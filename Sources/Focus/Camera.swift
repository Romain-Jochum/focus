import AVFoundation
import CoreGraphics
import CoreImage
import CoreML
import FocusCore
import Foundation
import VideoToolbox
import Vision

/// Built-in camera only. The session runs from `start()` until `stop()`, but its video output is disabled between samples, so the process receives one frame per `interval` seconds. Publishes `latest`.
final class CameraSensor: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Seconds between processed frames. Set before `start()`.
    var interval: Double = 5
    /// Multiplies Vision's pitch so positive means looking down (unverified: calibrate with `--probe`).
    static let pitchSign: Double = 1
    /// Phone model: only after `phoneIdle` seconds without keyboard or mouse input, and on every `phoneEvery`-th frame.
    static let phoneIdle = 5.0, phoneEvery = 3

    private let lock = NSLock()   // guards reading, running, armed, phoneModel, lastShot and phoneSeen
    private var reading: CameraReading?, running = false, armed = false, phoneModel: PhoneModel?
    private var lastShot: Shot?, phoneSeen: Shot?

    private let sessionQueue = DispatchQueue(label: "focus.camera.session"), frameQueue = DispatchQueue(label: "focus.camera.frames")
    private let session = AVCaptureSession(), output = AVCaptureVideoDataOutput()
    private let faceReq: VNDetectFaceRectanglesRequest = {
        let req = VNDetectFaceRectanglesRequest()
        req.revision = VNDetectFaceRectanglesRequestRevision3
        return req
    }()
    private var timer: DispatchSourceTimer?, configured = false, connection: AVCaptureConnection?   // sessionQueue
    private var samples = 0, phoneHold = 0.0, lastPhone = 0.0   // frameQueue

    /// Latest reading; safe to read from the main thread.
    var latest: CameraReading? { lock.withLock { reading } }

    func start() {
        lock.withLock { running = true }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } }
        sessionQueue.async {
            if self.lock.withLock({ self.phoneModel == nil }) { self.loadPhoneModel() }   // every start, after stop() released it
            guard self.timer == nil else { return }
            self.timer = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            self.timer?.setEventHandler { self.tick() }
            self.timer?.schedule(deadline: .now(), repeating: self.interval)
            self.timer?.resume()
        }
    }
    func stop() {
        lock.withLock { running = false; reading = nil; armed = false; lastShot = nil; phoneSeen = nil; phoneModel = nil }
        sessionQueue.async { self.timer?.cancel(); self.timer = nil; if self.session.isRunning { self.session.stopRunning() } }
    }
    private func tick() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return publish(CameraReading(at: monotonic(), presence: .unauthorized)) }
        if !configured { configured = configure() }   // retried on later ticks and starts until it succeeds
        guard let connection else { return }
        if !session.isRunning { session.startRunning() }
        lock.withLock { armed = true }
        connection.isEnabled = true
    }
    /// Returns false when no usable camera or format was found.
    private func configure() -> Bool {
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        guard let dev = devs.first(where: { !$0.isContinuityCamera }), let input = try? AVCaptureDeviceInput(device: dev),
              let format = Self.smallestFormat(dev) else { publish(CameraReading(at: monotonic(), presence: .blocked)); return false }
        session.beginConfiguration()
        guard session.canAddInput(input) else { session.commitConfiguration(); publish(CameraReading(at: monotonic(), presence: .blocked)); return false }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true; output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        // Without the lock, setting activeFormat raises. The input is removed so a later tick can retry.
        guard (try? dev.lockForConfiguration()) != nil else { session.removeInput(input); session.commitConfiguration(); publish(CameraReading(at: monotonic(), presence: .blocked)); return false }
        dev.activeFormat = format
        let slowest = format.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 1; dev.activeVideoMinFrameDuration = CMTime(seconds: 1 / slowest, preferredTimescale: 600)
        dev.activeVideoMaxFrameDuration = dev.activeVideoMinFrameDuration; dev.unlockForConfiguration()
        session.commitConfiguration()
        connection = output.connection(with: .video); connection?.isEnabled = false   // no frames until the first tick
        return connection != nil
    }

    /// Smallest 420v format.
    private static func smallestFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        dev.formats.filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
            .min { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }
    }

    /// Compiles the package into Application Support when the cache is missing or older, then loads it. A failure means no phone detection.
    private func loadPhoneModel() {
        let fm = FileManager.default
        // The app bundle, or Resources/ when run from the repo with `swift run`.
        let dirs = [Bundle.main.resourceURL, URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources")]
        guard let pkg = dirs.compactMap({ $0?.appendingPathComponent("rfdetr-nano.mlpackage") }).first(where: { fm.fileExists(atPath: $0.path) }) else {
            NSLog("Focus: rfdetr-nano.mlpackage not found, phone detection is off (run scripts/make-model.sh)"); return
        }
        let mtime = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
        do {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Focus", isDirectory: true)
            let cache = support.appendingPathComponent("rfdetr-nano.mlmodelc", isDirectory: true)
            if !(fm.fileExists(atPath: cache.path) && mtime(cache) >= mtime(pkg)) {
                try fm.createDirectory(at: support, withIntermediateDirectories: true); try? fm.removeItem(at: cache)
                try fm.moveItem(at: try MLModel.compileModel(at: pkg), to: cache)
            }
            let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: cache, configuration: cfg)
            lock.withLock { phoneModel = PhoneModel(model) }
        } catch { NSLog("Focus: phone model unavailable: %@", String(describing: error)) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard lock.withLock({ let was = armed; armed = false; return was }), let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        sessionQueue.async { connection.isEnabled = false }
        process(pb, luma: Self.luma(pb), at: monotonic())
    }
    private func process(_ pb: CVPixelBuffer, luma l: (mean: Double, sd: Double), at t: Double) {
        // Whatever happens below, the frame becomes the latest shot (and the phone shot when it scored).
        var shot = Shot(pb: pb, at: t)
        defer { lock.withLock { lastShot = shot; if shot.score >= 0.5 { phoneSeen = shot } } }
        if l.mean < 20 || l.sd < 6 { return publish(CameraReading(at: t, presence: .blocked)) }  // lens covered
        do { try VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([faceReq]) } catch { return }
        let face = faceReq.results?.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        let pitchDown = (face?.pitch?.doubleValue ?? 0) * 180 / .pi * Self.pitchSign
        shot.face = face.map { Shot.topLeft($0.boundingBox) }
        // Typing is not a phone: the phone model runs only after idle input. Same call as ActivitySensor.idleSeconds() (MainActor).
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        samples += 1
        if idle < Self.phoneIdle { phoneHold = 0; lastPhone = 0 }
        else if samples % Self.phoneEvery == 1, let model = lock.withLock({ phoneModel }) {
            let d = (try? model.detect(pb)) ?? (score: 0, box: nil)
            shot.score = d.score; shot.phone = d.score >= 0.5 ? d.box : nil
            // Reported only after two consecutive positive runs, and held until the next run.
            phoneHold = min(d.score, lastPhone); lastPhone = d.score
        }
        publish(CameraReading(at: t, presence: face == nil ? .none : .face, pitchDown: face == nil ? 0 : pitchDown, phone: phoneHold))
    }

    /// The frame to show on a check-in card: the phone frame when asked for and under 30 s old, else the latest frame. Converted on demand to a 480 px mirrored image.
    func evidence(preferPhone: Bool) -> CameraEvidence? {
        let picked = lock.withLock { () -> Shot? in
            let fresh = phoneSeen.map { monotonic() - $0.at < 30 } ?? false
            return preferPhone && fresh ? phoneSeen : lastShot
        }
        guard let s = picked else { return nil }
        // VideoToolbox converts on the CPU, without the ~40 MB a second CIContext keeps.
        var full: CGImage?
        VTCreateCGImageFromCVPixelBuffer(s.pb, options: nil, imageOut: &full)
        guard let full else { return nil }
        let w = 480, h = w * full.height / full.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1)   // mirrored like a selfie
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return nil }
        let mirror = { (r: CGRect) in CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height) }
        return CameraEvidence(image: image, face: s.face.map(mirror), phone: s.phone.map(mirror), phoneScore: s.score)
    }

    /// Mean and standard deviation of a subsampled Y plane.
    private static func luma(_ pb: CVPixelBuffer) -> (mean: Double, sd: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let p = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return (0, 0) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var sum = 0.0, sq = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 8) { for x in stride(from: 0, to: w, by: 8) {
            let v = Double(p[y * bpr + x]); sum += v; sq += v * v; n += 1
        } }
        let mean = sum / n
        return (mean, max(0, sq / n - mean * mean).squareRoot())
    }
    private func publish(_ r: CameraReading) { lock.withLock { if running { reading = r } } }
}

/// A processed frame kept for evidence: the pixel buffer plus its boxes in normalized, top-left coordinates.
private struct Shot {
    let pb: CVPixelBuffer, at: Double
    var face: CGRect?, phone: CGRect?, score = 0.0

    /// Vision's boxes are bottom-left origin.
    static func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
}

/// What the check-in card shows: a mirrored frame and its boxes (normalized, top-left origin).
struct CameraEvidence {
    let image: CGImage
    let face: CGRect?, phone: CGRect?
    let phoneScore: Double
}

/// RF-DETR nano: input "tensors" [1, 3, N, N] (RGB, ImageNet-normalized, NCHW); outputs boxes [1, 300, 4] (cx, cy, w, h, normalized) and logits [1, 300, 91] over COCO ids.
/// Reads only the "cell phone" column (COCO id 77) and the box of its best query. Used only from the frame queue.
private final class PhoneModel {
    let model: MLModel, inputName: String, size: Int
    let input: MLMultiArray, canvas: CVPixelBuffer
    let ctx = CIContext()

    init?(_ model: MLModel) {
        guard let desc = model.modelDescription.inputDescriptionsByName.first, let constraint = desc.value.multiArrayConstraint,
              let dim = constraint.shape.last?.intValue,
              let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: dim), NSNumber(value: dim)], dataType: .float32) else { return nil }
        var buf: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, dim, dim, kCVPixelFormatType_32BGRA, nil, &buf) == kCVReturnSuccess, let canvas = buf else { return nil }
        (self.model, self.inputName, self.size, self.input, self.canvas) = (model, desc.key, dim, input, canvas)
    }

    /// Scale-fills the frame to the model size; returns the cell-phone score (0...1) and the box of its best query, if the model has one.
    func detect(_ pb: CVPixelBuffer) throws -> (score: Double, box: CGRect?) {
        let sx = CGFloat(size) / CGFloat(CVPixelBufferGetWidth(pb)), sy = CGFloat(size) / CGFloat(CVPixelBufferGetHeight(pb))
        ctx.render(CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: canvas,
                   bounds: CGRect(x: 0, y: 0, width: size, height: size), colorSpace: nil)
        guard fill() else { return (0, nil) }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)]))
        let outputs = out.featureNames.compactMap { out.featureValue(for: $0)?.multiArrayValue }
        guard let logits = outputs.first(where: { $0.shape.last?.intValue == 91 }), logits.shape.count >= 2 else { return (0, nil) }
        // Read through strides and the raw buffer: no per-query allocations.
        let column = (0..<logits.shape[logits.shape.count - 2].intValue).map { Self.read(logits, $0, 77) }
        let best = column.max() ?? 0, top = column.indices.max { column[$0] < column[$1] } ?? 0
        let score = Double(column.contains { $0 < 0 } ? 1 / (1 + exp(-best)) : best)  // raw logits vs scores
        guard let boxes = outputs.first(where: { $0.shape.last?.intValue == 4 }), boxes.shape.count >= 2,
              top < boxes.shape[boxes.shape.count - 2].intValue else { return (score, nil) }
        let (cx, cy, w, h) = (Self.read(boxes, top, 0), Self.read(boxes, top, 1), Self.read(boxes, top, 2), Self.read(boxes, top, 3))
        return (score, CGRect(x: CGFloat(cx - w / 2), y: CGFloat(cy - h / 2), width: CGFloat(w), height: CGFloat(h)))
    }

    /// Element (row, column) of the last two axes, read through the strides (float16 or float32).
    private static func read(_ a: MLMultiArray, _ row: Int, _ col: Int) -> Float {
        let rank = a.shape.count, st = a.strides.map { $0.intValue }
        let off = row * st[rank - 2] + col * st[rank - 1]
        return a.dataType == .float16 ? Float(a.dataPointer.load(fromByteOffset: off * 2, as: Float16.self)) : a.dataPointer.load(fromByteOffset: off * 4, as: Float.self)
    }
    private func fill() -> Bool {
        CVPixelBufferLockBaseAddress(canvas, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(canvas, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(canvas) else { return false }
        let px = base.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(canvas), plane = size * size
        let dst = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        for y in 0..<size { for x in 0..<size { for c in 0..<3 {   // BGRA source
            dst[c * plane + y * size + x] = (Float(px[y * bpr + x * 4 + 2 - c]) / 255 - mean[c]) / std[c]
        } } }
        return true
    }
}

import AVFoundation
import CoreGraphics
import CoreMediaIO
import CoreML
import FocusCore
import Foundation
import VideoToolbox
import Vision

/// Built-in camera only, read through CoreMediaIO: the frames AVFoundation would deliver, without its video-effects stack (measured:
/// 4 MB and 0.9% CPU against 156 MB and 3.5% for a capture session). Streams while `want(true)`, keeps one frame per `interval` seconds
/// and publishes `latest`.
final class CameraSensor: @unchecked Sendable {
    /// Seconds between processed frames. Set before `start()`.
    var interval: Double = 5
    /// Multiplies Vision's pitch so positive means looking down (unverified: calibrate with `--probe`).
    static let pitchSign: Double = 1
    /// Phone model: only after `phoneIdle` seconds without keyboard or mouse input, and on every `phoneEvery`-th frame.
    static let phoneIdle = 5.0, phoneEvery = 3
    /// Frames are skipped this long after a start: auto-exposure starts dark each time (measured: black for 0.6 s, 85% of its level at 2 s).
    static let warmUp = 2.0
    /// A stream that delivers nothing this long reads as covered (the camera failed to start or went away).
    static let stall = 15.0

    private let lock = NSLock()   // guards the next two lines
    private var reading: CameraReading?, running = false, wanted = false, phoneModel: PhoneModel?, lastShot: Shot?, phoneSeen: Shot?
    private var buffers: CMSimpleQueue?, due = Double.infinity, lastFrame = 0.0   // when the next frame is kept, and when the last one came

    private let queue = DispatchQueue(label: "focus.camera", qos: .utility)
    private let faceReq: VNDetectFaceRectanglesRequest = {
        let req = VNDetectFaceRectanglesRequest()
        req.revision = VNDetectFaceRectanglesRequestRevision3
        return req
    }()
    private var timer: DispatchSourceTimer?, device = CMIOObjectID(0), stream = CMIOStreamID(0)   // queue
    private var since: Double?, samples = 0, phoneHold = 0.0, lastPhone = 0.0   // queue; since: when the stream started, nil while off

    /// Latest reading; safe to read from the main thread. Nil while the camera is not wanted.
    var latest: CameraReading? { lock.withLock { reading } }

    func start() {
        lock.withLock { running = true }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } }
        queue.async {
            if self.lock.withLock({ self.phoneModel == nil }) { self.loadPhoneModel() }   // every start, after stop() released it
            guard self.timer == nil else { return }
            self.timer = DispatchSource.makeTimerSource(queue: self.queue)
            self.timer?.setEventHandler { self.apply() }
            self.timer?.schedule(deadline: .now(), repeating: self.interval, leeway: .seconds(1))
            self.timer?.resume()
        }
    }
    func stop() {
        lock.withLock { running = false; wanted = false; reading = nil; lastShot = nil; phoneSeen = nil; phoneModel = nil }
        queue.async { self.timer?.cancel(); self.timer = nil; self.halt() }
    }
    /// Called every second with `Engine.wantsCamera`; the stream starts or stops when it changes.
    func want(_ on: Bool) {
        if lock.withLock({ defer { wanted = on }; return wanted != on }) { queue.async { self.apply() } }
    }

    /// On each change of `want` and every `interval`: starts or stops the stream, and reads covered when no camera or frame comes.
    private func apply() {   // queue
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { halt(); return publish(CameraReading(at: monotonic(), presence: .unauthorized)) }
        let now = monotonic(), (on, last) = lock.withLock { (running && wanted, lastFrame) }
        guard on else { halt(); return lock.withLock { reading = nil } }
        if let since {
            guard now - max(since, last) > Self.stall else { return }
            // The stream died (the camera went away, or the system stopped it): reopened on the next interval, covered meanwhile.
            halt(); lock.withLock { buffers = nil }
            return publish(CameraReading(at: now, presence: .blocked))
        }
        // Retried every interval until it succeeds; a failed start reopens the device (it may have gone and come back).
        guard lock.withLock({ buffers }) != nil || open(), startStream() else {
            lock.withLock { buffers = nil }
            return publish(CameraReading(at: now, presence: .blocked))
        }
        (since, samples, phoneHold, lastPhone) = (now, 0, 0, 0)
        lock.withLock { due = now + Self.warmUp }
    }
    private func halt() {   // queue
        guard since != nil else { return }
        CMIODeviceStopStream(device, stream)
        since = nil
        lock.withLock { due = .infinity }
    }

    /// The built-in camera's input stream, with our buffer queue attached. AVFoundation only finds the camera (its uniqueID is the CMIO
    /// device UID, and Desk View and iPhones are left out); it loads no effects for that.
    private func open() -> Bool {   // queue
        let camera = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first { !$0.isContinuityCamera }
        guard let uid = camera?.uniqueID,
              let dev = Self.ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).first(where: { Self.value($0, kCMIODevicePropertyDeviceUID) == uid }),
              let st = Self.ids(dev, kCMIODevicePropertyStreams, kCMIODevicePropertyScopeInput).first else { return false }
        // The queue holds the sensor for as long as the process lives.
        var q: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(st, { _, _, me in Unmanaged<CameraSensor>.fromOpaque(me!).takeUnretainedValue().delivered() },
                                        Unmanaged.passRetained(self).toOpaque(), &q) == noErr, let q else { return false }
        (device, stream) = (dev, st)
        lock.withLock { buffers = q.takeRetainedValue() }
        return true
    }
    /// Starts the stream at the smallest 420v format and slowest rate. The format is the device's, shared by every app, so it is left
    /// alone while another app streams (a call keeps its resolution; we take its frames).
    private func startStream() -> Bool {   // queue
        if Self.get(device, kCMIODevicePropertyDeviceIsRunningSomewhere, UInt32(0)) == 0,
           let formats: [CMFormatDescription] = Self.value(stream, kCMIOStreamPropertyFormatDescriptions),
           let format = formats.filter({ CMFormatDescriptionGetMediaSubType($0) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange })
               .min(by: { CMVideoFormatDescriptionGetDimensions($0).width < CMVideoFormatDescriptionGetDimensions($1).width }) {
            let current: CMFormatDescription? = Self.value(stream, kCMIOStreamPropertyFormatDescription)
            if current.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
                _ = Self.set(stream, kCMIOStreamPropertyFormatDescription, Unmanaged.passUnretained(format).toOpaque())
            }
            if let slowest = Self.get(stream, kCMIOStreamPropertyMinimumFrameRate, 0.0), Self.get(stream, kCMIOStreamPropertyFrameRate, 0.0) != slowest {
                _ = Self.set(stream, kCMIOStreamPropertyFrameRate, slowest)
            }
        }
        return CMIODeviceStartStream(device, stream) == noErr
    }

    /// CoreMediaIO's thread, on every frame (15 fps at our format, a call's rate while one streams): all are released at once except
    /// one per `interval`.
    private func delivered() {
        guard let buffers = lock.withLock({ buffers }) else { return }
        var newest: CMSampleBuffer?
        while let raw = CMSimpleQueueDequeue(buffers) { newest = Unmanaged<CMSampleBuffer>.fromOpaque(raw).takeRetainedValue() }
        let now = monotonic()
        guard let pb = newest.flatMap(CMSampleBufferGetImageBuffer), lock.withLock({ () -> Bool in
            lastFrame = now
            guard now >= due else { return false }
            due = now + interval
            return true
        }) else { return }
        queue.async { self.process(pb, at: now) }
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
    private func process(_ pb: CVPixelBuffer, at t: Double) {   // queue
        guard since != nil else { return }   // the stream stopped after this frame came
        // Whatever happens below, the frame becomes the latest shot (and the phone shot when it scored).
        var shot = Shot(pb: pb, at: t)
        defer { lock.withLock { lastShot = shot; if shot.score >= 0.5 { phoneSeen = shot } } }
        let l = Self.luma(pb)
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

    /// The frame to show on a check-in card: the phone frame when asked for and under 30 s old, else the latest frame if the stream is
    /// on (nil until its next frame otherwise). Converted on demand to a 480 px mirrored image, plus the frame itself when `raw`.
    func evidence(preferPhone: Bool, raw: Bool = false) -> CameraEvidence? {
        let picked = lock.withLock { () -> Shot? in
            let now = monotonic()
            if preferPhone, let p = phoneSeen, now - p.at < 30 { return p }
            return lastShot.flatMap { now - $0.at < 2 * interval ? $0 : nil }
        }
        guard let s = picked else { return nil }
        // VideoToolbox converts on the CPU, without the ~40 MB a CIContext keeps.
        var full: CGImage?
        VTCreateCGImageFromCVPixelBuffer(s.pb, options: nil, imageOut: &full)
        guard let full else { return nil }
        let w = 480, h = w * full.height / full.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1)   // mirrored like a selfie
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return nil }
        return CameraEvidence(image: image, face: s.face.map(CameraEvidence.mirrored), phone: s.phone.map(CameraEvidence.mirrored),
                              phoneScore: s.score, frame: raw ? full : nil)
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

    private static func address(_ selector: Int, _ scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(scope), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    /// A list of CMIO objects: the devices, or a device's streams.
    private static func ids(_ object: CMIOObjectID, _ selector: Int, _ scope: Int = kCMIOObjectPropertyScopeGlobal) -> [CMIOObjectID] {
        var addr = address(selector, scope), size: UInt32 = 0, used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        return CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &out) == noErr ? out : []
    }
    /// A Core Foundation property (a string, an array), which CMIO returns retained.
    private static func value<T>(_ object: CMIOObjectID, _ selector: Int) -> T? {
        var addr = address(selector), used: UInt32 = 0, out: Unmanaged<CFTypeRef>?
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<CFTypeRef?>.size), &used, &out) == noErr else { return nil }
        return out?.takeRetainedValue() as? T
    }
    /// A plain property: a UInt32 flag, a Float64 rate.
    private static func get<T: BitwiseCopyable>(_ object: CMIOObjectID, _ selector: Int, _ zero: T) -> T? {
        var addr = address(selector), v = zero, used: UInt32 = 0
        return CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &used, &v) == noErr ? v : nil
    }
    /// Sets a property from plain bytes: a Float64, or a Core Foundation object's pointer.
    private static func set<T: BitwiseCopyable>(_ object: CMIOObjectID, _ selector: Int, _ value: T) -> Bool {
        var addr = address(selector), v = value
        return CMIOObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }
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
    /// Developer mode: the frame as the camera delivered it (full size, not mirrored), for a `FalseAlarm`.
    var frame: CGImage? = nil

    /// A box flipped left to right: from the camera's view to the mirrored image, and back.
    static func mirrored(_ r: CGRect) -> CGRect { CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height) }
}

/// RF-DETR nano: input "tensors" [1, 3, N, N] (RGB, ImageNet-normalized, NCHW); outputs boxes [1, 300, 4] (cx, cy, w, h, normalized) and logits [1, 300, 91] over COCO ids.
/// Reads only the "cell phone" column (COCO id 77) and the box of its best query. Used only from the frame queue.
private final class PhoneModel {
    let model: MLModel, inputName: String, size: Int
    let input: MLMultiArray

    init?(_ model: MLModel) {
        guard let desc = model.modelDescription.inputDescriptionsByName.first, let constraint = desc.value.multiArrayConstraint,
              let dim = constraint.shape.last?.intValue,
              let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: dim), NSNumber(value: dim)], dataType: .float32) else { return nil }
        (self.model, self.inputName, self.size, self.input) = (model, desc.key, dim, input)
    }

    /// Scale-fills the frame to the model size; returns the cell-phone score (0...1) and the box of its best query, if the model has one.
    func detect(_ pb: CVPixelBuffer) throws -> (score: Double, box: CGRect?) {
        guard fill(pb) else { return (0, nil) }
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
    /// Scale-fills the frame as the model was validated (research/spike-rfdetr.swift): VideoToolbox converts it and Core Graphics scales
    /// it in the frame's own colour space, so the pixels stay gamma-encoded (Core Image would hand over linear light, which raised a
    /// laptop photo past the threshold).
    private func fill(_ pb: CVPixelBuffer) -> Bool {
        var frame: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &frame)
        guard let frame, let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: frame.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let base = ctx.data else { return false }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: size, height: size))
        let px = base.assumingMemoryBound(to: UInt8.self), bpr = ctx.bytesPerRow, plane = size * size
        let dst = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        for y in 0..<size { for x in 0..<size { for c in 0..<3 {   // BGRA in memory
            dst[c * plane + y * size + x] = (Float(px[y * bpr + x * 4 + 2 - c]) / 255 - mean[c]) / std[c]
        } } }
        return true
    }
}

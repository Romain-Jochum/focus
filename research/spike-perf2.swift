// Performance spike 2: steady-state CPU and memory for webcam face rectangles + YOLO26s.
// Build (release, embedded camera usage string):
//   swiftc -O spike-perf2.swift -o spike-perf2 \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker spike-perf2-Info.plist
//   Info.plist for -sectcreate __TEXT __info_plist (spike-perf2-Info.plist, not kept) needs one key: <key>NSCameraUsageDescription</key><string>Spike</string>
// Model:  compile once, outside the timed window:  ./spike-perf2 compile
// Run:    ./spike-perf2 <cont-face|cont-face-yolo|cont-face-yolo5|snap5|snap10> [interval=1]
//         interval = seconds between processed frames (continuous) or capture period is fixed by the mode.
// The process runs 85 s. The measurement window is 20 s to 80 s after launch; the driver script
// (not kept) samples ps cputime and footprint at the same points. Exit code 3 = camera not authorized.

import AVFoundation
import CoreML
import CoreMedia
import CoreVideo
import Foundation
import Vision

let root = FileManager.default.currentDirectoryPath   // run from a scratch folder holding yolo26s.mlpackage
let cachedModel = root + "/cache/yolo26s.mlmodelc"
let sourceModel = root + "/yolo26s.mlpackage"
let windowStart = 20.0
let windowEnd = 80.0
let totalRun = 85.0
let scoreThreshold: Float = 0.25
let personIdx = 0    // COCO "person"
let phoneIdx = 67    // COCO "cell phone" (YOLO26 end2end class index)

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

func say(_ s: String) {
    print(s)
    fflush(stdout)
}

func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let u = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
    let s = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    return u + s
}

func peakRSSMB() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_maxrss) / 1_048_576.0   // bytes on macOS
}

// Same counter Activity Monitor shows as "Memory" (phys_footprint).
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), q, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : -1
}

struct Config {
    let name: String
    let continuous: Bool
    let yolo: Bool
    let yoloEvery: Int      // run YOLO on every Nth processed frame (continuous only)
    let interval: Double    // continuous: seconds between processed frames; snap: capture period
}

func parseConfig(_ args: [String]) -> Config? {
    guard args.count >= 2 else { return nil }
    let iv = args.count >= 3 ? (Double(args[2]) ?? 1.0) : 1.0
    switch args[1] {
    case "cont-face":
        return Config(name: args[1], continuous: true, yolo: false, yoloEvery: 1, interval: iv)
    case "cont-face-yolo":
        return Config(name: args[1], continuous: true, yolo: true, yoloEvery: 1, interval: iv)
    case "cont-face-yolo5":
        return Config(name: args[1], continuous: true, yolo: true, yoloEvery: 5, interval: iv)
    case "snap5":
        return Config(name: args[1], continuous: false, yolo: true, yoloEvery: 1, interval: 5)
    case "snap10":
        return Config(name: args[1], continuous: false, yolo: true, yoloEvery: 1, interval: 10)
    default:
        return nil
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
}

// Compile YOLO26s once and cache the .mlmodelc. Run before any measured run.
func compileModel() throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/cache", withIntermediateDirectories: true)
    let tmp = try MLModel.compileModel(at: URL(fileURLWithPath: sourceModel))
    if fm.fileExists(atPath: cachedModel) { try fm.removeItem(atPath: cachedModel) }
    try fm.copyItem(at: tmp, to: URL(fileURLWithPath: cachedModel))
}

func loadYolo() throws -> VNCoreMLModel {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = .cpuAndNeuralEngine
    let ml = try MLModel(contentsOf: URL(fileURLWithPath: cachedModel), configuration: cfg)
    return try VNCoreMLModel(for: ml)
}

// YOLO26 end2end output [1, 300, 6]: x1, y1, x2, y2, score, class. Counts persons and phones above threshold.
func countYolo(_ a: MLMultiArray) -> (persons: Int, phones: Int) {
    let n = a.shape[1].intValue
    var persons = 0
    var phones = 0
    for i in 0..<n {
        let score = a[[0, i, 4].map { NSNumber(value: $0) }].floatValue
        guard score >= scoreThreshold else { continue }
        let cls = Int(a[[0, i, 5].map { NSNumber(value: $0) }].floatValue.rounded())
        if cls == personIdx { persons += 1 } else if cls == phoneIdx { phones += 1 }
    }
    return (persons, phones)
}

// Smallest-resolution 420v format, with its longest supported frame duration (1 / min fps).
func smallest420vFormat(_ dev: AVCaptureDevice) -> (format: AVCaptureDevice.Format, duration: CMTime, desc: String)? {
    let want = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var best: (f: AVCaptureDevice.Format, px: Int32)?
    for f in dev.formats where CMFormatDescriptionGetMediaSubType(f.formatDescription) == want {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let px = d.width * d.height
        if best == nil || px < best!.px { best = (f, px) }
    }
    guard let b = best else { return nil }
    let ranges = b.f.videoSupportedFrameRateRanges
    guard let longest = ranges.map({ $0.maxFrameDuration }).max(by: { CMTimeCompare($0, $1) < 0 }) else { return nil }
    let d = CMVideoFormatDescriptionGetDimensions(b.f.formatDescription)
    let fpsText = ranges.map { String(format: "%.1f-%.1f", $0.minFrameRate, $0.maxFrameRate) }.joined(separator: ",")
    let desc = "\(d.width)x\(d.height) 420v, fps ranges [\(fpsText)], chosen duration \(String(format: "%.4f", longest.seconds)) s"
    return (b.f, longest, desc)
}

final class Spike: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let cfg: Config
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let frameQueue = DispatchQueue(label: "spike2.frames", qos: .userInitiated)
    let sessionQueue = DispatchQueue(label: "spike2.session")
    let faceReq = VNDetectFaceRectanglesRequest()
    var yoloReq: VNCoreMLRequest?
    let seq = VNSequenceRequestHandler()
    var camDevice: AVCaptureDevice?
    var enforcerTimer: DispatchSourceTimer?
    var formatReapplies = 0   // sessionQueue-confined
    var pickFormat: (format: AVCaptureDevice.Format, duration: CMTime, desc: String)?
    var camName = "none"
    var formatDesc = "none"
    var postRunFormat = "none"

    // Confined to frameQueue.
    var processedTotal = 0
    var lastProcessed = -1.0
    var delivered = 0
    var ptsLast = -1.0
    var ptsDeltaSum = 0.0
    var ptsDeltaN = 0
    var processed = 0
    var faceFrames = 0
    var facesTotal = 0
    var faceMs = 0.0
    var yoloRuns = 0
    var yoloMs = 0.0
    var personsTotal = 0
    var phonesTotal = 0
    var errors = 0
    var pixFmt = "?"
    var windowOpen = false
    var armed = false
    var startHost = 0.0
    var camOn0 = 0.0
    var captureRecords: [(start: Double, dur: Double, footprintMB: Double)] = []

    init(cfg: Config) {
        self.cfg = cfg
        super.init()
        faceReq.revision = VNDetectFaceRectanglesRequestRevision3
    }

    func setup() throws {
        let disco = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let dev = disco.devices.first(where: { !$0.isContinuityCamera }) else {
            throw SpikeError(description: "no built-in camera among \(disco.devices.map { $0.localizedName })")
        }
        camName = dev.localizedName
        guard let pick = smallest420vFormat(dev) else { throw SpikeError(description: "no 420v format") }
        camDevice = dev
        pickFormat = pick

        session.beginConfiguration()
        // .inputPriority is unavailable on macOS; setting activeFormat below switches the session to it.
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw SpikeError(description: "cannot add input") }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { throw SpikeError(description: "cannot add output") }
        session.addOutput(output)
        session.commitConfiguration()
        // The session reapplies its preset on start, so the format is (re)applied after every startRunning.
        formatDesc = pick.desc

        startEnforcer()
        if cfg.yolo {
            let m = try loadYolo()
            let r = VNCoreMLRequest(model: m)
            r.imageCropAndScaleOption = .scaleFill
            yoloReq = r
        }
    }

    func describeDevice() -> String {
        guard let dev = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.first(where: { !$0.isContinuityCamera }) else { return "device gone" }
        let d = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        return String(format: "%dx%d, minFrameDuration=%.4f s, maxFrameDuration=%.4f s, preset=%@",
                      d.width, d.height,
                      CMTimeGetSeconds(dev.activeVideoMinFrameDuration),
                      CMTimeGetSeconds(dev.activeVideoMaxFrameDuration),
                      session.sessionPreset.rawValue)
    }

    // Format is enforced on sessionQueue. Setting activeFormat switches the session to input priority on macOS.
    // The session reverts to its High preset at start, so the format is checked after start and every 0.5 s
    // while the session runs, and re-applied when it differs. Re-apply count is reported.
    func formatMatches(_ dev: AVCaptureDevice, _ pick: (format: AVCaptureDevice.Format, duration: CMTime, desc: String)) -> Bool {
        dev.activeFormat == pick.format
            && CMTimeCompare(dev.activeVideoMinFrameDuration, pick.duration) == 0
            && CMTimeCompare(dev.activeVideoMaxFrameDuration, pick.duration) == 0
    }

    func enforceFormat() {
        guard session.isRunning, let dev = camDevice, let pick = pickFormat else { return }
        if formatMatches(dev, pick) { return }
        formatReapplies += 1
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = pick.format
            dev.activeVideoMinFrameDuration = pick.duration
            dev.activeVideoMaxFrameDuration = pick.duration
            dev.unlockForConfiguration()
        } catch {
            say("APPLY_FORMAT_ERROR \(error)")
        }
    }

    func applyFormatAfterStart() {
        for _ in 0..<40 {
            enforceFormat()
            Thread.sleep(forTimeInterval: 0.05)
            if let dev = camDevice, let pick = pickFormat, formatMatches(dev, pick) { return }
        }
    }

    func startEnforcer() {
        sessionQueue.async {
            let t = DispatchSource.makeTimerSource(queue: self.sessionQueue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { self.enforceFormat() }
            t.resume()
            self.enforcerTimer = t
        }
    }

    func startSession() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning(); self.applyFormatAfterStart() }
        }
    }

    // Snap mode: start the kept session, arm the frame filter (first frame >= 0.3 s after start).
    func beginCapture() {
        let t = uptime()
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        frameQueue.async {
            self.armed = true
            self.startHost = host
            self.camOn0 = t
        }
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning(); self.applyFormatAfterStart() }
        }
    }

    func stopAll() {
        sessionQueue.sync {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func openWindow() {
        frameQueue.async {
            self.delivered = 0
            self.ptsDeltaSum = 0
            self.ptsDeltaN = 0
            self.processed = 0
            self.faceFrames = 0
            self.facesTotal = 0
            self.faceMs = 0
            self.yoloRuns = 0
            self.yoloMs = 0
            self.personsTotal = 0
            self.phonesTotal = 0
            self.errors = 0
            self.captureRecords = []
            self.windowOpen = true
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = uptime()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        delivered += 1
        if ptsLast >= 0 && windowOpen {
            ptsDeltaSum += pts - ptsLast
            ptsDeltaN += 1
        }
        ptsLast = pts
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if pixFmt == "?" {
            let p = CVPixelBufferGetPixelFormatType(pb)
            pixFmt = String(bytes: [UInt8((p >> 24) & 255), UInt8((p >> 16) & 255), UInt8((p >> 8) & 255), UInt8(p & 255)], encoding: .ascii) ?? "?"
        }

        if cfg.continuous {
            if lastProcessed >= 0 && now - lastProcessed < cfg.interval { return }
            lastProcessed = now
            let runYolo = cfg.yolo && (processedTotal % cfg.yoloEvery == 0)
            process(pb, runYolo: runYolo)
            return
        }

        // Snap mode: first frame at least 0.3 s after the session started.
        guard armed, pts - startHost >= 0.3 else { return }
        armed = false
        let on0 = camOn0
        process(pb, runYolo: cfg.yolo)
        let fp = physFootprintMB()   // sampled while the camera is still on
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            let t1 = uptime()
            self.frameQueue.async {
                self.captureRecords.append((start: on0, dur: t1 - on0, footprintMB: fp))
            }
        }
    }

    func process(_ pb: CVPixelBuffer, runYolo: Bool) {
        processedTotal += 1
        processed += 1

        let t0 = uptime()
        do { try seq.perform([faceReq], on: pb, orientation: .up) } catch { errors += 1 }
        faceMs += (uptime() - t0) * 1000
        let faces = faceReq.results ?? []
        if !faces.isEmpty { faceFrames += 1 }
        facesTotal += faces.count

        if runYolo, let yr = yoloReq {
            let t1 = uptime()
            do { try seq.perform([yr], on: pb, orientation: .up) } catch { errors += 1 }
            yoloMs += (uptime() - t1) * 1000
            yoloRuns += 1
            if let obs = (yr.results as? [VNCoreMLFeatureValueObservation])?.first,
               let arr = obs.featureValue.multiArrayValue {
                let c = countYolo(arr)
                personsTotal += c.persons
                phonesTotal += c.phones
            }
        }
    }

    func formatReapplies_snapshot() -> Int {
        sessionQueue.sync { formatReapplies }
    }

    func closeWindow(cpuDelta: Double, wall: Double) {
        let footprint = physFootprintMB()
        frameQueue.sync {
            windowOpen = false
            let fps = Double(delivered) / wall
            let ptsFps = ptsDeltaN > 0 ? Double(ptsDeltaN) / ptsDeltaSum : 0
            say(String(format: "RESULT mode=%@ window=%.1fs", cfg.name, wall))
            say(String(format: "RESULT cpu_self_pct=%.2f cpu_s=%.2f", cpuDelta / wall * 100, cpuDelta))
            say(String(format: "RESULT footprint_mb=%.1f rss_peak_mb=%.1f", footprint, peakRSSMB()))
            say("camera: \(camName)")
            say("format: \(formatDesc)")
            say("format_reapplies=\(formatReapplies_snapshot())")
            say("post-run device: \(describeDevice())")
            say(String(format: "RESULT delivered=%d delivered_fps=%.2f delivered_fps_pts=%.2f pixfmt=%@",
                       delivered, fps, ptsFps, pixFmt))
            say(String(format: "RESULT processed=%d processed_fps=%.2f", processed, Double(processed) / wall))
            say(String(format: "RESULT face_frames=%d faces_total=%d face_ms_avg=%.1f",
                       faceFrames, facesTotal, processed > 0 ? faceMs / Double(processed) : 0))
            say(String(format: "RESULT yolo_runs=%d yolo_ms_avg=%.1f persons=%d phones=%d",
                       yoloRuns, yoloRuns > 0 ? yoloMs / Double(yoloRuns) : 0, personsTotal, phonesTotal))
            if !cfg.continuous {
                // captureRecords is cleared when the window opens, so every record is inside the window.
                let recs = captureRecords
                let avg = recs.isEmpty ? 0 : recs.map { $0.dur }.reduce(0, +) / Double(recs.count)
                let fpMax = recs.map { $0.footprintMB }.max() ?? -1
                say(String(format: "RESULT captures=%d camera_on_s_per_capture=%.2f camera_on_total_s=%.2f footprint_max_during_capture_mb=%.1f",
                           recs.count, avg, recs.map { $0.dur }.reduce(0, +), fpMax))
            } else {
                say(String(format: "RESULT camera_on=continuous_whole_window"))
            }
            say("RESULT errors=\(errors)")
        }
    }
}

// MARK: - main

let argv = CommandLine.arguments
if argv.count >= 2 && argv[1] == "compile" {
    do {
        try compileModel()
        say("compiled to \(cachedModel)")
        exit(0)
    } catch {
        say("COMPILE_ERROR \(error)")
        exit(1)
    }
}

guard let cfg = parseConfig(argv) else {
    say("usage: spike-perf2 compile | <cont-face|cont-face-yolo|cont-face-yolo5|snap5|snap10> [interval]")
    exit(2)
}

let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
var authorized = authStatus == .authorized
if authStatus == .notDetermined {
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { ok in
        authorized = ok
        sem.signal()
    }
    sem.wait()
}
guard authorized else {
    say("AUTH_DENIED: camera not authorized for this process")
    exit(3)
}

let spike = Spike(cfg: cfg)
do {
    try spike.setup()
} catch {
    say("SETUP_ERROR \(error)")
    exit(4)
}
say("mode=\(cfg.name) interval=\(cfg.interval) camera=\(spike.camName)")

var keepTimers: [DispatchSourceTimer] = []
var cpu0 = 0.0
var wall0 = 0.0

if cfg.continuous {
    spike.startSession()
} else {
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now(), repeating: cfg.interval)
    t.setEventHandler { spike.beginCapture() }
    t.resume()
    keepTimers.append(t)
}

DispatchQueue.main.asyncAfter(deadline: .now() + windowStart) {
    cpu0 = cpuSeconds()
    wall0 = uptime()
    spike.openWindow()
}

DispatchQueue.main.asyncAfter(deadline: .now() + windowEnd) {
    let cpuNow = cpuSeconds()
    let wallNow = uptime()
    spike.closeWindow(cpuDelta: cpuNow - cpu0, wall: wallNow - wall0)
}

DispatchQueue.main.asyncAfter(deadline: .now() + totalRun) {
    keepTimers.forEach { $0.cancel() }
    spike.stopAll()
    say("RESULT exit_after_s=\(totalRun)")
    exit(0)
}

dispatchMain()

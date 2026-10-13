// Performance spike: 1 fps webcam analysis + frontmost app polling.
// Build (release, not interpreter):
//   swiftc -O spike-perf.swift -o spike-perf \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker spike-perf-Info.plist
//   Info.plist for -sectcreate __TEXT __info_plist (not kept) needs one key: <key>NSCameraUsageDescription</key><string>Spike</string>
// Run:    ./spike-perf <face|face+yolo|face+yolo5|snap20|compile> [seconds=60]
// "compile" only compiles and caches the YOLO model (dl/YOLOv3TinyFP16.mlmodelc).
// Exit code 3 = camera not authorized (the driver script, not kept, retries).

import AppKit
import AVFoundation
import CoreML
import CoreMedia
import CoreVideo
import Foundation
import Vision

let perfDir = FileManager.default.currentDirectoryPath   // run from a scratch folder; models download to ./dl
let dlDir = perfDir + "/dl"

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
    // ru_maxrss is in bytes on macOS
    return Double(ru.ru_maxrss) / 1_048_576.0
}

enum Mode: String {
    case face
    case faceYolo = "face+yolo"
    case faceYolo5 = "face+yolo5"
    case snap20
    case compile
}

enum SpikeError: Error {
    case noBuiltInCamera([String])
    case cannotAddInput
    case cannotAddOutput
    case noFormat
}

func loadYolo() throws -> VNCoreMLModel {
    let compiledURL = URL(fileURLWithPath: dlDir + "/YOLOv3TinyFP16.mlmodelc")
    if !FileManager.default.fileExists(atPath: compiledURL.path) {
        let src = URL(fileURLWithPath: dlDir + "/YOLOv3TinyFP16.mlmodel")
        let tmp = try MLModel.compileModel(at: src)
        try FileManager.default.copyItem(at: tmp, to: compiledURL)
    }
    let cfg = MLModelConfiguration()
    cfg.computeUnits = .cpuAndNeuralEngine
    let ml = try MLModel(contentsOf: compiledURL, configuration: cfg)
    return try VNCoreMLModel(for: ml)
}

struct FormatChoice {
    let format: AVCaptureDevice.Format
    let duration: CMTime
    let desc: String
}

func pickFormat(_ dev: AVCaptureDevice) throws -> FormatChoice {
    let want = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var candidates: [(AVCaptureDevice.Format, Int, Double)] = []
    for f in dev.formats {
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        guard sub == want else { continue }
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let minRate = f.videoSupportedFrameRateRanges.map { $0.minFrameRate }.min() ?? 30
        candidates.append((f, Int(d.width) * Int(d.height), minRate))
    }
    guard !candidates.isEmpty else { throw SpikeError.noFormat }
    candidates.sort { ($0.1, $0.2) < ($1.1, $1.2) }
    let (fmt, _, _) = candidates[0]
    let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
    let ranges = fmt.videoSupportedFrameRateRanges
    let minRate = ranges.map { $0.minFrameRate }.min() ?? 1
    let maxRate = ranges.map { $0.maxFrameRate }.max() ?? 30
    let supportsOne = ranges.contains { $0.minFrameRate <= 1.0 && 1.0 <= $0.maxFrameRate }
    let duration: CMTime = supportsOne
        ? CMTime(value: 1, timescale: 1)
        : CMTime(seconds: 1.0 / minRate, preferredTimescale: 600)
    let desc = "\(dims.width)x\(dims.height) 420v, ranges min=\(minRate) max=\(maxRate) fps, "
        + "chosen frame duration=\(String(format: "%.3f", duration.seconds))s (\(String(format: "%.2f", 1.0 / duration.seconds)) fps)"
    return FormatChoice(format: fmt, duration: duration, desc: desc)
}

final class Spike: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let mode: Mode
    let capMode: Bool
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let frameQueue = DispatchQueue(label: "spike.frames", qos: .userInitiated)
    let sessionQueue = DispatchQueue(label: "spike.session")
    var camName = "none"
    var connNote = ""
    var pixFmt = ""
    var formatDesc = "none"
    let faceReq = VNDetectFaceRectanglesRequest()
    var yoloReq: VNCoreMLRequest?

    // Touched only on frameQueue.
    var delivered = 0
    var processed = 0
    var faceFrames = 0
    var faceTotal = 0
    var yoloRuns = 0
    var yoloDetections = 0
    var errors = 0
    var faceMs: [Double] = []
    var yoloMs: [Double] = []
    var lastProcessed: Double = -1
    var warmupEnd: Double = 0
    var captured = false
    var captures = 0
    var captureLog: [String] = []

    init(mode: Mode, capMode: Bool) {
        self.mode = mode
        self.capMode = capMode
        super.init()
        faceReq.revision = VNDetectFaceRectanglesRequestRevision3
    }

    func setup() throws {
        let disco = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        let cams = disco.devices.filter { !$0.isContinuityCamera }
        guard let dev = cams.first else {
            throw SpikeError.noBuiltInCamera(disco.devices.map { $0.localizedName })
        }
        camName = dev.localizedName
        let input = try AVCaptureDeviceInput(device: dev)
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw SpikeError.cannotAddInput }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        // Spec config: explicit 420v output. Cap mode: no explicit key (an explicit key defeats the connection cap).
        if !capMode {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        }
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { throw SpikeError.cannotAddOutput }
        session.addOutput(output)
        let choice = try pickFormat(dev)
        try dev.lockForConfiguration()
        dev.activeFormat = choice.format
        dev.activeVideoMinFrameDuration = choice.duration
        dev.activeVideoMaxFrameDuration = choice.duration
        dev.unlockForConfiguration()
        session.commitConfiguration()
        // Set after commit: device-level durations above are ignored on this camera (delivers ~30 fps).
        // The connection-level minimum frame duration is what caps delivery at 1 fps.
        if capMode, let conn = output.connection(with: .video), conn.isVideoMinFrameDurationSupported {
            conn.videoMinFrameDuration = CMTime(value: 1, timescale: 1)
            connNote = "capMode: connection videoMinFrameDuration=1s"
        } else if capMode {
            connNote = "capMode requested but connection cap unsupported"
        } else {
            connNote = "spec: 420v output, frames dropped in delegate"
        }
        formatDesc = choice.desc + " | " + connNote
        if mode == .faceYolo || mode == .faceYolo5 || mode == .snap20 {
            let m = try loadYolo()
            let r = VNCoreMLRequest(model: m)
            r.imageCropAndScaleOption = .scaleFill
            yoloReq = r
        }
    }

    func startSession() {
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopSession() {
        sessionQueue.sync {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func beginCapture() {
        frameQueue.async {
            self.captured = false
            self.warmupEnd = uptime() + 1.0
            self.lastProcessed = -1
        }
        startSession()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delivered += 1
        let t = uptime()
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if pixFmt.isEmpty { let p = CVPixelBufferGetPixelFormatType(pb); pixFmt = String(bytes: [UInt8((p>>24)&255), UInt8((p>>16)&255), UInt8((p>>8)&255), UInt8(p&255)], encoding: .ascii) ?? "?" }
        if mode == .snap20 {
            if captured || t < warmupEnd { return }
            captured = true
            captures += 1
            processFrame(pb, runYolo: true)
            captureLog.append("capture \(captures): faces=\(lastFaces) yolo=\(lastYolo)")
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
            }
            return
        }
        if lastProcessed >= 0 && t - lastProcessed < 0.95 { return }
        lastProcessed = t
        let runYolo = mode == .faceYolo || (mode == .faceYolo5 && (processed + 1) % 5 == 0)
        processFrame(pb, runYolo: runYolo)
    }

    var lastFaces = 0
    var lastYolo = 0

    func processFrame(_ pb: CVPixelBuffer, runYolo: Bool) {
        processed += 1
        let t0 = uptime()
        let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try h.perform([faceReq]) } catch { errors += 1 }
        faceMs.append((uptime() - t0) * 1000)
        let faces = faceReq.results ?? []
        lastFaces = faces.count
        if !faces.isEmpty { faceFrames += 1 }
        faceTotal += faces.count

        var yawText = "-", pitchText = "-"
        if let f = faces.first {
            if let y = f.yaw { yawText = String(format: "%.2f", y.doubleValue) }
            if let p = f.pitch { pitchText = String(format: "%.2f", p.doubleValue) }
        }

        lastYolo = 0
        if runYolo, let yr = yoloReq {
            let t1 = uptime()
            let h2 = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            do { try h2.perform([yr]) } catch { errors += 1 }
            yoloMs.append((uptime() - t1) * 1000)
            yoloRuns += 1
            let objs = (yr.results as? [VNRecognizedObjectObservation]) ?? []
            let n = objs.filter { $0.confidence > 0.3 }.count
            lastYolo = n
            yoloDetections += n
        }

        if mode != .snap20 && processed % 10 == 0 {
            say(String(format: "t=%.0fs frame=%d faces=%d yaw=%@ pitch=%@ yoloRuns=%d",
                       uptime() - startUptime, processed, faces.count, yawText, pitchText, yoloRuns))
        }
    }

    var startUptime = uptime()

    func frontmostTick(_ state: inout (reads: Int, changes: Int, last: String)) {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        state.reads += 1
        if name != state.last {
            state.changes += 1
            state.last = name
        }
    }

    func report(wall: Double, cpuUsed: Double, frontmost: (reads: Int, changes: Int, last: String)) {
        frameQueue.sync {
            say("---- RESULT mode=\(mode.rawValue) wall=\(String(format: "%.1f", wall))s")
            say("camera: \(camName)")
            say("format: \(formatDesc)")
            say("delivered callbacks: \(delivered) (\(String(format: "%.2f", Double(delivered) / wall)) /s)")
            say("processed frames: \(processed) (\(String(format: "%.2f", Double(processed) / wall)) /s)")
            if mode == .snap20 {
                say("captures: \(captures)")
                for l in captureLog { say("  " + l) }
            }
            say("faces: frames_with_face=\(faceFrames) total_faces=\(faceTotal)")
            say(String(format: "face request avg ms=%.1f (n=%d)", faceMs.isEmpty ? 0 : faceMs.reduce(0, +) / Double(faceMs.count), faceMs.count))
            if yoloRuns > 0 {
                say(String(format: "yolo runs=%d avg ms=%.1f detections(conf>0.3)=%d",
                           yoloRuns, yoloMs.reduce(0, +) / Double(yoloMs.count), yoloDetections))
            }
            say("request errors: \(errors)")
            say("delivered pixel format: \(pixFmt)")
            say(String(format: "SELF cpu over window=%.2f%% of one core (cpu_s=%.2f)", cpuUsed / wall * 100, cpuUsed))
            say(String(format: "SELF peak RSS=%.1f MB", peakRSSMB()))
            say("frontmost polls=\(frontmost.reads) app changes=\(frontmost.changes) last=\(frontmost.last)")
        }
    }
}

// MARK: - main

let argv = CommandLine.arguments
guard argv.count >= 2, let mode = Mode(rawValue: argv[1]) else {
    say("usage: spike-perf <face|face+yolo|face+yolo5|snap20|compile> [seconds] [cap]")
    exit(2)
}
let duration = argv.count >= 3 ? (Double(argv[2]) ?? 60) : 60

if mode == .compile {
    do {
        _ = try loadYolo()
        say("YOLO compiled and cached in \(dlDir)")
        exit(0)
    } catch {
        say("COMPILE_ERROR \(error)")
        exit(1)
    }
}

let status = AVCaptureDevice.authorizationStatus(for: .video)
say("camera auth status before: \(status.rawValue) (0=notDetermined 2=denied 3=authorized)")
var authorized = status == .authorized
if status == .notDetermined {
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

let capMode = argv.count >= 4 && argv[3] == "cap"
let spike = Spike(mode: mode, capMode: capMode)
do {
    try spike.setup()
} catch {
    say("SETUP_ERROR \(error)")
    exit(4)
}
say("camera: \(spike.camName)")
say("format: \(spike.formatDesc)")

var frontState: (reads: Int, changes: Int, last: String) = (0, 0, "")
let frontTimer = DispatchSource.makeTimerSource(queue: .main)
frontTimer.schedule(deadline: .now() + 1, repeating: 1.0)
frontTimer.setEventHandler {
    let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
    frontState.reads += 1
    if name != frontState.last {
        frontState.changes += 1
        frontState.last = name
    }
}
frontTimer.resume()

let startWall = uptime()
let cpuStart = cpuSeconds()
spike.startUptime = startWall
var retainedSnapTimer: DispatchSourceTimer?

if mode == .snap20 {
    spike.beginCapture()
    let snapTimer = DispatchSource.makeTimerSource(queue: .main)
    snapTimer.schedule(deadline: .now() + 20, repeating: 20.0)
    snapTimer.setEventHandler { spike.beginCapture() }
    snapTimer.resume()
    retainedSnapTimer = snapTimer
} else {
    spike.startSession()
}

DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    frontTimer.cancel()
    retainedSnapTimer?.cancel()
    spike.stopSession()
    let wall = uptime() - startWall
    let cpuUsed = cpuSeconds() - cpuStart
    spike.report(wall: wall, cpuUsed: cpuUsed, frontmost: frontState)
    exit(0)
}

dispatchMain()

// Vision spike: one webcam-style frame -> face presence, face pose, phone presence.
// Build:  swiftc -O spike-vision.swift -o spike-vision
// Run:    /usr/bin/time -l ./spike-vision <YOLOv3TinyFP16.mlmodel> <image.jpg> [more.jpg ...]
// Compiles the .mlmodel at runtime with MLModel.compileModel(at:) (no coremlcompiler needed).

import Foundation
import Vision
import CoreML
import ImageIO
import CoreGraphics

let phoneWords = ["phone", "cell", "mobile", "smartphone", "telephone"]
let phoneYoloLabels: Set<String> = ["cell phone"]
let personYoloLabels: Set<String> = ["person"]
let runs = 3

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func elapsedMs(_ start: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: .now)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s[s.count / 2]
}

// MARK: - (a) Face rectangles + pose

func runFace(_ cg: CGImage) throws -> [VNFaceObservation] {
    let req = VNDetectFaceRectanglesRequest()
    req.revision = VNDetectFaceRectanglesRequestRevision3
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return req.results ?? []
}

// MARK: - (b) Image classification

func runClassify(_ cg: CGImage) throws -> [VNClassificationObservation] {
    let req = VNClassifyImageRequest()
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results as? [VNClassificationObservation]) ?? []
}

// MARK: - (c) YOLOv3-Tiny via Core ML

func runYolo(_ cg: CGImage, _ model: VNCoreMLModel) throws -> [VNRecognizedObjectObservation] {
    let req = VNCoreMLRequest(model: model)
    req.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    return (req.results as? [VNRecognizedObjectObservation]) ?? []
}

// MARK: - (d) Body + hand pose, used only as a phone-use proxy (wrist near face)

func runPose(_ cg: CGImage) throws -> (body: [VNHumanBodyPoseObservation], hands: [VNHumanHandPoseObservation]) {
    let body = VNDetectHumanBodyPoseRequest()
    let hand = VNDetectHumanHandPoseRequest()
    hand.maximumHandCount = 2
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([body, hand])
    let b = (body.results as? [VNHumanBodyPoseObservation]) ?? []
    let h = (hand.results as? [VNHumanHandPoseObservation]) ?? []
    return (b, h)
}

func jointPoint(_ o: VNHumanBodyPoseObservation, _ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
    guard let p = try? o.recognizedPoint(j), p.confidence > 0.3 else { return nil }
    return p.location
}

func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
    Double(hypot(a.x - b.x, a.y - b.y))
}

func fmtBox(_ r: CGRect) -> String {
    String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", r.minX, r.minY, r.width, r.height)
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: spike-vision <model.mlmodel> <image> [image ...]")
    exit(2)
}
let modelSource = URL(fileURLWithPath: args[1])
let images = Array(args[2...])

// Compile the model at runtime.
let compileStart = ContinuousClock.now
let compiledURL = try await MLModel.compileModel(at: modelSource)
let compileMs = elapsedMs(compileStart)
let mlModel = try MLModel(contentsOf: compiledURL)
let vnModel = try VNCoreMLModel(for: mlModel)
print(String(format: "YOLO compile: %.0f ms (one-time)", compileMs))

// (b) Known classifications matching phone-like words, printed once.
let classifyRevision = VNClassifyImageRequest().revision
let known = try VNClassifyImageRequest.knownClassifications(forRevision: classifyRevision)
let phoneKnown = known.map { $0.identifier }.filter { id in
    phoneWords.contains { id.lowercased().contains($0) }
}
print("VNClassifyImageRequest revision \(classifyRevision): \(known.count) known labels")
print("Phone-like known labels: \(phoneKnown)")
print("")

// Warm-up on the first image for every method.
if let first = loadCGImage(images[0]) {
    _ = try runFace(first)
    _ = try runClassify(first)
    _ = try runYolo(first, vnModel)
    _ = try runPose(first)
}

var timing: [String: [Double]] = ["face": [], "classify": [], "yolo": [], "pose": []]

for path in images {
    print("=== \(URL(fileURLWithPath: path).lastPathComponent)")
    guard let cg = loadCGImage(path) else {
        print("  cannot load image")
        continue
    }

    // (a) face
    var faces: [VNFaceObservation] = []
    var faceTimes: [Double] = []
    for _ in 0..<runs {
        let t = ContinuousClock.now
        faces = try runFace(cg)
        faceTimes.append(elapsedMs(t))
    }
    timing["face"]!.append(median(faceTimes))
    print(String(format: "  face: count=%d  (%.1f ms median)", faces.count, median(faceTimes)))
    for f in faces {
        let yaw = f.yaw.map { String(format: "%.2f", $0.doubleValue) } ?? "nil"
        let pitch = f.pitch.map { String(format: "%.2f", $0.doubleValue) } ?? "nil"
        let roll = f.roll.map { String(format: "%.2f", $0.doubleValue) } ?? "nil"
        print("    conf=\(String(format: "%.2f", f.confidence)) yaw=\(yaw) pitch=\(pitch) roll=\(roll) box[\(fmtBox(f.boundingBox))]")
    }

    // (b) classification
    var classes: [VNClassificationObservation] = []
    var classTimes: [Double] = []
    for _ in 0..<runs {
        let t = ContinuousClock.now
        classes = try runClassify(cg)
        classTimes.append(elapsedMs(t))
    }
    timing["classify"]!.append(median(classTimes))
    let top = classes.prefix(5).map { "\($0.identifier)=\(String(format: "%.2f", $0.confidence))" }
    let phoneHits = classes.filter { c in phoneWords.contains { c.identifier.lowercased().contains($0) } }
    let phoneHitStr = phoneHits.isEmpty ? "none above threshold list" : phoneHits.map { "\($0.identifier)=\(String(format: "%.3f", $0.confidence))" }.joined(separator: ", ")
    print(String(format: "  classify (%.1f ms median) top: %@", median(classTimes), top.joined(separator: ", ")))
    print("    phone-like labels: \(phoneHitStr)")

    // (c) YOLOv3-Tiny
    var dets: [VNRecognizedObjectObservation] = []
    var yoloTimes: [Double] = []
    for _ in 0..<runs {
        let t = ContinuousClock.now
        dets = try runYolo(cg, vnModel)
        yoloTimes.append(elapsedMs(t))
    }
    timing["yolo"]!.append(median(yoloTimes))
    print(String(format: "  yolo (%.1f ms median)", median(yoloTimes)))
    for d in dets {
        guard let top = d.labels.first else { continue }
        if phoneYoloLabels.contains(top.identifier) || personYoloLabels.contains(top.identifier) {
            print(String(format: "    %@ conf=%.2f box[%@]", top.identifier, top.confidence, fmtBox(d.boundingBox)))
        }
    }
    let yoloPhone = dets.filter { phoneYoloLabels.contains($0.labels.first?.identifier ?? "") }.count
    let yoloPerson = dets.filter { personYoloLabels.contains($0.labels.first?.identifier ?? "") }.count
    print("    summary: cell phone=\(yoloPhone) person=\(yoloPerson)")

    // (d) pose proxy: wrist-to-nose distance and nose-vs-shoulder height, both in shoulder-width units
    var poseTimes: [Double] = []
    var pose = try runPose(cg)
    for _ in 0..<runs {
        let t = ContinuousClock.now
        pose = try runPose(cg)
        poseTimes.append(elapsedMs(t))
    }
    timing["pose"]!.append(median(poseTimes))
    print(String(format: "  pose (%.1f ms median): bodies=%d hands=%d", median(poseTimes), pose.body.count, pose.hands.count))
    for b in pose.body {
        guard let nose = jointPoint(b, .nose),
              let ls = jointPoint(b, .leftShoulder), let rs = jointPoint(b, .rightShoulder) else {
            print("    body: nose or shoulders not confident")
            continue
        }
        let shoulderW = dist(ls, rs)
        let mid = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
        let headRatio = shoulderW > 0 ? (nose.y - mid.y) / shoulderW : 0   // lower = head dropped toward chest
        let wrists = [jointPoint(b, .leftWrist), jointPoint(b, .rightWrist)].compactMap { $0 }
        let wristNose = shoulderW > 0 ? (wrists.map { dist($0, nose) / shoulderW }.min() ?? -1) : -1
        print(String(format: "    body: headRatio=%.2f minWristToNose=%.2f (shoulderW units; wrist -1 = not seen)", headRatio, wristNose))
    }
    for h in pose.hands {
        if let w = try? h.recognizedPoint(.wrist), w.confidence > 0.3 {
            print(String(format: "    hand wrist at x=%.2f y=%.2f conf=%.2f", w.location.x, w.location.y, w.confidence))
        }
    }
    print("")
}

print("MEDIAN ms per frame across images (face | classify | yolo | pose):")
for key in ["face", "classify", "yolo", "pose"] {
    let v = timing[key]!
    if !v.isEmpty { print(String(format: "  %@: %.1f", key, median(v))) }
}

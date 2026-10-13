// Phone detection spike with Hugging Face Core ML detectors (YOLO26s end-to-end, RF-DETR Nano).
// Build:  swiftc -O spike-hf.swift -o spike-hf
// Run:    /usr/bin/time -l ./spike-hf <model.mlpackage|.mlmodelc> <image.jpg> [more.jpg ...]
// Model kind is inferred from output names: "coordinates"+"confidence" = RF-DETR, otherwise YOLO26 end2end [1,300,6].
// Preprocessing and inference go through VNCoreMLRequest (scaleFill, stretched to the model input size).
// Raw feature outputs are read through VNCoreMLFeatureValueObservation because these models have no
// Vision-native (VNRecognizedObjectObservation) output, so decoding is done here.

import Foundation
import Vision
import CoreML
import ImageIO
import CoreGraphics

let phoneCocoId = 77   // COCO category id "cell phone" (YOLO26 end2end names[67]; RF-DETR uses COCO category ids)
let personCocoId = 1   // COCO category id "person" (YOLO26 names[0])
let yoloPhoneIdx = 67, yoloPersonIdx = 0
let runs = 5
let scoreThreshold: Float = 0.25

let cocoNames = ["person","bicycle","car","motorcycle","airplane","bus","train","truck","boat","traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat","dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball","kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket","bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple","sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair","couch","potted plant","bed","dining table","toilet","tv","laptop","mouse","remote","keyboard","cell phone","microwave","oven","toaster","sink","refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"]

struct Det { let label: String; let score: Float; let box: CGRect }  // box in normalized [0,1] top-left coords

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func ms(_ start: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: .now)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }

func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

func value(_ a: MLMultiArray, _ idx: [Int]) -> Float {
    a[idx.map { NSNumber(value: $0) }].floatValue
}

// Runs the model through Vision and returns the raw named outputs.
func runModel(_ cg: CGImage, _ vn: VNCoreMLModel) throws -> [String: MLMultiArray] {
    let req = VNCoreMLRequest(model: vn)
    req.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    var out: [String: MLMultiArray] = [:]
    for obs in (req.results ?? []) {
        if let f = obs as? VNCoreMLFeatureValueObservation, let arr = f.featureValue.multiArrayValue {
            out[f.featureName] = arr
        }
    }
    return out
}

// YOLO26 end2end: [1, 300, 6] rows of x1,y1,x2,y2,score,class in 640px input space.
func decodeYolo(_ o: [String: MLMultiArray], inputSize: Double) -> [Det] {
    guard let a = o.values.first else { return [] }
    var dets: [Det] = []
    let n = a.shape[1].intValue
    for i in 0..<n {
        let score = value(a, [0, i, 4])
        guard score >= scoreThreshold else { continue }
        let cls = Int(value(a, [0, i, 5]).rounded())
        let x1 = Double(value(a, [0, i, 0])) / inputSize, y1 = Double(value(a, [0, i, 1])) / inputSize
        let x2 = Double(value(a, [0, i, 2])) / inputSize, y2 = Double(value(a, [0, i, 3])) / inputSize
        let label = cls >= 0 && cls < cocoNames.count ? cocoNames[cls] : "cls\(cls)"
        dets.append(Det(label: label, score: score, box: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)))
    }
    return dets
}

// RF-DETR: coordinates [300, 4] (cx, cy, w, h normalized), confidence [300, 91] (sigmoid if negative logits).
func decodeRFDETR(_ o: [String: MLMultiArray]) -> [Det] {
    guard let boxes = o["coordinates"], let conf = o["confidence"] else { return [] }
    // RF-DETR outputs have no batch axis: coordinates [300, 4], confidence [300, 91].
    let n = boxes.shape[0].intValue, c = conf.shape[1].intValue
    var anyNeg = false
    for i in 0..<min(n, 50) where value(conf, [i, 1]) < 0 { anyNeg = true }
    var dets: [Det] = []
    let names = [1: "person", 77: "cell phone", 73: "laptop", 3: "car"]   // COCO category ids (91-index)
    for i in 0..<n {
        var bestC = 0; var bestS: Float = -1
        for k in 0..<c {
            let s = anyNeg ? sigmoid(value(conf, [i, k])) : value(conf, [i, k])
            if s > bestS { bestS = s; bestC = k }
        }
        guard bestS >= scoreThreshold else { continue }
        let cx = Double(value(boxes, [i, 0])), cy = Double(value(boxes, [i, 1]))
        let w = Double(value(boxes, [i, 2])), h = Double(value(boxes, [i, 3]))
        let label = names[bestC] ?? "cls\(bestC)"
        dets.append(Det(label: label, score: bestS, box: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)))
    }
    return dets
}

func fmt(_ r: CGRect) -> String { String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", r.minX, r.minY, r.width, r.height) }

// MARK: main
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: spike-hf <model> <image> [image ...]"); exit(2) }
let source = URL(fileURLWithPath: args[1])
let images = Array(args[2...])

let compileStart = ContinuousClock.now
let compiledURL: URL = source.pathExtension == "mlmodelc" ? source : try await MLModel.compileModel(at: source)
let compileMs = ms(compileStart)
let config = MLModelConfiguration()
config.computeUnits = .all
let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
let vn = try VNCoreMLModel(for: mlModel)
let outNames = Set(mlModel.modelDescription.outputDescriptionsByName.keys)
let isRFDETR = outNames.contains("coordinates") && outNames.contains("confidence")
let inputSize: Double = isRFDETR ? 384 : 640
print(String(format: "model: %@ (%@) compile %.0f ms (one-time)", source.lastPathComponent, isRFDETR ? "RF-DETR" : "YOLO26 end2end", compileMs))

func decode(_ o: [String: MLMultiArray]) -> [Det] { isRFDETR ? decodeRFDETR(o) : decodeYolo(o, inputSize: inputSize) }

// Warm-up
if let first = loadCGImage(images[0]) { _ = try runModel(first, vn) }

var times: [Double] = []
for path in images {
    print("=== \(URL(fileURLWithPath: path).lastPathComponent)")
    guard let cg = loadCGImage(path) else { print("  cannot load"); continue }
    var outs: [String: MLMultiArray] = [:]
    var runTimes: [Double] = []
    for _ in 0..<runs {
        let t = ContinuousClock.now
        outs = try runModel(cg, vn)
        runTimes.append(ms(t))
    }
    times.append(median(runTimes))
    let dets = decode(outs).sorted { $0.score > $1.score }
    let phones = dets.filter { $0.label == "cell phone" }
    let persons = dets.filter { $0.label == "person" }
    print(String(format: "  %.1f ms median (VNCoreMLRequest, incl. resize)", median(runTimes)))
    print("  person: \(persons.count) (max \(String(format: "%.2f", persons.first?.score ?? 0)))  cell phone: \(phones.count) (max \(String(format: "%.2f", phones.first?.score ?? 0)))")
    for p in phones.prefix(3) { print("    cell phone \(String(format: "%.2f", p.score)) box[\(fmt(p.box))]") }
    let top = dets.prefix(4).map { "\($0.label)=\(String(format: "%.2f", $0.score))" }
    print("  top: \(top.joined(separator: ", "))")
}
print(String(format: "MEDIAN ms/frame across images: %.1f", median(times)))

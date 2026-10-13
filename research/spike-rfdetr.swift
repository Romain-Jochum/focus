// Phone detection spike: RF-DETR (Core ML, any size) and YOLO26s (Core ML) on the same six test frames.
// Build:  swiftc -O spike-rfdetr.swift -o spike-rfdetr
// Run:    /usr/bin/time -l ./spike-rfdetr <model.mlpackage|.mlmodelc> <hold-seconds> <image.jpg> [more.jpg ...]
//         footprint -p <pid> while the process is holding (after the timing loop) gives phys_footprint.
//
// Two input paths, chosen from the model's input description:
//   - image input (Vision-native, e.g. YOLO26s, mlboydaisuke RF-DETR Nano): VNCoreMLRequest with scaleFill.
//   - multiArray input (kortexa-ai RF-DETR "tensors" [1,3,N,N]): our own resize to NxN, RGB in [0,1],
//     ImageNet mean/std, NCHW float32.
// Two output layouts:
//   - YOLO26 end2end [1,300,6]: x1,y1,x2,y2,score,class in input-pixel space.
//   - RF-DETR: a box tensor with last dim 4 (cx,cy,w,h normalized) and a logit tensor with last dim 91
//     (COCO sparse category ids 1...90). Sigmoid applied when negative logits are seen. Flattened
//     query x class pairs are sorted and the top 300 kept, then thresholded (RF-DETR has no NMS).

import Foundation
import Vision
import CoreML
import ImageIO
import CoreGraphics

let scoreThreshold: Float = 0.25
let runs = 5
let phoneName = "cell phone"
let cocoNames = ["person","bicycle","car","motorcycle","airplane","bus","train","truck","boat","traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat","dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball","kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket","bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple","sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair","couch","potted plant","bed","dining table","toilet","tv","laptop","mouse","remote","keyboard","cell phone","microwave","oven","toaster","sink","refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"]

// COCO category ids (1...90, sparse; gaps are unused) as used by RF-DETR's 91-way head.
let cocoNames91: [Int: String] = [
    1: "person",
    2: "bicycle",
    3: "car",
    4: "motorcycle",
    5: "airplane",
    6: "bus",
    7: "train",
    8: "truck",
    9: "boat",
    10: "traffic light",
    11: "fire hydrant",
    13: "stop sign",
    14: "parking meter",
    15: "bench",
    16: "bird",
    17: "cat",
    18: "dog",
    19: "horse",
    20: "sheep",
    21: "cow",
    22: "elephant",
    23: "bear",
    24: "zebra",
    25: "giraffe",
    27: "backpack",
    28: "umbrella",
    31: "handbag",
    32: "tie",
    33: "suitcase",
    34: "frisbee",
    35: "skis",
    36: "snowboard",
    37: "sports ball",
    38: "kite",
    39: "baseball bat",
    40: "baseball glove",
    41: "skateboard",
    42: "surfboard",
    43: "tennis racket",
    44: "bottle",
    46: "wine glass",
    47: "cup",
    48: "fork",
    49: "knife",
    50: "spoon",
    51: "bowl",
    52: "banana",
    53: "apple",
    54: "sandwich",
    55: "orange",
    56: "broccoli",
    57: "carrot",
    58: "hot dog",
    59: "pizza",
    60: "donut",
    61: "cake",
    62: "chair",
    63: "couch",
    64: "potted plant",
    65: "bed",
    67: "dining table",
    70: "toilet",
    72: "tv",
    73: "laptop",
    74: "mouse",
    75: "remote",
    76: "keyboard",
    77: "cell phone",
    78: "microwave",
    79: "oven",
    80: "toaster",
    81: "sink",
    82: "refrigerator",
    84: "book",
    85: "clock",
    86: "vase",
    87: "scissors",
    88: "teddy bear",
    89: "hair drier",
    90: "toothbrush"
]

struct Det { let label: String; let score: Float; let box: CGRect }

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func ms(_ start: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: .now)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

// Reads any numeric MLMultiArray into a flat Float array in logical (row-major) order.
// Honors the array's strides: ANE/GPU outputs are often padded, so raw dataPointer order is not logical order.
func flatten(_ a: MLMultiArray) -> [Float] {
    let shape = a.shape.map { $0.intValue }, strides = a.strides.map { $0.intValue }
    let dims = shape.count
    var out = [Float](); out.reserveCapacity(a.count)
    var idx = [Int](repeating: 0, count: dims)
    let raw = a.dataPointer
    for _ in 0..<a.count {
        var off = 0
        for d in 0..<dims { off += idx[d] * strides[d] }
        switch a.dataType {
        case .float32: out.append(raw.load(fromByteOffset: off * 4, as: Float.self))
        case .float16: out.append(Float(raw.load(fromByteOffset: off * 2, as: Float16.self)))
        case .double: out.append(Float(raw.load(fromByteOffset: off * 8, as: Double.self)))
        default: out.append(a[idx.map { NSNumber(value: $0) }].floatValue)
        }
        var d = dims - 1
        while d >= 0 { idx[d] += 1; if idx[d] < shape[d] { break }; idx[d] = 0; d -= 1 }
    }
    return out
}

// NCHW float32 tensor, stretched to size x size (same as Vision scaleFill), ImageNet normalized.
func makeTensor(_ cg: CGImage, size: Int) throws -> MLMultiArray {
    let w = size, h = size
    let buf = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
    defer { buf.deallocate() }
    guard let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "ctx", code: 1) }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
    let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
    let out = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * w * h)
    let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
    for y in 0..<h { for x in 0..<w {
        let s = (y * w + x) * 4
        for c in 0..<3 {
            out[c * w * h + y * w + x] = (Float(px[s + c]) / 255 - mean[c]) / std[c]
        }
    } }
    return arr
}

func decodeYolo(_ o: [String: MLMultiArray], inputSize: Double) -> [Det] {
    guard let a = o.values.first else { return [] }
    let v = flatten(a)
    let n = a.shape[1].intValue
    var dets: [Det] = []
    for i in 0..<n {
        let score = v[i * 6 + 4]
        guard score >= scoreThreshold else { continue }
        let cls = Int(v[i * 6 + 5].rounded())
        let x1 = Double(v[i * 6]) / inputSize, y1 = Double(v[i * 6 + 1]) / inputSize
        let x2 = Double(v[i * 6 + 2]) / inputSize, y2 = Double(v[i * 6 + 3]) / inputSize
        let label = cls >= 0 && cls < cocoNames.count ? cocoNames[cls] : "cls\(cls)"
        dets.append(Det(label: label, score: score, box: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)))
    }
    return dets
}

// RF-DETR: boxes [..., N, 4] (cx,cy,w,h normalized), logits [..., N, C] with C = 91 COCO sparse ids.
func decodeRFDETR(boxesA: MLMultiArray, logitsA: MLMultiArray) -> [Det] {
    let boxes = flatten(boxesA), logits = flatten(logitsA)
    let n = boxesA.shape[boxesA.shape.count - 2].intValue
    let c = logitsA.shape[logitsA.shape.count - 1].intValue
    let anyNeg = logits.prefix(4000).contains { $0 < 0 }
    var cands: [(i: Int, k: Int, s: Float)] = []
    for i in 0..<n {
        for k in 0..<c {
            let raw = logits[i * c + k]
            let s = anyNeg ? sigmoid(raw) : raw
            if s >= scoreThreshold { cands.append((i, k, s)) }
        }
    }
    cands.sort { $0.s > $1.s }
    var dets: [Det] = []
    for cand in cands.prefix(n) {
        let cx = Double(boxes[cand.i * 4]), cy = Double(boxes[cand.i * 4 + 1])
        let w = Double(boxes[cand.i * 4 + 2]), h = Double(boxes[cand.i * 4 + 3])
        let label = cocoNames91[cand.k] ?? "cls\(cand.k)"
        dets.append(Det(label: label, score: cand.s, box: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)))
    }
    return dets
}

func fmt(_ r: CGRect) -> String { String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", r.minX, r.minY, r.width, r.height) }

// MARK: main
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 4, let holdSeconds = Double(args[2]) else {
    print("usage: spike-rfdetr <model> <hold-seconds> <image> [image ...]"); exit(2)
}
let source = URL(fileURLWithPath: args[1])
let images = Array(args[3...])

let compileStart = ContinuousClock.now
let compiledURL: URL = source.pathExtension == "mlmodelc" ? source : try await MLModel.compileModel(at: source)
let compileMs = ms(compileStart)
let config = MLModelConfiguration()
// Default .cpuAndNeuralEngine (as the task asked). COMPUTE=all|cpu|gpu|ane overrides, for placement experiments only.
switch ProcessInfo.processInfo.environment["COMPUTE"] ?? "" {
case "all": config.computeUnits = .all
case "cpu": config.computeUnits = .cpuOnly
case "gpu": config.computeUnits = .cpuAndGPU
case "ane": config.computeUnits = .cpuAndNeuralEngine
default: config.computeUnits = .cpuAndNeuralEngine
}
let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
let desc = mlModel.modelDescription
let outNames = Set(desc.outputDescriptionsByName.keys)
let isRFDETR = desc.outputDescriptionsByName.values.contains { $0.multiArrayConstraint?.shape.last?.intValue == 91 }  // RF-DETR logits [.., 300, 91]
let inputName = desc.inputDescriptionsByName.keys.first ?? "?"
let inputDesc = desc.inputDescriptionsByName.values.first!
let usesImageInput = inputDesc.type == .image
let inputSize: Int = usesImageInput ? (isRFDETR ? 384 : 640) : inputDesc.multiArrayConstraint!.shape.last!.intValue

print(String(format: "model: %@ compile %.0f ms (one-time), computeUnits=%d", source.lastPathComponent, compileMs, config.computeUnits.rawValue))
print("  input: \(inputName) type=\(inputDesc.type.rawValue) " + (usesImageInput ? "image" : "shape=\(inputDesc.multiArrayConstraint!.shape)"))
for (name, d) in desc.outputDescriptionsByName { print("  output: \(name) \(d.multiArrayConstraint?.shape ?? [])") }

let vn: VNCoreMLModel? = usesImageInput ? try VNCoreMLModel(for: mlModel) : nil

// One inference: returns named outputs. Preprocessing is included in the timed region.
func infer(_ cg: CGImage) throws -> [String: MLMultiArray] {
    if let vn {
        let req = VNCoreMLRequest(model: vn)
        req.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        var out: [String: MLMultiArray] = [:]
        for obs in req.results ?? [] {
            if let f = obs as? VNCoreMLFeatureValueObservation, let arr = f.featureValue.multiArrayValue {
                out[f.featureName] = arr
            }
        }
        return out
    }
    let input = try makeTensor(cg, size: inputSize)
    let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])
    let result = try mlModel.prediction(from: provider)
    var out: [String: MLMultiArray] = [:]
    for name in outNames { if let a = result.featureValue(for: name)?.multiArrayValue { out[name] = a } }
    return out
}

func decode(_ o: [String: MLMultiArray]) -> [Det] {
    if isRFDETR {
        // Pick the box tensor (last dim 4) and the logit tensor (last dim 91).
        let boxes = o.first { $0.value.shape.last?.intValue == 4 }?.value
        let logits = o.first { $0.value.shape.last?.intValue == 91 }?.value
        guard let b = boxes, let l = logits else { return [] }
        return decodeRFDETR(boxesA: b, logitsA: l)
    }
    return decodeYolo(o, inputSize: 640)
}

// Warm-up (not reported)
if let first = loadCGImage(images[0]) { _ = try infer(first) }

var times: [Double] = []
var phoneImagesHit = 0, falsePositiveImages = 0
let hasPhone: Set<String> = ["laptop1_man_typing_laptop.jpg", "phone1_man_smartphone_laptop.jpg", "phone2_concerned_phone_call.jpg", "phone3_girl_holding_smartphone.jpg"]
for path in images {
    let name = URL(fileURLWithPath: path).lastPathComponent
    print("=== \(name)")
    guard let cg = loadCGImage(path) else { print("  cannot load"); continue }
    var outs: [String: MLMultiArray] = [:]
    var runTimes: [Double] = []
    for _ in 0..<runs {
        let t = ContinuousClock.now
        outs = try infer(cg)
        runTimes.append(ms(t))
    }
    times.append(median(runTimes))
    let dets = decode(outs).sorted { $0.score > $1.score }
    let phones = dets.filter { $0.label == phoneName }
    let persons = dets.filter { $0.label == "person" }
    print(String(format: "  %.1f ms median (preprocess + predict)", median(runTimes)))
    print("  person: \(persons.count) (max \(String(format: "%.2f", persons.first?.score ?? 0)))  cell phone: \(phones.count) (max \(String(format: "%.2f", phones.first?.score ?? 0)))")
    for p in phones.prefix(3) { print("    cell phone \(String(format: "%.2f", p.score)) box[\(fmt(p.box))]") }
    let top = dets.prefix(4).map { "\($0.label)=\(String(format: "%.2f", $0.score))" }
    print("  top: \(top.joined(separator: ", "))")
    if hasPhone.contains(name) && !phones.isEmpty { phoneImagesHit += 1 }
    if !hasPhone.contains(name) && !phones.isEmpty { falsePositiveImages += 1 }
}
print(String(format: "MEDIAN ms/frame across images: %.1f", median(times)))
print("SUMMARY phone hits: \(phoneImagesHit)/4  false-positive images: \(falsePositiveImages)/2")

// Hold for footprint measurement (run `footprint -p <pid>` during this window).
print("HOLD pid=\(getpid())")
fflush(stdout)
try await Task.sleep(for: .seconds(holdSeconds))

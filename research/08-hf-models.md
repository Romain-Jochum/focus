# Hugging Face detectors for phone-in-frame detection (Core ML)

Date of research: 2026-10-12. Window: released or last substantially updated on or after 2025-10-12. Dates below are Hugging Face repo dates (createdAt and lastModified from the HF API) plus upstream dates where the model card gives them.

## Candidates

| # | Model (HF) | Upstream / release | HF repo created, last modified | Size (weights) | License | Core ML? | COCO "cell phone" | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | mlboydaisuke/YOLO26s-CoreML | YOLO26 (Ultralytics; HF upstream repo Ultralytics/YOLO26 created 2026-01-26) | 2026-08-03, 2026-08-15 | 18.2 MB (yolo26s.mlpackage, FP16) | AGPL-3.0 | Yes, .mlpackage, end-to-end (NMS-free), output [1,300,6] | Yes, class 67 | Tested, works |
| 2 | mlboydaisuke/RF-DETR-Nano-CoreML | RF-DETR Nano (Roboflow, arXiv 2511.09554, 2025) | 2026-08-03, 2026-08-15 | 102.5 MB | Apache-2.0 | Yes, .mlpackage, outputs coordinates [300,4] and confidence [300,91] | Yes, COCO id 77 | Tested, works, too big and slower |
| 3 | mlboydaisuke/YOLO11s-CoreML | YOLO11 (Ultralytics, 2024) | 2026-08-03, 2026-08-15 | about 18 MB | AGPL-3.0 | Yes, .mlpackage with built-in NMS (Vision-native outputs) | Yes | Not run |
| 4 | mlboydaisuke/YOLOv10n-CoreML | YOLOv10 (THU, 2024) | 2026-08-03, 2026-08-15 | small (nano) | AGPL-3.0 | Yes, .mlpackage | Yes | Not run |
| 5 | hugging-mac/yolov8-coreml | YOLOv8 (Ultralytics, 2023); yolov8n package | 2026-08-19, 2026-08-19 | small (nano package) | AGPL-3.0 | Yes, .mlpackage (and .zip) | Yes | Not run |

Excluded: pzoltowski/rfdetr-nano-fp16-coreml (created 2025-09-01, before the window); kortexa-ai/rf-detr-coreml (Apache-2.0, 2026-08-31, but medium and large packages, too big for the budget); YOLOX-CoreAI repos (Apache-2.0, but .aimodel format, not .mlpackage); DEIMv2 and D-FINE COCO checkpoints (ONNX or OpenVINO only); RF-DETR LiteRT and qualcomm builds (not Core ML). No HF model found that was trained specifically on phone-in-hand data; all candidates are COCO detectors, so the "cell phone" class is the only phone signal.

## Test setup

The chosen model is YOLO26s. Its package is already in Core ML format, so no conversion was needed. The Swift test script is `research/spike-hf.swift`. It compiles with swiftc -O, compiles the model at runtime with MLModel.compileModel(at:), sets computeUnits to .all, and runs each frame through VNCoreMLRequest with scaleFill. Because the output is a raw tensor (not VNRecognizedObjectObservation), the script decodes it by hand. Score threshold is 0.25. Timings are the median of 5 runs after one warm-up, and include the Vision resize.

## Results on the six test images (the spike's Wikimedia Commons set, not kept)

YOLO26s (18 MB, 640 input): empty room, no detections. Laptop1 (man typing), cell phone 0.91 on the table at the left edge. The image shows a real phone lying on the desk, so this is a true positive, but the phone is not in hand. Laptop2 (woman at laptop), no phone, 0 false positives. Phone1 (man with smartphone), cell phone 0.53. Phone2 (phone call), cell phone 0.90. Phone3 (girl holding smartphone), cell phone 0.54, box x=0.57 y=0.39 w=0.23 h=0.38. Phone present in 4 of 4 images with a phone, 0 false positives on the 2 phone-free images. Latency: 8 to 16 ms per image (median over the six images 9.3 ms, including Vision resize). Compile time at runtime 112 ms (one-time). Peak RSS 78.7 MB (/usr/bin/time -l, six-image run).

RF-DETR-Nano (102.5 MB, 384 input): same phone detections, with higher scores (0.85 to 0.93) and 4 persons on phone2. Latency 26 to 38 ms per image (median 31.8 ms, first run; 10-rfdetr.md has the later figures), which misses the 20 ms target. Peak RSS 288 MB on one image. It fails the 30 MB size target.

YOLOv3-Tiny (earlier run, not repeated here): cell phone detected in 1 of 3 phone images.

## Model kept

The working Core ML package (18 MB) and its model card came from the Hugging Face repo mlboydaisuke/YOLO26s-CoreML; neither is kept, since RF-DETR replaced YOLO26s (`10-rfdetr.md`), partly on licence.

## Recommendation

Superseded: the app ships RF-DETR nano (Apache-2.0), see 10-rfdetr.md. This section records the first-round result; the AGPL YOLO models were never shipped.

Use YOLO26s from mlboydaisuke/YOLO26s-CoreML as the phone detector. It meets the size, latency, and memory targets, and it finds phones in every test image that contains one. The license is AGPL-3.0, which is acceptable for personal use but requires source release if the app is distributed. For a commercial or distributed app, RF-DETR-Nano (Apache-2.0) is the alternative, but it fails the size and latency targets. Caveat: the detector only reports that a phone is visible. Detecting that the person is holding or using it needs a geometric rule (phone box overlapping a hand or the face from Vision pose), which is not tested here.

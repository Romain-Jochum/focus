# RF-DETR vs YOLO26s for phone detection (Core ML spike)

Date of research: 2026-10-12. Window: a model counts if it was released or last substantially updated on or after 2025-10-12. Machine: MacBook Air (Apple Silicon), macOS 26.6, Swift 6.3.3, Command Line Tools only. Machine load during timing was high (load average 13 to 21, from Spotlight indexing, ANE compiler and a camera benchmark), so latency numbers have roughly plus or minus 30 percent noise; memory numbers are stable across repeated runs.

## Sources and dates

RF-DETR has official Roboflow weights on Hugging Face in five sizes: Roboflow/rf-detr-nano, rf-detr-small, rf-detr-base, rf-detr-medium and rf-detr-large. All five were created 2026-05-11 and last modified 2026-05-20, so they pass the window. They ship as fp32 safetensors (122 to 136 MB) for the transformers path. Roboflow also has rf-detr-base-2 and seg variants, which were not tested. The RF-DETR paper is arXiv 2511.09554 (November 2025). The rfdetr Python package is at version 1.9.4 (released 2026-08-24); the package latest is 1.11.2 (2026-10-04).

Core ML exports found on Hugging Face in the window are kortexa-ai/rf-detr-coreml (Apache-2.0, created 2026-08-31, medium at 576 px and large at 704 px, FP16 ML Program, exported with rfdetr 1.9.4 and coremltools 9.0) and mlboydaisuke/RF-DETR-Nano-CoreML (Apache-2.0, created 2026-08-03, modified 2026-08-15, 384 px). The mlboydaisuke nano package gave bit-identical detections to our own nano export, which is a useful cross-check. pzoltowski/rfdetr-{nano,small,medium}-fp16-coreml exist but were created 2025-09-01, before the window, so they were excluded. No Core ML export of small or base was found, so those were converted here.

## Conversion

The rfdetr 1.9.4 export path was used for small (512 px) and base (560 px) at their native resolutions, and for nano (384 px) as an official reference. The initial attempt failed under Python 3.14 with "BlobWriter not loaded", because coremltools 9.0 has no native library for 3.14. The fix was a Python 3.12 environment managed by uv, with nothing installed globally (in `scripts/make-model.sh`). Each export took 27 to 42 seconds, and the total conversion time was about 5 minutes including the weight downloads. Every variant was under the 150 MB limit, so none was skipped. Medium and large use the kortexa packages as they are.

## Test setup

The script is `research/spike-rfdetr.swift`. It builds with swiftc -O and compiles the model at runtime with MLModel.compileModel(at:). It uses computeUnits .cpuAndNeuralEngine as requested. The COMPUTE environment variable overrides this for placement experiments only. Image-input models (YOLO26s, the mlboydaisuke nano) go through VNCoreMLRequest with scaleFill. Multi-array RF-DETR models (kortexa and our exports) use our own resize to NxN, RGB in [0,1], ImageNet mean and std, and NCHW float32, because Vision does not preprocess multi-array inputs. The decoder reads outputs stride-aware (ANE output arrays are padded), maps COCO sparse category ids 1 to 90 with the correct 91-id names, applies a sigmoid when logits are negative, keeps the top 300 query by class pairs above 0.25, and applies no NMS. Each image gets one warm-up pass and then 5 timed runs. The reported time is the median of those runs, covering preprocessing and prediction, not decoding. Memory comes from `footprint -p <pid>` taken 1 second after the timing loop while the process is still alive, which is the phys_footprint at the end. Peak footprint and RSS come from /usr/bin/time -l.

Scoring uses the six Wikimedia Commons test images from `05-vision-spike.md` (not kept). "Phone hits" counts images that contain a phone and get a cell phone detection at or above 0.25 out of 4 (laptop1, phone1, phone2, phone3). "False positives" counts images with no phone (empty1, laptop2) that get any cell phone detection, out of 2.

## Results

| Variant | Source and date | File (MB) | Footprint end (MB) | Footprint peak (MB) | RSS (MB) | Median ms | Phone hits | False positives |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| YOLO26s | mlboydaisuke, 2026-08 | 18 | 36 | 78 | 52 | 11.6 | 4/4 | 0/2 |
| RF-DETR nano (ours, rfdetr 1.9.4, 384 px) | Roboflow weights, 2026-05; export 2026-10-12 | 103 | 68 | 81 | 236 | 44 to 48 | 4/4 | 0/2 |
| RF-DETR nano (mlboydaisuke) | 2026-08 | 103 | 18 | 79 | 246 | 44 | 4/4 | 0/2 |
| RF-DETR small (ours, 512 px) | Roboflow weights, 2026-05; export 2026-10-12 | 109 | 113 | 152 | 298 | 94 | 4/4 | 0/2 |
| RF-DETR base (ours, 560 px) | Roboflow weights, 2026-05; export 2026-10-12 | 103 | 131 | 209 | 312 | 116 to 175 | 4/4 | 0/2 |
| RF-DETR medium (kortexa, 576 px) | kortexa-ai, 2026-08-31 | 58 | 159 | 160 | 175 | 28 to 37 | 4/4 | 0/2 |
| RF-DETR large (kortexa, 704 px) | kortexa-ai, 2026-08-31 | 58 | 224 | 225 | 173 | 62 | 4/4 | 0/2 |

Per-image phone confidence (laptop1 / phone1 / phone2 / phone3). YOLO26s: 0.91 / 0.53 / 0.90 / 0.54. RF-DETR nano (ours and mlboydaisuke): 0.92 / 0.93 / 0.88 / 0.85. RF-DETR small: 0.94 / 0.95 / 0.90 / 0.77. RF-DETR base: 0.91 / 0.91 / 0.88 / 0.80. RF-DETR medium: 0.93 / 0.95 / 0.78 / 0.69. RF-DETR large: 0.93 / 0.94 / 0.86 / 0.82. The empty room and laptop2 images produced no cell phone detections for any model. The phone on the desk in laptop1 is a real phone, so it counts as a hit.

Placement matters for memory. Medium with computeUnits .all rose to 206 MB footprint, against 159 MB with .cpuAndNeuralEngine. The FP16 weights of the kortexa and Roboflow exports appear to run on the CPU path and expand to FP32 there, which explains the large MALLOC_LARGE regions in the footprint reports. The nano packages run mostly on the ANE, so their weights stay out of the process footprint. This makes RF-DETR nano much lighter at rest (18 to 68 MB) than the larger sizes.

## Recommendation

The whole-app budget of under 200 MB leaves about 100 MB for the model. Only the nano sizes fit, since medium, small, base and large all peak above 150 MB. Between YOLO26s and RF-DETR nano, peak footprint is nearly equal (78 vs 79 to 81 MB), so the choice is about confidence, speed, and licence. RF-DETR nano has higher phone confidence (0.85 to 0.93 against 0.53 to 0.90, with phone1 and phone3 much stronger), is Apache-2.0 instead of AGPL-3.0, and needs no NMS, at about 45 ms per frame, which is inside the 60 ms budget for a once-per-second to once-per-ten-second cadence. YOLO26s is about four times faster and uses half the resting footprint, so it is the choice if the licence is acceptable and resting memory matters more than confidence.

The comparison reference was the official-export nano at 384 px (103 MB on disk); the app uses its FP16 export (52 MB), produced by `scripts/make-model.sh` (not committed, see `docs/design.md`). It is the same output as the mlboydaisuke package. Caveat: all these detectors are COCO models, and the test set has only four phone images, so "phone in hand" detection still needs a geometric rule that is not tested here.

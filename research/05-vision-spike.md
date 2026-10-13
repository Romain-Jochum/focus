# Vision spike: face, gaze proxy and phone detection from one frame

Empirical spike on macOS 26.6, Swift 6.3.3, Command Line Tools only. No webcam was accessed. All inputs are still images from Wikimedia Commons, resized to 1280 px wide to mimic a laptop camera frame. The sample is tiny (3 phone, 2 laptop, 1 empty), so treat the numbers as a feasibility check, not as accuracy figures.

Script: `research/spike-vision.swift`. Build with `swiftc -O spike-vision.swift -o spike-vision`, run with `/usr/bin/time -l ./spike-vision YOLOv3TinyFP16.mlmodel <images...>`. The model is compiled at runtime with MLModel.compileModel(at:); the one-time compile took about 216 ms.

## Model download that worked

The YOLOv3-Tiny FP16 model is at https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel (HTTP 200, 17,769,580 bytes). The URL is taken from the model gallery at https://developer.apple.com/machine-learning/models/. A guessed `/Model/` sub-path returned 403. The Int8LUT variant was not tested because FP16 was enough for the spike.

## Test images

| File (spike folder, not kept) | Content | Source (Wikimedia Commons) | License |
|---|---|---|---|
| phone1_man_smartphone_laptop.jpg | Man from behind at a laptop, holding a smartphone | File:Man with smartphone and laptop (Unsplash).jpg | CC0 |
| phone2_concerned_phone_call.jpg | Person on a phone call, face partly turned | File:Concerned Phone Call (Unsplash).jpg | CC0 |
| phone3_girl_holding_smartphone.jpg | Face visible, phone held in hand | File:Girl Holding a Smartphone.jpg | CC BY-SA 4.0 |
| laptop1_man_typing_laptop.jpg | Close-up of hands typing, no face | File:Man typing on laptop (Unsplash).jpg | CC0 |
| laptop2_woman_home_office_laptop.jpg | Woman at a desk with a laptop | File:Woman sits at desk working on laptop in home office.jpg | CC BY 2.0 |
| empty1_empty_room.jpg | Empty room, no person | File:Empty Room (Unsplash).jpg | CC0 |

Commons pages are at https://commons.wikimedia.org/wiki/File:<name>. Rejected candidates were "Person looks down at phone (Unsplash)", which is too far from the camera, and "Desks in an open office space", which contains a person.

## Results

Timings are medians of 3 runs per image, measured with ContinuousClock after a warm-up pass. Two full runs gave about 7 to 10 ms per call on the first run and 9 to 27 ms on the second. The second run was noisier, so the ranges below are approximate.

| Method | Detects phone? | Looking-down signal? | ms per frame | Model size |
|---|---|---|---|---|
| VNDetectFaceRectanglesRequest, revision 3 | Not applicable | Yes, via yaw and pitch (radians). Found faces in 3 of 6 frames. Pitch sign convention not verified. | about 7 to 20 | None (built into Vision) |
| VNClassifyImageRequest | No. Phone-like labels stayed at or below 0.014 on phone images, and "phone" scored 0.070 on the empty room. | No | about 7 to 20 | None (built into Vision) |
| YOLOv3-Tiny FP16 via VNCoreMLRequest | Partly. "cell phone" 0.98 in 1 of 3 phone images. Missed the phone in the other two. | No. Gives person boxes only. | about 7 to 17 | 16.9 MB |
| Body and hand pose (proxy) | Not directly. Hand detected in 5 frames. Body pose failed on partial bodies. | Head-ratio value computed, but not validated on any frame | about 9 to 25 | None (built into Vision) |

Peak RSS for the full six-image process was about 210 to 214 MB ("maximum resident set size" from /usr/bin/time -l). Peak memory footprint was about 263 MB.

Per-frame highlights:

- Face detection found the frontal girl (yaw 0.48, pitch 0.27) and the turned face in the call photo (yaw -1.04). It correctly found no face in the back-view and empty-room frames.
- YOLO found "person" in every frame that showed a person's body, but missed the back-view man in phone1 entirely.
- The classifier's top labels were scene-level ("machine", "consumer_electronics", "people"). It never produced a usable phone label.

## Verdict

Face presence is cheap and reliable enough on these frames. Use VNDetectFaceRectanglesRequest revision 3 for presence, and treat yaw and pitch as a rough gaze-down proxy that needs calibration on real webcam frames. Phone detection is not reliable from one frame with these tools. YOLO hit 1 of 3 phone frames, and the classifier is noise. Do not gate on phone presence until it is tested on real webcam footage. The best next step is a short recorded clip of real desk sessions, labelled by hand, with a threshold sweep on face pitch and YOLO cell phone confidence.

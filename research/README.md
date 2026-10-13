# Research

The studies and spikes behind the numbers in `docs/design.md`, from 2026-10-12 and 2026-10-13. Spike sources are single-file Swift programs (`swiftc -O <file>`, run from a scratch folder); their inputs, models and logs were not kept, the write-ups hold the results.

The numbering skips 01 and 09: those notes were not kept.

| Doc | What it settled |
|---|---|
| [02-focus-science.md](02-focus-science.md) | Which interventions restore focus, what backfires, and the design parameters taken from them |
| [03-existing-solutions.md](03-existing-solutions.md) | Existing focus, blocking and camera-based apps: what they do, their gaps, ideas worth taking |
| [04-macos-tech.md](04-macos-tech.md) | macOS APIs for activity detection and the camera check, and packaging without Xcode |
| [05-vision-spike.md](05-vision-spike.md) | Apple Vision faces, gaze proxy and phone detection from one frame (`spike-vision.swift`) |
| [06-safari-youtube.md](06-safari-youtube.md) | Hiding YouTube recommendations: injected CSS rather than Safari extensions |
| [07-perf-spike.md](07-perf-spike.md) | CPU and memory of camera analysis at different cadences (`spike-perf.swift`, `spike-perf2.swift`) |
| [08-hf-models.md](08-hf-models.md) | Hugging Face phone detectors under a year old (`spike-hf.swift`) |
| [10-rfdetr.md](10-rfdetr.md) | RF-DETR sizes and precisions versus YOLO26s; nano FP16 chosen (`spike-rfdetr.swift`) |
| [11-iphone-ble.md](11-iphone-ble.md) | Reading iPhone use from its Bluetooth advert, and recognising the owner's iPhone |
| [12-progression.md](12-progression.md) | XP, losses, streaks and the multiplier from the evidence; 100 levels paced for a year, by simulation |
| [13-garden.md](13-garden.md) | The garden's look (Kenney Nature Kit), SceneKit rendering in a child process, Core Animation, and what it costs |

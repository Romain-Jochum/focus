# Performance spike: 1 fps webcam analysis plus frontmost-app polling

Measured on a MacBook Air (arm64, macOS 26.6, Swift 6.3.3, Command Line Tools only). Source: `research/spike-perf.swift`, built with `swiftc -O` and an embedded Info.plist carrying `NSCameraUsageDescription`. Raw logs and samples were not kept. Each mode ran 60 s. The camera was already authorized for Terminal, so no permission retry was needed.

## Verdict

Continuous 1 fps analysis does not fit the budget. Every continuous configuration measured above 3% CPU (3.75% to 6.0%), and the face+YOLO configuration peaked at 207 MB RSS, over the 200 MB limit. The cheapest measured config was `snap20`, at 3.1% CPU and 201.5 MB, which is marginal on both counts.

## Results (60 s windows)

CPU is the process's own rusage over the run window, as a percent of one core. "ps CPU" is the average of the 5 s `ps -o %cpu` samples. GPU is system-wide `Device Utilization %` from IOAccelerator, and is not resolvable against this baseline (see caveats).

| Mode | Config | CPU (self) | ps CPU avg | Peak RSS (self) | GPU mean (delta vs baseline) | Processed fps | Delivered fps |
|---|---|---|---|---|---|---|---|
| baseline (nothing running) | none | n/a | n/a | n/a | 32.0 (range 29-50) | n/a | n/a |
| face | 420v, delegate drops to 1/s | 4.56% | 2.42% | 168.7 MB | 17.1 (-14.9) | 1.03 | 29.6 |
| face+yolo | 420v, delegate drops to 1/s | 4.71% | 4.95% | 206.7 MB | 9.3 (-22.7) | 1.03 | 29.8 |
| face+yolo5 | 420v, YOLO every 5th frame | 3.75% | 6.63% | 181.1 MB | 7.3 (-24.7) | 1.03 | 29.8 |
| snap20 | session start every 20 s, 1 s warm-up, 1 frame, stop | 3.11% | 8.99% | 201.5 MB | 5.9 (-26.1) | 0.05 (3 captures) | 0.93 |
| face+yolo, cap | 2vuy, connection min frame duration 1 s | 6.04% | 6.58% | 188.0 MB | 20.5 (-11.5) | 0.96 | 0.98 |
| face, cap | 2vuy, connection min frame duration 1 s | 5.33% | 4.90% | 167.5 MB | 15.3 (-16.7) | 0.98 | 0.98 |

## Camera format and frame rate

The built-in camera exposes seven formats, all with a 420v subtype and all with a minimum of 15 fps. The lowest-resolution format is 640x480. The spec configuration uses that format with 420v output and sets the device frame duration to 1/15 s, the lowest rate the format supports. The camera still delivers about 30 fps to the delegate, and the delegate drops frames down to 1 processed frame per second. Setting the device-level frame duration does not cap delivery on this camera.

A connection-level `videoMinFrameDuration` of 1 s does cap delivery to about 1 fps, but only when the output has no explicit pixel format. With the explicit 420v key the cap is ignored, so the cap configurations deliver 2vuy frames instead. Those configurations measured higher CPU than the spec configuration, not lower. The likely reason is that Vision does more work converting 2vuy (its face request averaged 33 ms against 10 ms for 420v), but this was not profiled.

## Camera light

The green indicator should be solid on for the whole of each continuous run, because the sensor streams at about 30 fps internally even though only 1 frame per second is analysed. This was reasoned from the delivered frame counts, not observed. In `snap20` the light should come on for roughly 2 to 3 s per capture (start, 1 s warm-up, one frame, stop), and go off between captures, three times in 60 s. Someone was at the machine, but this was not visually confirmed.

## Caveats

The GPU baseline is contaminated. During the 30 s idle baseline, XprotectService used about 38% CPU and a Virtualization VM about 21%, and the IOAccelerator reading swung between 29% and 50%. A 3% change cannot be resolved against that, so the GPU deltas above are not meaningful. The mode means are lower than the baseline mean, which reflects baseline noise rather than a GPU saving.

ps `%cpu` on macOS is a decayed short-term average and is spiky around session starts, so the rusage figure is the more reliable CPU number. The ps RSS maximum is close to the self-reported peak for the face+YOLO run, but for `snap20` the ps maximum (159 MB) is lower than the self-reported peak (201.5 MB), because the self figure includes the model load and the repeated session starts.

Vision's YOLOv3-Tiny ran on `.cpuAndNeuralEngine`, averaging about 9 to 15 ms per run. The compiled model was cached, so model compilation is not included in the timings.

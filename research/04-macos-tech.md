# macOS technical research for a near-zero-cost Swift menu-bar focus app

Scope: macOS 26 on Apple Silicon, Swift 6.3.3, Command Line Tools only (no Xcode). Each claim is tagged **[verified]** (seen in an Apple doc or a local check), **[partial]** (secondary source or only part confirmed), or **[unverified]** (from general knowledge, to test on device). Local checks were run on macOS 26 on 2026-10-12.

## Local environment facts

Verified with shell commands on macOS 26. `xcode-select -p` returns `/Library/Developer/CommandLineTools`. `swift --version` reports Swift 6.3.3 with target `arm64-apple-macosx26.0`. The CLT SDK directory contains `MacOSX26.5.sdk` (symlinked as `MacOSX.sdk`), and that SDK includes `FoundationModels.framework`, `Vision.framework`, `CoreML.framework`, and `ServiceManagement.framework`. `xcrun --find coremlcompiler` fails with "unable to find utility", and `coremlcompiler` is not in `/Library/Developer/CommandLineTools/usr/bin`. So the compiler is not available without Xcode. `codesign` is present in `/usr/bin`.

## A. Activity detection

### A1. Frontmost app

Use `NSWorkspace.shared.notificationCenter` with `NSWorkspace.didActivateApplicationNotification`. The notification's `userInfo[NSWorkspace.applicationUserInfoKey]` holds the `NSRunningApplication`. This is event-driven, needs no permission, and needs no polling. **[verified in general API design; standard since macOS 10.6]**

```swift
import AppKit

let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                               object: nil, queue: .main) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    print("frontmost:", app?.bundleIdentifier ?? "?", app?.localizedName ?? "?")
}
```

Recommendation: use this as the only trigger for app changes. Do not poll `NSWorkspace.shared.frontmostApplication`.

### A2. Window title of the frontmost window

The two candidate paths compare as follows.

**Accessibility (AX).** Needs the Accessibility permission (TCC service `kTCCServiceAccessibility`), checked with `AXIsProcessTrustedWithOptions`. Read the title with:

```swift
let appEl = AXUIElementCreateApplication(pid)
var win: CFTypeRef?
AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win)
var title: CFTypeRef?
AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title)
```

**CGWindowList.** `CGWindowListCopyWindowInfo` returns window dictionaries, but `kCGWindowName` for other apps is withheld unless the caller holds Screen Recording permission. Apple DTS says the call itself still succeeds without the permission and only omits the potentially private values such as `kCGWindowName`. **[partial, from Apple Developer Forums thread 839069 via search]** Screen Recording is the more invasive permission, and the window list is a full-scan call that is more expensive than an AX read.

Verdict: AX is cheaper and less invasive. Use Accessibility, not Screen Recording. Chromium's 10.15 fallback logic (name-visibility check) is a hint that CG names are gated, but no Apple doc for 10.15 specifically was found. **[partial]**

**Event-driven title changes.** Create an `AXObserver` on the app PID and subscribe to `kAXFocusedWindowChangedNotification` (window switch within an app) and `kAXTitleChangedNotification` (title change on the focused window). Add the run-loop source from `AXObserverGetRunLoopSource` to the main run loop. Re-subscribe when the frontmost app changes. This keeps the whole path event-driven. **[unverified in the sense of testing, standard AX pattern]**

```swift
var observer: AXObserver?
AXObserverCreate(pid, { _, element, notif, _ in
    // read kAXTitleAttribute of element here
} as AXObserverCallback, &observer)
let appEl = AXUIElementCreateApplication(pid)
AXObserverAddNotification(observer!, appEl, kAXFocusedWindowChangedNotification as CFString, nil)
AXObserverAddNotification(observer!, appEl, kAXTitleChangedNotification as CFString, nil)
CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer!), .defaultMode)
```

Caveat: `kAXTitleChangedNotification` is posted on the window element. For reliable coverage, subscribe on the focused window element after reading it, and re-subscribe on each `kAXFocusedWindowChangedNotification`. **[unverified]**

Caveat: AX can return `.cannotComplete` for some apps even when `AXIsProcessTrusted` is true. **[partial, Apple forums thread 794253 via search]** Handle errors and fall back to the app name.

### A3. Browser URL and tab title

Recommended per-browser stack, with cost and permission notes.

| Browser | Method | Permission | Notes |
|---|---|---|---|
| Safari | AppleScript `URL of current tab of front window` | Automation for Safari | Native scripting dictionary. **[unverified on macOS 26]** |
| Chrome, Brave | AppleScript `URL of active tab of front window` | Automation for each browser | Chromium dictionary. **[unverified]** |
| Arc | AppleScript `URL of active tab of front window` | Automation for Arc | Works in forum examples. Fails for "Little Arc" windows. **[partial, Keyboard Maestro and Hook forums via search]** |
| Firefox | No AppleScript URL access | n/a | Keyboard Maestro forum says browsers without an osascript interface cannot be reached. Use the window title only (Firefox title usually ends in the page title, not the URL). **[partial]** |

Cost: each `osascript` or `NSAppleScript` call is an IPC round trip into the target app, typically on the order of tens of milliseconds, and it wakes the target app. Run it only when A1 or A2 fires, never on a timer. Use `NSAppleScript` in-process with a precompiled script, or spawn `osascript` once per event. The Automation prompt is shown once per (controlling app, target app) pair. The Info.plist key is `NSAppleEventsUsageDescription`, and the entitlement `com.apple.security.automation.apple-events` applies only to sandboxed or hardened-runtime builds. **[partial]**

### A4. User idle time

```swift
import CoreGraphics

let anyEvent = CGEventType(rawValue: ~0)!  // kCGAnyInputEventType
let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
```

The API is `CGEventSource.secondsSinceLastEventType(_:eventType:)`. It has existed since macOS 10.4. **[partial, signature from general knowledge; Apple doc page did not render]** It is expected to need no TCC permission for the idle query, but this is **[unverified]**; test on a clean TCC database (`tccutil reset All <bundle id>`).

Recommendation: poll it only at a low rate while the user is active. Do not poll during idle. An alternative with zero polling is to subscribe to `com.apple.screensaver.didstart` and `com.apple.screensaver.didstop`, but those cover only screensaver, not idle. Use the poll sparingly (for example once per 30 s) and only while a session is running.

### A5. Lock, sleep, and wake

- Screen lock: `DistributedNotificationCenter.default()` with `"com.apple.screenIsLocked"` and `"com.apple.screenIsUnlocked"`. These distributed notifications are widely used and need no permission. **[unverified on macOS 26, standard practice]**
- Sleep and wake: `NSWorkspace.shared.notificationCenter` with `willSleepNotification`, `didWakeNotification`, and `screensDidSleepNotification`. **[unverified on macOS 26, long-standing API]**

Pause the camera timer and the AX observer on sleep or lock. Resume on wake or unlock.

## B. Camera "phone in hand" check

### B1. Single still frame on a timer

Pattern: start an `AVCaptureSession`, let auto-exposure settle, grab one frame, stop the session. Do not keep the session running between checks.

```swift
let session = AVCaptureSession()
session.sessionPreset = .medium
let dev = AVCaptureDevice.default(for: .video)!
session.addInput(try AVCaptureDeviceInput(device: dev))
let out = AVCaptureVideoDataOutput()
session.addOutput(out)
// set delegate; on the first N frames (about 1 to 2 s, 20 to 30 frames), discard;
// keep frame N, then session.stopRunning()
session.startRunning()
```

Warm-up: discard about 1 to 2 seconds of frames (about 20 to 30 at 30 fps) so auto-exposure and white balance settle. **[unverified value, standard practice]** Use `AVCapturePhotoOutput` if you want full-resolution stills. The video data path is cheaper.

Indicator: the green camera indicator and the orange privacy dot appear while the session is running and disappear after `stopRunning()`. **[unverified on macOS 26]**

Info.plist: `NSCameraUsageDescription` is required, or the app crashes on first access. **[partial, standard]**

Cost: the session start is the expensive part, not the frame. At a 60 to 120 s interval the average power is low, but the camera hardware wakes each time. **[unverified, measure with `powermetrics` or Activity Monitor Energy tab]**

### B2. Detection models

**Apple Vision built-ins.**

- `VNClassifyImageRequest` is available since macOS 10.15. **[verified, Apple doc]** It returns `VNClassificationObservation` values through `results` and exposes the label vocabulary through the class method `knownClassifications(forRevision:)`. Apple docs did not confirm a "cellphone" or "phone" label (the doc page lists no label set). **[unverified]** Test it on device:

```swift
let all = try VNClassifyImageRequest.knownClassifications(forRevision: VNClassifyImageRequestRevision1)
print(all.map(\.identifier).filter { $0.contains("phone") })
```

- `VNDetectFaceRectanglesRequest` revision 3 (introduced iOS 15) reports continuous `roll`, `pitch`, and `yaw`. Revision 2 gives roll and yaw only in discrete bins. **[partial, tutorial sources]** Pitch is the useful signal for "looking down at a phone". The face is often not detected when the head is tilted far down, so treat "no face" as a weak signal, not proof.
- `VNDetectHumanBodyPoseRequest` gives joints, which can separate "hands together at chest height" from "upright at desk". **[unverified accuracy]**

Vision built-ins avoid any model download and any Python step. Their weakness is the lack of a verified phone class.

**Apple's downloadable Core ML models** (developer.apple.com/machine-learning/models, verified on the page):

| File | Size | Direct URL |
|---|---|---|
| YOLOv3Tiny.mlmodel | 35.4 MB | `https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3Tiny.mlmodel` |
| YOLOv3TinyFP16.mlmodel | 17.7 MB | `https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel` |
| YOLOv3TinyInt8LUT.mlmodel | 8.9 MB | `https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel` |
| YOLOv3.mlmodel | 248.4 MB | `https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3.mlmodel` |

These are COCO 80-class detectors. COCO's label for a phone is "cell phone". **[unverified inside the file, COCO convention]** Verify by reading the model's `classLabels` through `MLModel(contentsOf:).modelDescription` or by running the model once. The Tiny FP16 file is the best trade-off for a background check. Expected accuracy for a phone held at desk distance is unmeasured in the sources consulted. The phone is a small object in the frame, and YOLOv3-Tiny is a weak detector, so expect misses. Measure with 50 to 100 labelled frames before trusting it.

Use Vision to run the model: wrap the `MLModel` in `VNCoreMLModel`, then `VNCoreMLRequest`. Apple's "Recognizing Objects in Live Capture" sample uses this path. **[partial]**

**Ultralytics YOLOv8n and YOLO11n.** Export is `model.export(format="coreml")`, which needs Python and `ultralytics`/`coremltools`. This is a Python step. The license is AGPL-3.0 unless you buy an enterprise license. **[partial, Ultralytics docs and general knowledge]** No verified ANE latency or file-size numbers for YOLO11n were found in the sources consulted. Using it in a closed-source app is a licensing problem, so avoid it.

**Smallest no-Python path:** download `YOLOv3TinyFP16.mlmodel` (17.7 MB) from the Apple URL above, compile it at runtime (B3), and run it through Vision. Keep the Vision face-pitch check as a second signal.

### B3. Running .mlmodel without Xcode

`xcrun coremlcompiler` is not available: it is absent from the CLT `usr/bin` and `xcrun` cannot find it (verified locally). Compile at runtime instead:

```swift
import CoreML

let src = URL(filePath: "/path/YOLOv3TinyFP16.mlmodel")
let compiledURL = try await MLModel.compileModel(at: src)  // returns .mlmodelc in a temp dir
// Copy compiledURL into Application Support to reuse it across launches.
let model = try MLModel(contentsOf: cachedURL, configuration: cfg)
```

`MLModel.compileModel(at:)` exists in the CoreML framework (async and completion-handler forms). **[partial, general knowledge; test on device]** Compile once and cache the `.mlmodelc`. Load with `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine` to use the ANE. **[unverified]**

## C. Packaging without Xcode

Planning snapshot from 2026-10-12: the shipped layout and deployment target differ, see Package.swift and the README.

### C1. SwiftUI MenuBarExtra, SwiftPM build, hand-made bundle

Package layout:

```text
focus/
  Package.swift            (platforms: [.macOS(.v14)], executableTarget "Focus")
  Sources/Focus/App.swift  (@main struct: MenuBarExtra { ... } .menuBarExtraStyle(.window))
  bundle/Info.plist
  scripts/build-app.sh     (swift build -c release; assemble Focus.app; codesign)
```

Assemble `Focus.app/Contents/MacOS/Focus`, `Contents/Info.plist`, and `Contents/Resources/`. Required Info.plist keys:

- `CFBundleIdentifier`: a fixed value such as `<bundle-id>`. Never change it. TCC keys off it.
- `CFBundleExecutable`: `Focus`
- `LSUIElement`: `true` (menu-bar only, no Dock icon)
- `LSMinimumSystemVersion`: `14.0` (MenuBarExtra needs macOS 13 or later)
- `NSCameraUsageDescription`
- `NSAppleEventsUsageDescription`

`MenuBarExtra` is available from macOS 13. **[partial, general knowledge]** `FoundationModels` needs macOS 26 (see C3).

Signing: ad-hoc signing (`codesign --sign -`) generates a new code-directory hash each build. TCC sees a new app identity and drops the Accessibility and Automation grants. **[partial, OpenClaw and similar project docs via search]** The fix is a stable self-signed code-signing certificate reused for every build:

1. Create a certificate in Keychain Access (Certificate Assistant, Create a Certificate, identity type "Self Signed Root", certificate type "Code Signing"). Or generate it with `openssl` and import with `security import`. **[unverified commands]**
2. Sign with it: `codesign --force --options runtime --sign "Focus Local Signing" --identifier <bundle-id> Focus.app`. **[unverified]**
3. Check identity: `security find-identity -v -p codesigning`.

Apple's "Apple Development" certificate needs an Apple ID signed into Xcode. Without Xcode, use the self-signed certificate. Keep the app at a fixed path (for example `~/Applications/Focus.app`). TCC also tracks the path, so moving the bundle resets grants. **[partial]**

### C2. Launch at login

```swift
import ServiceManagement
try SMAppService.mainApp.register()   // macOS 13+
// SMAppService.mainApp.status: .enabled, .notRegistered, .requiresApproval, .notFound
```

The user can disable the item in System Settings, Login Items. If the status is `.requiresApproval`, the user must approve it. **[partial, general knowledge; Apple doc page did not render]** Register from a signed bundle at a stable path, because the login item is keyed to the app.

### C3. FoundationModels from a SwiftPM CLI build

`FoundationModels.framework` is present in the CLT SDK (`MacOSX26.5.sdk`), so `import FoundationModels` should compile with `swift build`. **[verified present locally; compile not yet tested]** The model is `SystemLanguageModel.default`. Check `availability` before use. It returns `.available` or `.unavailable(reason)`, and availability depends on Apple Intelligence being enabled on the device and region. **[partial, Apple SystemLanguageModel reference via search]**

Sketch:

```swift
import FoundationModels

let model = SystemLanguageModel.default
guard case .available = model.availability else { return }
let session = LanguageModelSession(instructions: "Answer only YES or NO.")
let reply = try await session.respond(to: "Task: write the thesis. Window title: Reddit - r/funny. Relevant?")
```

Unverified: whether a plain executable (no `.app` bundle, no entitlement) can use the model. Test it. Cost: on-device, so no network cost. Latency per call is not measured in the sources consulted. A tiny yes or no prompt keeps it short, but measure. Keep calls rare (only when the title changes and the cache misses).

## Recommended stack

- **A1:** `NSWorkspace.didActivateApplicationNotification`. No permission. Event-driven.
- **A2:** Accessibility (AX) with `AXObserver` on `kAXFocusedWindowChangedNotification` and `kAXTitleChangedNotification`. Avoid Screen Recording.
- **A3:** AppleScript per browser (Safari, Chrome, Brave, Arc), run only on events. Firefox: window title only.
- **A4:** `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)`, polled sparingly while active. Test that it needs no permission.
- **A5:** `com.apple.screenIsLocked`/`Unlocked` distributed notifications, plus `NSWorkspace` sleep and wake notifications.
- **B1:** `AVCaptureSession` with `AVCaptureVideoDataOutput`, discard about 20 to 30 frames, keep one, stop the session.
- **B2:** Apple's `YOLOv3TinyFP16.mlmodel` (17.7 MB) through Vision, with the face-pitch check as a second signal. Verify the "cell phone" label at runtime. Avoid YOLO11n (AGPL and Python export).
- **B3:** `MLModel.compileModel(at:)` at first launch, then cache the `.mlmodelc`. `coremlcompiler` is not in CLT.
- **C1:** SwiftPM executable plus hand-built `.app`, `LSUIElement`, usage strings, self-signed code-signing certificate reused across builds, fixed path.
- **C2:** `SMAppService.mainApp.register()`.
- **C3:** `FoundationModels` is in the CLT SDK. Use `SystemLanguageModel.default` with an availability check. Test whether a CLI-style binary works.

## Blockers and open items

1. No verified "phone" label in Apple's Vision taxonomy. Test with `knownClassifications(forRevision:)` on device.
2. No measured accuracy for YOLOv3-Tiny on a phone at desk distance. Measure before relying on it.
3. Whether `secondsSinceLastEventType` and AX reads need any extra permission on macOS 26. Test on a clean TCC database.
4. Whether a plain SwiftPM executable can call FoundationModels. Test.
5. Whether `kCGWindowName` is populated for other apps without Screen Recording on macOS 26. Apple DTS says it is withheld. Confirm if CG path is ever needed.

# Existing solutions survey

Survey date is 2026-10-12. Prices and feature claims come from vendor or aggregator pages fetched or searched during the survey, and conflicting figures are flagged. Items marked "unverified" were seen only in search snippets or secondary sources. Nothing here was installed or run.

## Bottom line

Nothing found does exactly what the idea describes, which is a private, local, background daemon that combines frontmost app, window, and browser URL signals with an occasional webcam frame classified on-device for "phone in hand", followed by a soft interrupt that asks for a typed justification. Blockers (Freedom, Cold Turkey, SelfControl, Opal, one sec) enforce rules but do not use a camera. Trackers (ActivityWatch, Timing, RescueTime, Rize) record context but do not intervene. The camera tools (FocusCam, FocusVision, WithFocus, Gaze Guard, EyeLock, Focus Buddy) detect attention or phones but are either Python or browser prototypes, or Mac apps that blur content rather than ask a question. The closest combination is ActivityWatch-style tracking plus a YOLO phone detector plus a Swift notification and prompt layer, which is the gap this project would fill.

## macOS focus, blocking, and time-tracking apps

### Freedom (freedom.to)

- What it does: cross-device website and app blocker with scheduled and manual sessions.
- Detection: blocklists for websites and apps, enforced by the app. Website blocking works on Mac; the vendor page lists app blocking on Mac as well.
- Price: per the fetched pricing page, Premium Monthly $8.99/mo, Premium Yearly $3.33/mo billed yearly with a 7-day trial, Premium Forever $99.50 one-time (shown as 50% off $199). Treat the lifetime figure as unverified until checked on a second page.
- Missing vs the idea: no camera, no context awareness, no interruption prompt; it is a hard block, not a question.
- Source: https://freedom.to/pricing

### Cold Turkey Blocker (getcoldturkey.com)

- What it does: Windows and Mac blocker for websites, apps, and the whole internet, with timed and scheduled blocks.
- Detection: rule-based lists. Free includes website blocking and timed blocks. Pro adds app blocking, scheduled blocks, an application password, locking, and breaks and allowances.
- Price: Pro is a one-time purchase ("pay once, own forever"); the dollar amount did not appear in the fetched page. Pro key works on Mac and Windows.
- Missing vs the idea: no camera, no context signals beyond the list, no typed justification flow.
- Source: https://getcoldturkey.com/pricing/

### SelfControl (selfcontrolapp.com, GitHub)

- What it does: free, open-source Mac blocker that blocks websites, mail servers, or the entire internet for a fixed timer.
- Detection: none beyond a static blocklist. Once started, it cannot be undone by the app or a restart, and only the timer ending releases it.
- Price: free. License GPL-3.0.
- Missing vs the idea: a useful model for the "commit and cannot cheat" mode, but no monitoring, no signals, no prompts.
- Source: https://github.com/SelfControlApp/selfcontrol

### Opal (opal.so, iOS-first)

- What it does: iPhone-first app blocker with scheduled focus sessions and a "Deep Focus" lock.
- Detection: Apple Screen Time API on iPhone. Some reviews also claim a VPN profile is used; this was not confirmed from an independent source.
- Price: reported inconsistently. Commonly cited: Pro about $99.99/yr or $19.99/mo, Lifetime $399. One source lists lower prices ($59.99/yr, $9.99/mo). Free tier is limited.
- Missing vs the idea: iOS-centric, no webcam, no Mac context signals in the way described here.
- Sources: https://makeheadway.com/blog/opal-app-review/ (secondary), https://www.autonomous.ai/de-US/ourblog/opal-app-review (secondary)

### Session (Mac)

- What it does: Mac focus-session timer with website and app blocking and session logs.
- Detection: rule-based blocking during sessions.
- Price: conflicting. Toolradar (checked June 2026) lists Free plus Pro at $4.99/mo. Setapp lists From $14.99/mo (English) and From $9.99/mo (Portuguese); Setapp is a bundle, which may explain the gap, but this is unverified.
- Missing vs the idea: no camera, no interruption dialog.
- Sources: https://toolradar.com/tools/session , https://setapp.com/apps/Session

### one sec (one-sec.app)

- What it does: friction-based app and site blocker on iPhone, Mac, and browsers. Interrupts with breathing, mirror, typing, or a rotate-phone challenge before letting you open a distraction.
- Detection: opening of selected apps or sites, via a browser extension for web (Windows, macOS, Linux) and a block mode for sessions. The page does not explain how app opens are detected on iPhone or Mac.
- Price: Essentials free; premium amount not on the page. "Pay once, use on all your devices." Team plans from $0.83 per user per month billed annually.
- Missing vs the idea: this is the closest design analogue for the soft-interrupt UX (friction before continuing), but it triggers on a site or app open, not on a behavioral or visual signal, and it does not ask for a typed reason.
- Source: https://www.one-sec.app/

### Timing (timingapp.com)

- What it does: automatic Mac time tracker, with apps, documents, websites, and calendar integration.
- Detection: records frontmost app, document path, and full website URL (per the product page). Private/incognito tabs are discarded. Stores data locally, with optional cloud sync.
- Price: $10/mo (Professional) or $168/yr (Connect); 30-day trial; no one-time option listed.
- Missing vs the idea: strong on tracking and privacy, but it is passive. No intervention, no camera, no task timer prompting.
- Source: https://timingapp.com/

### RescueTime

- What it does: passive time tracker with productivity scoring, app and website categories.
- Detection: on Mac it needs Accessibility permission for app and window info, and Automation permission per browser to read URLs. Firefox needs a separate extension (RescueTime help docs).
- Price: conflicting across secondary sources. Common figures: $7/mo (billed yearly) to $9/mo monthly, with a Lite free plan. Other sources cite higher ranges. Verify on the vendor page before relying on this.
- Missing vs the idea: passive reporting and scoring only. No intervention or camera.
- Source: https://newrescuetime.helpscoutdocs.com/article/257-enabling-website-tracking-on-macos

### Rize

- What it does: automatic time tracker with focus blocks and per-project tagging.
- Detection: app and browser activity on Mac and Windows (details of URL capture not confirmed).
- Price: about $9.99/mo annual per a Dayflow roundup (secondary, unverified).
- Missing vs the idea: passive tracking; no camera or intervention confirmed.
- Source: not fetched directly; the Dayflow comparison roundup is a competitor page, so treat with caution.

### LookAway (lookaway.app)

- What it does: Mac break reminder with 20-20-20 style breaks.
- Detection: heuristics rather than a camera. It pauses breaks during meetings, during video playback in the active app, during fullscreen games, and while typing. A "Deep Focus Apps" list lets the user pick apps where breaks pause. Developer comments suggest reliable deep-focus detection (low app switching, idle patterns) is still being worked on.
- Price: not checked in the survey.
- Missing vs the idea: the activity-heuristics layer is a useful reference for when not to interrupt. No camera, no question dialog.
- Sources: https://lookaway.app/docs/introduction , https://news.ycombinator.com/item?id=48659483 (Show HN post; unverified details)

### Raycast focus and macOS Focus / Screen Time

- What it does: Raycast Focus blocks chosen apps and websites during a timed goal session, with Block (only listed) or Allow (everything except listed) modes. Raycast 1.92 added a system Focus Filter so that a macOS Focus can start a Raycast session.
- Detection: rule-based. Focus filters are an Apple mechanism for system Focus modes and do not expose window content to third parties.
- Price: part of Raycast; check the Raycast pricing page (not fetched).
- Missing vs the idea: no context-aware check, no camera. Apple's Focus filters are a good integration point if the app wants to start or end its own sessions when a system Focus changes.
- Sources: https://manual.raycast.com/focus , https://www.raycast.com/changelog/macos-v1/1-92-0

### Screen Time / macOS Focus

- What it does: built-in Mac and iOS app limits and Focus modes; app limits and downtime are enforced by the system.
- Detection: system-level usage data; Focus modes are triggered by schedule, location, or app.
- Missing vs the idea: no camera, no typed prompt, no custom signal. The developer surface for third parties is limited (Focus filters, FamilyControls on iOS); FamilyControls was not researched on Mac.

### Not covered in depth in the survey

- HeyFocus, Focusplan, Structured, Centered, Serene: searches returned no reliable detection or pricing details, except that Centered is described as "AI coaching and focus music" with "distraction nudges" (unverified). These need a follow-up pass with the vendor sites.

## Camera-based detection projects and apps

### FocusCam (Python, GitHub)

- Repo: https://github.com/Executioner501/FocusCam
- What it does: webcam tool that reports "PAYING ATTENTION" or "DISTRACTED".
- Models: YOLOv8 nano (`yolov8n.pt`, Ultralytics) for phone detection; a MobileNetV2-based Keras CNN for yawns (trained on YawDD); a Keras CNN on eye crops plus a MediaPipe Face Mesh iris-position rule for gaze.
- License: not stated on the page. Treat as unlicensed until the LICENSE file is checked.
- Status: 12 commits and 1 star as shown; no dates visible.
- Reusable for macOS/Swift: the approach (YOLO phone class plus MediaPipe gaze) is reusable. The Python code is not directly reusable in a Swift daemon, but the pipeline can be ported to Core ML.

### Focus Tracker (GitHub, YOLOv5)

- Found via search snippet only. It uses Ultralytics YOLOv5 to detect a phone in a webcam frame, with training data the authors collected themselves. Repo link not checked; treat as unverified.

### Hugging Face demo: YOLOv8n "cell phone" class

- Link: https://huggingface.co/spaces/Omarrran/yolo_phone_deduction/blob/main/app.py
- A Gradio app using YOLOv8n, class "cell phone", confidence threshold 0.4, with OpenCV. Useful as a baseline for a threshold and class choice; not a product.

### FocusVision (browser, TensorFlow.js)

- Link: https://peerlist.io/adhitya5119/project/focusvision--ai-distraction-detection-for-deep-work
- Runs COCO-SSD in the browser on a camera feed; fires audio and push alerts when a phone is seen. Client-side design is a useful reference for doing inference locally with no frames leaving the device. License and repo not verified.

### University of Detroit Mercy poster: smartphone detection

- Link: https://libraries.udmercy.edu/archives/achievement/index.php?sid=22868
- Describes Ultralytics YOLO detecting persons and mobile devices in frames, with BYTETracker to estimate per-person phone usage over time. Poster only; treat as preliminary.

### WithFocus (Mac)

- Link: https://www.hunted.space/product/withfoc-us
- Described as a Mac app that uses facial metrics and head position to detect looking away or down, aimed at phone distraction. Product Hunt-scale launch with thin details; the claim of phone detection is not verified.

### Gaze Guard (Mac)

- Link: https://www.producthunt.com/products/gaze-guard
- Blurs chosen windows when the user looks away. Uses Apple's Vision framework, processing on device. Does not detect phones. Relevant as a native-Mac reference for camera capture and on-device face processing.

### Habito (iPhone)

- Link: https://apps.apple.com/us/app/-/id6758572739
- Uses the camera during focus sessions to check presence and attention. iPhone only; not a Mac reference.

### Chrome extensions: Focus Buddy and EyeLock

- Focus Buddy: https://chromewebstore.google.com/detail/enefnbeijiedpklbfihgdlhknicikmam (alerts after about 3 seconds of looking away).
- [EyeLock](https://chromeboard.com/extension/eyelock-–-privacy-screen-kjecgmaajngdeofligdhakhacolbfpal) (mutes tabs when looking away; uses MediaPipe Face Landmarker on device, per listing).
- Both are browser-only and do not see outside the browser.

### Ultralytics YOLO licensing (not searched; general knowledge)

- Ultralytics YOLO models ship under AGPL-3.0 with a commercial license option. This matters for a product: a private local app is fine, but distributing it would need a license decision. Verify before shipping. Alternatives that avoid this include training a small MobileNet or EfficientDet-Lite classifier, or using Apple Vision and Core ML models directly.

## Open-source macOS trackers (Swift and others)

### ActivityWatch aw-watcher-window

- Repo: https://github.com/ActivityWatch/aw-watcher-window
- License: MPL-2.0 (per the GitHub page).
- What it does: cross-platform window watcher for Linux (X11), macOS, and Windows. Logs the active application and, if permitted, the window title; the README says the terminal needs macOS Accessibility permission to read titles.
- Browser URLs: handled by a separate watcher, aw-watcher-web (browser extension), per the official docs at https://docs.activitywatch.net/en/latest/watchers.html . The docs say aw-watcher-window itself can read URLs on Chromium and Safari in some setups; this was not confirmed in code.
- Language: Python per the fetched page's install instructions (inferred; the Languages section was empty).
- Reuse: the architecture (watcher pushes events to a local server with buckets) is the thing to copy. Code is Python, not reusable in Swift, but the event schema is a good model.

### WatchEye (Swift)

- Repo: https://github.com/m1guelpf/WatchEye
- License: MIT. Swift Package Manager.
- Observes: active app changes, focused window title changes, and current browser URL (via optional browser helpers, including incognito detection).
- Method: Accessibility API. Needs App Sandbox disabled. Browser URL reads need the Apple Events entitlement and `NSAppleEventsUsageDescription`.
- Reuse: the most directly reusable Swift code found. Good for the frontmost app and browser URL capture layer of this project.

### Potem (Swift, SwiftUI)

- Repo: https://github.com/fausto95/potem (found in search; the Potem-app/potem URL returned 404)
- Native macOS time tracker with automatic tracking and a timeline view, per a search snippet. License and whether it captures URLs were not confirmed.

### mado (Rust crate with Swift bridge)

- Link: https://docs.rs/crate/mado/latest
- Wraps macOS APIs, listens for focus changes, and can enrich browser windows with URL metadata; browser URL needs Accessibility permission. License not checked. Useful only if Rust is acceptable.

### Timetracker (macOS, manual)

- Repo: https://github.com/mribeiro/Timetracker
- MIT per search snippet. Manual start and stop, not automatic window or URL capture. Limited value beyond UI reference.

### active-win-url (npm)

- Link: https://www.npmjs.com/package/active-win-url
- Node package returning the active window and URL on macOS. Implementation detail (Swift helper vs JXA) not verified.

## Gaps and open items

- Structured, Serene, HeyFocus, Focusplan, and Centered need a direct pass; detection and pricing were not confirmed.
- Pricing for Cold Turkey Pro, one sec premium, Raycast, and Rize needs the vendor pages checked.
- The FocusCam and Focus Tracker repos' licenses are unknown; do not copy code until confirmed.
- No peer-reviewed study on webcam phone detection for focus was found; the UDM poster is the closest.
- Accuracy of YOLO phone detection at laptop-webcam distance, low light, and with a phone held below the frame was not measured in any source found. This needs a local test set.

## Ideas worth stealing

- Interrupt-first UX from one sec and LookAway: the interruption should be a short, skippable question with a typed reason, plus a "do not interrupt" list (video, meetings, typing) learned from LookAway.
- Event schema and buckets from ActivityWatch: store frontmost app, window title, and URL as timestamped events in a local store so the daemon can be audited and replayed.
- Commit-mode from SelfControl: a session that cannot be cancelled until the timer ends, as an opt-in, for deep-work blocks.

## Reusable code pointers

- WatchEye (MIT, Swift): frontmost app and browser URL capture for the daemon, https://github.com/m1guelpf/WatchEye
- ActivityWatch aw-watcher-window (MPL-2.0, Python): event model and watcher architecture to copy, not code, https://github.com/ActivityWatch/aw-watcher-window

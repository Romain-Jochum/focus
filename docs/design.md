# Focus — design spec

Date: 2026-10-12 · Status: implemented (v1.0.0)

## Intent

A macOS menu-bar app that keeps you on the declared task. It catches drift (phone, distracting sites and apps, walking away, looking away) within seconds, pulls you back with a typed check-in, and makes focus time measurable. Nothing leaves the Mac, and camera frames are never written to disk, except for the false alarms kept in developer mode (off by default).

Success: during a session every drift is caught (≤20 s for distracting sites, ≤30 s for absence, ≤45 s for phone) and nags until resolved; every escape is either blocked or visible in stats; the app averages ≤3% CPU and <200 MB memory (Activity Monitor) during a session; the core test suite runs in under a second after an incremental build.

Research backing every number below lives in `research/` (see `research/README.md`).

## Behaviour

### Session

- Start sheet: task (one sentence, required), mode **On computer**, **Offline** or both (both chips can be selected together for sessions that mix computer and paper work), duration 25 / 50 / 90 / custom minutes, optional "If I drift, I will…" line (implementation intention, shown on every check-in).
- Dock icon and a Focus window (same content as the menu-bar popover), so it is always visible while open; closing the window keeps it running.
- Menu bar item: state dot (green focused, amber drifting, red away/alarm, grey idle) plus remaining minutes. Popover shows task, big tabular countdown, state line, Break and End buttons.
- Wrap-up notification 5 min before the end. At the end: the session's verdict and XP (see Progression) as a notification with its sound, then a one-line reflection prompt ("How did it go?"), stored with the session.
- Ending early: type the exact phrase `I am ending this session early`, then a 10 s countdown, kept by the engine so closing the popover does not cancel it (Keep going does); logged as `abandoned`.

### Detection rules (evaluated every second)

| Rule | Condition | Response |
|---|---|---|
| Distraction | Frontmost app or browser domain (the domain or any subdomain) in the distraction list for 20 s | Check-in |
| YouTube | Domain youtube.com during work hours | Inject hide-CSS (home feed, related sidebar, Shorts, end screen, thumbnails grid). Home page, `/shorts` and other pages count as Distraction; `/watch`, `/results`, `/playlist`, `/embed` and youtu.be links are allowed |
| Away | No face and no keyboard or mouse input for 30 s (120 s while the microphone is in use), or a covered (dark or uniform frame) or unauthorized camera for 30 s (the camera rests during unbroken input, so a lens covered then is seen once input stops, and Away comes 30 s after the last input) | Alarm card + chime (again at 20 s), then the looping alarm, which stops when you are back; time counted as `away`; the card waits for an answer (see Check-in) |
| Phone | No keyboard/mouse input for 10 s and either a phone detected by the camera (confidence ≥ 0.5) in two consecutive runs of the phone model, or the iPhone on the desk reporting it is unlocked and in use for 15 s (its Bluetooth "Nearby Info" advert, see below); or (On computer mode only) face present, head pitched down more than 20° (default, calibrated with `--probe`) and no input for 45 s (a microphone in use counts as input) | Check-in, reason "Phone?"; time counted as `phone` |
| Idle at computer | Mode On computer only, face present, no input for 3 min (a microphone in use counts as input) | Soft check-in |
| On computer while Offline | Mode Offline only, keyboard/mouse active more than 60 s within the last 120 s | Check-in "Your task is offline — what's this?" |
| No session | Work hours (default Mon–Fri 09:00–19:00), input active 3 min, no session | "Start a session or say why not" card; repeats every 15 min; answer logged |

- Input counts as presence: keyboard or mouse input in the last 2 s keeps Away from firing while the camera sees no face or rests (see Camera cadence and budget). A covered or unauthorized camera is not excused by input.
- A microphone in use (see Microphone in use) counts as input for the head-down branch of Phone and for Idle at computer, since talking, dictating a prompt or recording is work the camera often misses. It also makes Away wait 120 s instead of 30 s while the camera sees no face. It does not excuse a phone seen by the camera or an iPhone in use.
- After "I wasn't drifting", the rule that fired stays quiet for 10 minutes (see Check-in).
- First 3 minutes of a session: soft check-ins (Idle at computer, Offline) are suppressed; Away and Phone still fire.
- Default distraction list (editable in settings): youtube.com, youtu.be, tiktok.com, twitch.tv, netflix.com, 9gag.com, instagram.com, facebook.com, x.com, twitter.com, reddit.com, news.ycombinator.com; apps: none by default (bundle IDs can be added).
- Cooldown: after "I wasn't drifting" on a distraction, the same domain or app is allowed for 10 min, then asked again. A check-in never repeats within 60 s of the previous one except Away (20 s).

### Check-in

- A borderless panel at screen-saver level on every Space covers all screens with a dim + blur backdrop; the centred card shows the task, the "If I drift" line, the reason, and a text field.
- Evidence ("caught in the act"): the card shows the camera frame that triggered it, mirrored, with a box around the face ("You") and around the phone ("Phone 82%"); Away shows the empty chair. If the camera was resting when the card came up, its frame appears about 2 s later. Distraction, Idle and Offline check-ins add a thumbnail of the screen taken just before the overlay (ScreenCaptureKit, Focus's own windows excluded). Images stay in memory only and are dropped when the card closes, except a false alarm's in developer mode (below).
- Answer needs at least 3 words of two or more letters, not all the same word. Regular cards (distraction, phone, idle, offline) have three choices:
  - **I wasn't drifting** (a false alarm): the flagged time is booked as focused (the unbroken stretch of drifting, phone or away time that led to the card, for a distraction on that same domain or app; a stretch never reaches back past the previous card, a lock or sleep); the card does not count against the session verdict; the rule that fired stays quiet for 10 min, and for a distraction the same domain or app is allowed for 10 min.
  - **Take my break** (shown when a break is earned): starts the break, the time already booked stays as it is.
  - **I drifted — back to it**: the time stays booked as drifting, phone or away, the card counts against the verdict, and the same target is asked again once the 60 s check-in gap has passed. It does not justify the target.
- The Away card has the answer field and two buttons: **I was here** (a false alarm: the flagged away time is booked as focused, the card does not count against the verdict, and Away stays quiet for 10 min) and **I was away** (the away time stays away, and the card counts against the verdict). Answering any card counts as being present, so an Away card answered while the camera still sees no face does not raise Away again at once.
- The Away card stays up after you are back and waits for an answer. Its alarm stops when you are back and sounds again after 30 s if it is still unanswered. Leaving again while it waits resumes the 20 s chimes. If the Mac sleeps or the screen locks, the card is dismissed at once, so no alarm sounds behind a locked screen.
- Sound: a chime when the card appears. Unanswered for 30 s, it becomes a looping alarm (synthesized alarm-clock beeps: four 2.4 kHz beeps, then a pause, every second) until the card is answered (a distraction card also closes when its site or app is no longer in front); repeat chimes stay silent while it sounds. While the alarm sounds, the output volume is at least 50% and unmuted: a lower volume is raised to 50%, and the previous volume and mute state come back when the alarm stops (devices without a software volume are left alone). The permissions card never alarms, since it steps aside while System Settings is open.
- Unanswered for 30 s while a distraction is frontmost: the browser tab is closed (Safari/Chrome via AppleScript) or the app is hidden.
- Copy is neutral and curious ("Still on *task*?"), never guilt. Wording rotates among a few variants to stay noticeable.

### Breaks

- One 5-minute break earned per 50 minutes of focused time; at most one banked. During a break or quick pause, the session timer pauses while the break timer counts down, no rules fire except the break timer and the permissions check, and the camera rests (on a regular break).
- **I'm back** ends a break early; the rest of it is forfeited.
- **Quick pause** (a bathroom trip): any time during a session with no check-in up, once per session (twice when the session is 90 minutes or longer), without using the earned break. It pauses the session timer for up to 5 minutes, counts as `break` time on the timeline, and does not cost a perfect session. It ends with **I'm back**, or by itself when the camera sees a face again after 20 s or more without one during the pause (a blink of no face while still at the desk does not count).
- When a break or pause ends by itself, a soft two-tone sound plays and the session timer resumes. If no face is seen within 30 s, the Away alarm starts; overrun time counts as `away`.

### Stats

- Every second of a session is attributed to exactly one category: `focused`, `drifting`, `away`, `phone`, `break`, `untracked` (time Focus could not see: it was not running during an active session, or Accessibility or Automation was revoked).
- Stats window: today and last 7 days totals per category (stacked bar), per-session timeline strip, top distractions (target, minutes), log of every check-in answer and no-session answer (an "I wasn't drifting" is labelled "False alarm").

### Developer mode

Off by default (Settings › Developer; the switch applies at once, without Save). When on, each check-in answered as a false alarm ("I wasn't drifting", "I was here") is kept on disk to tune detection with later, in `false-alarms/<date>-<time>-<reason>/` (Settings › Developer › Show saved opens the folder):

- `alarm.json` (`FalseAlarm`): the reason, the typed answer, the task and mode, the card's face and phone boxes (normalized, top-left origin, as the camera sees them, not mirrored) and the phone model's score, whether the iPhone reported use, the settings, and the session's ticks (one per second: frontmost app, window title, URL, idle time, camera reading, iPhone and microphone) from 3 minutes before the card to the answer. With the settings, the ticks replay through `Engine`.
- `camera.jpg`: the card's frame as the camera delivered it (full size, not mirrored), for every card but the no-session and permissions ones, when the card had a frame by the time it was answered. `screen.jpg`: the card's screen thumbnail (distraction, idle and offline cards).
- Written as JPEG (quality 0.8) and compact JSON on a background queue, about 100–300 KB per false alarm. Nothing is deleted automatically.
- Cost: the tick log (`TickLog`, about 200 ticks) is kept only while developer mode is on and a session runs, and the full frame is held only while a card is up. With developer mode off, nothing changes.

## Progression

Consistency is rewarded with XP, 100 levels and a garden that grows from barren land into an ecosystem (inspired by Terra Nil). The game is tuned to last a year of steady work. Research and simulations: `research/12-progression.md`.

### Session verdict

Decided when a session ends, from its record. A check-in is any card raised for distraction, phone, idle, offline or away (counted in the record as `checkIns`), except one answered "I wasn't drifting" (a false alarm, counted as `falseAlarms`), which does not count against the verdict. The focused share is focused time over session time minus breaks and pauses; the time re-booked from false alarms is focused time.

| Verdict | Condition | XP |
|---|---|---|
| Perfect | Completed, planned ≥ 25 min, no check-in, focused share ≥ 95% | + focused minutes × (1 + bonuses) × daily multiplier |
| Good | Completed, ≤ 2 check-ins, focused share ≥ 80% | 0; keeps the streak |
| Drifted | Completed, anything worse | − 10% of the current level's span |
| Abandoned | Ended early with the phrase, after its first 2 minutes (earlier is a false start and does not count) | − 25% of the current level's span |

- Bonuses (perfect only, added together): **early** start 05:00–08:29 +25%; **late** start 19:00–21:59 +25% (none from 22:00, so sleep is never rewarded); **streak** +5% per consecutive kept day after the first, up to +50%.
- **Daily multiplier**: once a day has 3 perfect sessions totalling ≥ 4 h 30 focused, each further perfect session planned ≥ 90 min gets ×1.3, then ×1.6, ×1.9 … (additive +30%).
- **Streak**: a day is kept with at least one perfect or good session. A missed work day (Settings work days) breaks it unless a freeze is held; one freeze is earned every 5 kept days, at most 2 held, spent automatically. Other days never break it.
- **Losses** never drop a level: XP stops at the current level's floor. Within a level they take back garden growth, which withers.
- **Levels**: reaching level L takes `150 · (L − 1)^1.4` XP in total (L2 150, L10 3,251, L50 34,863, L100 93,321). Simulated (200 runs per profile): 5–6 days a week with 3–5 sessions reaches L10 in 3 weeks, L50 in 21 and L100 in about 55 weeks; 5 days with 2–4 sessions reaches L100 in about two years.
- XP is never stored: it is recomputed from the session records since `Settings.gardenStart` (set when the garden first appears), so a rule change re-scores history consistently.

### Garden

Research, rendering spikes and measurements: `research/13-garden.md`.

- **World**: an 11 × 11 floating island. The spring sits left of the middle with a stream wandering to the island's front edge, where it spills over the side, and each tile is meadow, forest, rock or stream (assigned once from a fixed seed, forests in clusters). Every tile climbs its own stages: dust → soil → young grass → grass → then flowers and bushes (meadow), sapling → young tree → mature tree → undergrowth (forest), moss and flowers (rock), or water and reeds (stream).
- **Growth steps**: the whole restoration is one fixed sequence of 977 single-tile steps, ordered so that the water comes first: from the spring down to the edge, each stream tile is dug and then filled, so the stream reaches the edge at step 22 (during level 4), and only then does the land start to green. The rest is a wave from the spring (a step's rank grows with its stage and its distance from the spring, plus a little seeded noise; soil only spreads next to green; grass needs green or water next to it; banks, lilies and reeds follow the same wave). A stream tile's channel opens only toward stream tiles already dug, so a stream on its way ends in a rounded end and the first tile is a small pool; the sheet of water down the side appears once the last tile has water. The garden's growth is half the progress through the levels and half the XP toward level 100, so the early levels show quickly and growth stays visible about every one or two perfect sessions all year; the island never reshuffles. At level 10 about 60 steps are done (an oasis around the spring), at level 50 about 420, at level 100 all of them. Level phases: Barren (1–4), Revival (5–14), Meadow (15–29), Grove (30–49), Forest (50–74), Ecosystem (75–99), Restored (100).
- **Look**: Kenney Nature Kit low-poly models (CC0, `Resources/Garden`, 49 of its 329 models, about 400 KB) recoloured in code to a natural palette, three shades per ground colour so the land reads as patches, isometric (2:1) orthographic camera, soft sun shadows. Same image in light and dark, on a quaternary box.
- **Rendering**: SceneKit renders the island offscreen (1040 × 800 px, 2× a 520 × 400 pt panel) only when its step changes, in a short-lived child process: the app runs its own binary with `--render-garden <steps> <dir>`, which renders (30–130 ms, about 270 ms the first time), writes the image to Application Support (`garden.png`, with `garden.json` holding the renderer version, the step and each tile's centre in the image) and exits (0.15–1.5 s from launch to exit, peaking at about 160 MB, all of it gone with the process). The app reads the cache back with ImageIO, so SceneKit's memory never stays in it (rendering in-process peaked at 175 MB and left about 26 MB behind), and launches and sessions never touch SceneKit. SceneKit is deprecated since WWDC 2025 but works on macOS 26; it is confined to one file.
- **Window**: the Focus window shows the controls on the left and the garden on the right, with the level and phase, total XP, XP to the next level, the streak and freezes, and today's multiplier (or what unlocks it). The menu-bar popover shows a one-line summary.
- **Reward moment**, played when the window is visible (or the next time it is): a card over the island shows the verdict, the XP counting up and the bonuses for 6 s; the new image spreads from the tiles that grew (expanding circles, 1.2 s) with a small sparkle on each. A level-up adds a burst of leaves and the new level's name on the card. Withering fades in over 3 s with no sound. A session that earns XP without a new step shows the card alone.
- **Life**: for 20 s after the window comes into view outside a session, butterflies (from flowering tiles) and birds (from mature trees) move over the island, then everything stops. Nothing animates while the window is covered or minimised, or during a session.
- **Sounds**, synthesized: a rising bell arpeggio for a perfect session, a soft two-note rise for a good one, a longer chime for a level-up, a two-tone for a break or pause ending by itself; nothing for a loss.
- **Budget**: the garden adds no CPU during a session (a still image, about 3 MB decoded). Measured on the release bundle (`research/13-garden.md`): the reveals and life add no measurable WindowServer CPU over the still window and at most about 1.5 points of GPU; the app spends 0.03–0.06% CPU on them and 1–2% while the reward card counts up; the footprint goes from about 26 MB to 33–45 MB with the window up. A key window with the cursor in a text field costs WindowServer about 12 points by itself (macOS's animated text cursor), which stops as soon as another app is in front.

## Escape routes and counters

| Escape | Counter |
|---|---|
| Never start a session | No-session nag during work hours while Focus is open |
| Quit / `kill -9` | Focus runs only while open (by design: no hidden background process). During a session ⌘Q and Quit from the Dock or Activity Monitor are refused (logout, restart and shutdown are allowed); the session must be ended with the phrase. Force Quit / `kill -9` leaves the session open: it resumes when Focus is reopened and the gap is logged as `untracked` |
| Hide the check-in with ⌘H | The app unhides itself while a check-in is up |
| Walk away, cover camera, revoke Camera | All map to Away with persistent alarm (Away waits 120 s, not 30 s, while the microphone is in use and the camera sees no face; a covered or revoked camera stays at 30 s, counted from the last input when the lens is covered during unbroken typing) |
| Close lid / sleep / lock screen during a session | Sleep and lock notifications; the whole interval counts as `away` |
| Phone held below or beside the camera's view | The iPhone's own Bluetooth advert says it is in use, wherever it is held; head-down + no-input rule; Idle-at-computer rule |
| Photo of a face | No-input rules still fire |
| YouTube "research" spiral | Recommendations hidden; home/Shorts need a typed reason; re-asked every 10 min |
| Junk answers | ≥3 words of 2+ letters, not one word repeated; every answer visible in stats |
| Break abuse | Earned, not bankable beyond one, overrun = away |
| Changing the clock | All timing within a run uses `CLOCK_MONOTONIC`, which also counts through sleep. The gap after a relaunch can only be measured on the wall clock; a gap that comes out negative (clock set back while Focus was killed) is not booked. Accepted: it needs both `kill -9` and a clock change |
| Revoking Accessibility/Automation | Detected each minute during a session; persistent banner in popover and check-in "Permission removed"; counted as `untracked` |
| Muting volume | The overlay is visual and blocks the screen |

## Architecture

Native Swift (SwiftPM, Swift 6 toolchain in Swift 5 language mode, macOS 26), one process, one dependency-free package. Swift is chosen because Core ML/Vision run on the Neural Engine with no runtime overhead and every OS API needed is first-class.

```
Package
├─ FocusCore      (library, Foundation only — deterministic, unit-tested)
│   ├─ Engine     state machine: step(Tick) -> [Action]
│   ├─ Rules      target(app:appName:url:title:settings:) -> String?
│   ├─ Model      Settings, Session, SessionRecord (timeline segments, totals), Entry, FalseAlarm (Codable); Tick, TickLog, Action
│   ├─ Store      ~/Library/Application Support/Focus/{settings.json, sessions/<date>-<id>.json, journal.jsonl, false-alarms/};
│   │             Stats (public enum): totals, per-day totals, top distractions
│   ├─ Progression verdicts, XP, streaks, levels (a fold over session records)
│   └─ Garden     the island's tiles and its fixed growth sequence
├─ Focus          (executable app: AppKit + SwiftUI; files directly in Sources/Focus except Garden/ and UI/)
│   ├─ Sensors    Activity (NSWorkspace notifications, AXObserver title changes,
│   │             AppleScript URL on app or title change only, during a session, idle via CGEventSource 1 Hz),
│   │             Camera (CoreMediaIO stream of the built-in camera, Vision faces, phone model),
│   │             PhoneSensor (CoreBluetooth scan for the iPhone's Nearby Info advert),
│   │             ScreenSnapshot (check-in thumbnail),
│   │             Microphone (CoreAudio's per-process recording flag, read once a second during a session; no audio)
│   ├─ AppModel   1 Hz tick; performs actions: overlay panel, chime, Alarm, hide app, close tab, inject CSS
│   ├─ Garden     GardenModel (drawing in a child process, the cache, reveals), GardenRenderer (SceneKit offscreen),
│   │             GardenStage (Core Animation reveal, sparkles, life)
│   ├─ Audio      Alarm, Sounds (synthesized cues), SystemVolume (CoreAudio)
│   ├─ UI         Focus window (controls + garden), MenuBarExtra popover, check-in card, stats, settings
│   └─ Tools      --probe (sensors and budget), --snapshots (every view to PNG), --garden-demo (the garden's cost)
└─ FocusTests     (executable runner; CLT has no XCTest/Swift Testing)
```

Data flow: sensors update a shared `Tick` snapshot (app, title, URL, input idle, camera reading, sleep, permissions, the iPhone signal and `micInUse`); a 1 Hz timer calls `Engine.step(tick)`; the engine returns actions (`show(reason)`, `dismiss`, `chime`, `alarm(on)`, `sound(cue)`, `closeTab`, `hideApp`, `injectCSS`, `notify`, `save`, `ended`); the app performs them; the engine books the second on the session record's timeline; the session record (timeline segments, totals, typed answers) is saved every 30 s; answers outside a session go to journal.jsonl.

### Detection model

Presence and head pose: Apple Vision `VNDetectFaceRectanglesRequest` (revision 3, ships with macOS 26). Phone: **RF-DETR nano** (Roboflow, Apache-2.0, COCO class "cell phone") exported to Core ML at FP16 (`Resources/rfdetr-nano.mlpackage`, 52 MB): 4/4 phones and no false positives on the test images, ~12 ms. FP16 beat the FP32 export (103 MB, ~35 ms, partly on CPU) and an INT8 variant (26 MB, same speed as FP32) on CPU use at the same footprint, and RF-DETR beat YOLO26s (AGPL) on licence. Each frame is scale-filled to the model's input by VideoToolbox and Core Graphics in the frame's own colour space, so the pixels stay gamma-encoded as in the validation: Core Image's default render hands the model linear light, which on the test photos (as 640x480 420v frames tagged like the camera's) raised a laptop from 0.42 to 0.56, over the threshold, while the Core Graphics path stays within 0.04 of the reference on all six. It is loaded with `.cpuAndNeuralEngine` (`.all` pushed the footprint to 330 MB) and released when the session ends. The model is compiled once at first launch with `MLModel.compileModel(at:)` and cached.

### Camera cadence and budget

Budget: ≤3% CPU average and <200 MB footprint during a session. Camera: built-in camera only (never Continuity or Desk View), read through CoreMediaIO (`CMIOStreamCopyBufferQueue`); AVFoundation only finds it (its `uniqueID` is the CMIO device UID) and checks permission, because an `AVCaptureSession` loads the video-effects stack (156 MB in our process). Smallest 420v format at its minimum frame rate (15 fps), set at each start unless another app is streaming: the format belongs to the device and every app shares it, so a call keeps its resolution and Focus takes its frames (setting it under a running 1080p capture dropped that capture to 640x480 at 15 fps). Frames are released on arrival except one every **5 s** (face every sample, phone model every 3rd sample and only when there has been no input for 5 s). Measured on the capture-session build, `--probe` at 1 s = 5.9% / 218 MB and 2 s = 3.4% / 175 MB, so the cadence is 5 s; the rules' latencies (30 s away, two phone samples) are well above it. The stream itself is the cost: while it runs, the system camera daemon (`cameracaptured`) works at 6–10% of a core at the 15 fps floor however few frames we keep, and receiving them costs us about 0.45 ms each. So it runs only while `Engine.wantsCamera` holds: in a running session, not on a regular break and not with the screen locked or asleep; from the start and whenever input has stopped for **5 s**, until input has lasted **30 s** without such a gap; and always while a card is up, during a quick pause or while the lens reads covered. Typing already counts as presence, and the phone and head-down rules wait for input to stop, so no rule is slower; only a lens covered while the camera rests is seen later (see Away). The camera light goes on and off with the stream. Every start begins dark (luma 16 for ~0.6 s, ~85% of its level at 2 s, whatever the gap), so frames from the first **2 s** are skipped; a started stream with no frame for **15 s** reads as covered and is reopened. Measured with `--probe`, which streams all the time (the worst case), alternating with the capture-session build under the same load: Focus 1.2–1.7% CPU and 19–36 MB (peak 35 MB with the phone model running) against 1.3–1.4% and 183 MB, and `cameracaptured` 6.7% against 7.9–9.6%. In a session the camera's share, the daemon's and ours, is saved for every stretch of steady typing past 30 s. Evidence images and the phone model's input are converted with VideoToolbox and Core Graphics, because a CIContext keeps ~40 MB (measured: 64 MB against 24 MB for the same eight detections). The screen side (frontmost app, window title, URL) is event-driven and costs nothing between changes. The camera, the URL reads, the microphone check (about 0.6 ms a second, see Microphone in use) and the iPhone scan run only during a session.

### iPhone in use (Bluetooth)

The camera's field of view is narrow, so a phone held low or to the side is missed. Every iPhone broadcasts Apple manufacturer data whose "Nearby Info" message (type `0x10`) carries an activity code: 3 locked, 11 recent interaction, 15 scrolling or video, 14 call (`research/11-iphone-ble.md`). Focus counts 11, 14 and 15 from a device at -62 dBm or stronger (the iPhone in hand or on the desk reads -35 to -55 dBm) as "in use"; 7 (screen on: notifications, StandBy) and 9 (Macs and Apple TVs, all day) are ignored. Focus remembers your iPhone (setup checklist "Your iPhone", or Settings › iPhone › Find: unlock it next to the Mac; the device reporting use at -50 dBm or stronger within 30 s is stored in settings by its Bluetooth identifier, which macOS keeps stable for one's own devices) and then counts only it; if it has not been heard for 10 min, any nearby iPhone counts again. No pairing and nothing on the phone. A scan costs ~0.4% CPU, so it runs only during a session, not on a break or quick pause or while the screen is locked, only once the Mac has had no input for 5 s, and 2 s on / 2 s off: 2.8% in the idle probe against 2.57% without it, nothing while typing. The check-in card then says the iPhone was unlocked and in use.

### Microphone in use

Talking, dictating a prompt and recording are work that the camera often misses, because the face is turned away. `Microphone.inUse()` (`Sources/Focus/Microphone.swift`) runs once a second during a session and reports whether any app is recording from a microphone. It first asks whether any audio device is running at all (most of the time none is, and the check ends there); if one is, it asks CoreAudio's process list which process is running input (`kAudioProcessPropertyIsRunningInput`). Asking per process matters because a running device can be playing rather than recording: a headset used as the default input runs while music plays, and that is not talking. It reads no audio, never opens the microphone, needs no permission, and returns false on any error. It costs about 0.6 ms a second with nothing playing and about 2 ms while audio plays. Nothing is stored. The flag reaches the engine as `Tick.micInUse` and changes only the rules above: the head-down branch of Phone and Idle at computer treat it as input, and Away waits 120 s instead of 30 s while the camera sees no face.

### Permissions and setup

Camera, Accessibility, Automation (Safari, Google Chrome), Screen Recording (only for the screen thumbnail on check-ins), Bluetooth (only for the iPhone signal; the checklist item is "Your iPhone" and is done once the iPhone is found), and in both browsers "Allow JavaScript from Apple Events" (one-time). The app shows a setup checklist in the popover until all are granted. No microphone permission is needed: Focus only asks macOS whether some app is using the microphone.

## Look

System font, semantic system colours, the system accent colour (`Color.accentColor`), radii 6 (controls) / 10 (boxes), quaternary box fills, no gradients and no shadows except one soft shadow lifting the check-in card off the blurred screen, tabular numerals for timers, spacing 4/8/12/16/20/24. Check-in = a single quiet card over a dimmed, blurred screen. Status colour always paired with an icon and a label.

## Testing

- `FocusTests`: table-driven scenario tests — a scripted timeline of ticks fed to `Engine` with expected actions at given seconds (e.g. "45 s on youtube.com/shorts → checkIn at t=20 → closeTab at t=50"), plus Rules, Store, Stats, Progression (verdicts, bonuses, streaks, levels, a pacing check) and Garden (determinism, one tile per step, the wave) tests. The suite (278 checks) runs in about 0.1 s; `make test` ≈ 2–4 s incremental.
- `Focus --snapshots <dir>`: renders every view in light and dark to PNG for visual review without clicking (the Focus window included), plus the garden at several levels with its render times, the water's first steps (`garden-water-*.png`) and the step and level at which it reaches the edge, and frames of the reveal, withering and life (`stage-*.png`, drawn from the stage's Core Animation presentation tree in an offscreen window; masks are left out there).
- `Focus --garden-demo [seconds]`: the Focus window with a reveal every 10 s (growing and withering in turn) and life running throughout, with no text field focused so the cursor's animation is not counted, then the app's CPU and its footprint before drawing, after and at the end. Nothing is saved.
- `Focus --garden-preview` (`make garden`): the garden alone in the Focus window with a level slider and stepper. Letting go shows the start of that level as after a session: going up plays the reveal with the level-up card, going down the withering. No menu-bar item, settings or sessions are touched, and the pictures go to a temporary folder.
- `Focus --probe`: 20 s live sensor readout (face, pitch, phone confidence, app, URL, idle, CPU, footprint) for tuning thresholds on the real webcam and verifying the budget.
- Manual acceptance on the installed app: walk away, phone in hand, iPhone unlocked out of camera view, YouTube home, cover camera, `kill -9`, break overrun.

## Install

`make install`: phone model exported once by `scripts/make-model.sh` (pinned rfdetr 1.9.4, coremltools 9.0, torch 2.14.1 through uv; not in git), release build → `~/Applications/Focus.app` (Info.plist with `NSCameraUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSAppleEventsUsageDescription`), signed with a self-signed identity "Focus Local Signing" created once in the login keychain (keeps TCC grants across rebuilds), then opened. No LaunchAgent: Focus starts when you open it.

## Out of scope

Signed or notarised binaries (Focus is built from source with `make install`), a second island after level 100, iPhone/iPad monitoring beyond the in-use signal (no app on the phone, no Screen Time), Firefox/Arc URL reading (window title only; titles are matched only for browsers), cloud sync, on-device LLM judging.

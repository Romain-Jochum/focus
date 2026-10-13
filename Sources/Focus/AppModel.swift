import AppKit
import CoreGraphics
import AVFoundation
import FocusCore
import ImageIO
import Observation
import UniformTypeIdentifiers
import UserNotifications

struct SetupItem: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var ok: Bool
    /// Its page in System Settings › Privacy & Security, e.g. "Privacy_Camera".
    var pane: String
    var hint = "Grant in System Settings ›"
}

/// The single source of truth the UI reads. Owns the engine, sensors, actuators and store, and runs the 1 Hz tick.
@MainActor @Observable final class AppModel {
    static let shared = AppModel()
    /// Set from `--start` in main.swift: a session to start on launch when none is running.
    static var launchStart: (task: String, minutes: Int)?
    /// Set from `--garden-demo` in main.swift: replay the garden's reveal and life for this many seconds, then quit.
    static var gardenDemo: Double?
    /// Set from `--garden-preview` in main.swift: the garden alone with a level slider (GardenPanel). Nothing is saved, and its pictures go
    /// to a temporary folder rather than the real garden's cache.
    static var gardenPreview = false

    var settings = Settings()
    var session: Session?
    var category: Bucket?
    var overlay: Reason?
    var remaining: Double = 0
    var breakAvailable = false
    var breakRemaining: Double?
    /// The running break is a quick pause.
    var pausing = false
    var pausesLeft = 0
    /// XP, level and streak, folded from the sessions since the garden started.
    var game = GameState()
    /// The latest scored session, for the reward card.
    var award: Award?
    /// The garden picture and its reveal (observable on its own).
    @ObservationIgnored let garden = GardenModel(dir: gardenPreview ? FileManager.default.temporaryDirectory.appending(path: "focus-garden-preview") : Store().root)
    var setup: [SetupItem] = []
    /// Last 7 days, for the stats window.
    var records: [SessionRecord] = []
    var journal: [Entry] = []
    /// Latest raw readings, shown in the popover's debug line.
    var camera: CameraReading?
    var frontmost: String?
    /// Check-in evidence, in memory only: the camera frame and, for screen reasons, the screen. Dropped on dismiss.
    var evidence: CameraEvidence?
    var screen: CGImage?
    /// The phone check-in came from the iPhone's own Bluetooth signal, not only the camera.
    var iPhoneInUse = false
    /// Looking for the owner's iPhone (`findPhone`).
    var findingPhone = false

    @ObservationIgnored private let store = Store()
    @ObservationIgnored private var engine = Engine()
    @ObservationIgnored private let activity = ActivitySensor()
    @ObservationIgnored private let cam = CameraSensor()
    @ObservationIgnored private let phone = PhoneSensor()
    @ObservationIgnored private var cameraOn = false
    /// Counts overlay changes, so a screen capture that finishes after its card is gone is dropped.
    @ObservationIgnored private var shown = 0
    /// Accessibility and Automation granted; the camera is not part of it (its loss is Away, not untracked).
    @ObservationIgnored private var trackingOK = true
    @ObservationIgnored private var setupAt = -Double.infinity
    @ObservationIgnored private var summaries: [SessionSummary] = []
    /// The day `game` was folded for; a new day can end a streak.
    @ObservationIgnored private var gameDay = Date.distantPast
    /// Developer mode: the session's recent ticks, for a `FalseAlarm`, and when the card now up was raised.
    @ObservationIgnored private var recent = TickLog()
    @ObservationIgnored private var shownAt: Double?

    /// Load settings, resume any running session, start sensors and the tick.
    func launch() {
        settings = store.loadSettings()
        if settings.gardenStart == nil, Self.gardenDemo == nil, !Self.gardenPreview { settings.gardenStart = Date(); store.save(settings) }
        engine = Engine(settings: settings)
        summaries = store.records(since: settings.gardenStart ?? Date()).map(SessionSummary.init)
        refreshGame()
        if let seconds = Self.gardenDemo { return demo(seconds) }
        if Self.gardenPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.activate() }
            set(\.game, GameState())
            return preview(level: 1)
        }
        garden.load()
        garden.show(gardenSteps)
        phone.remember(settings.iPhone)
        reload()
        activity.start()
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } }
        if PhoneSensor.undetermined { phone.ask() }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        refreshSetup()
        if let running = store.active() {
            perform(engine.resume(running, now: monotonic(), date: Date()))
            if engine.record?.outcome == .running { startSensors() }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0.1   // lets macOS batch the wakeup with others; every rule counts in seconds of monotonic time
        RunLoop.main.add(timer, forMode: .common)
        if let launch = Self.launchStart, engine.record == nil {
            start(task: launch.task, plan: "", mode: .computer, minutes: launch.minutes)
        }
        mirror()
    }

    func start(task: String, plan: String, mode: Mode, minutes: Int) {
        perform(engine.start(Session(task: task, plan: plan, mode: mode, minutes: minutes, started: Date()), now: monotonic()))
        startSensors()
        tick()  // Dismisses a no-session card and mirrors the new state.
    }

    /// Returns false when the text is rejected (fewer than 3 words).
    @discardableResult func answer(_ answer: Answer, text: String) -> Bool {
        guard Rules.isValidAnswer(text) else { return false }
        let date = Date()
        if overlay == .noSession {
            store.append(Entry(at: date, reason: "noSession", answer: answer.rawValue, text: text))
            journal = store.journal(since: weekAgo)
        }
        let card = overlay, shot = evidence, snap = screen, iPhone = iPhoneInUse, ticks = recent.ticks, alarms = engine.record?.falseAlarms
        perform(engine.answer(answer, text: text, now: monotonic(), date: date))
        if settings.developerMode == true, let card, let session = engine.record?.session, engine.record?.falseAlarms != alarms {
            keep(FalseAlarm(at: date, reason: String(describing: card), text: text, task: session.task, mode: session.mode,
                        face: shot?.face.map(Self.box), phone: shot?.phone.map(Self.box), phoneScore: shot?.phoneScore,
                        iPhoneInUse: iPhone, ticks: ticks, settings: settings), camera: shot?.frame, screen: snap)
        }
        mirror()
        return true
    }

    /// Developer mode: the folder of saved false alarms, in Finder.
    func revealFalseAlarms() {
        try? FileManager.default.createDirectory(at: store.falseAlarmsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.falseAlarmsURL)
    }

    func takeBreak() { perform(engine.takeBreak(now: monotonic())); mirror() }
    func pause() { perform(engine.pause(now: monotonic())); mirror() }
    /// "I'm back": ends the break or quick pause now.
    func endBreak() { perform(engine.endBreak(now: monotonic())); mirror() }
    func endEarly() { perform(engine.endEarly(date: Date())); mirror() }

    /// Saves the reflection with the record, then closes it (the engine clears its copy).
    func reflect(_ text: String) {
        guard var record = engine.record, record.outcome != .running else { return }
        record.reflection = text
        store.save(record)
        perform(engine.reflect(text))
        reload()
        mirror()
    }

    /// Asks first where macOS can (so Focus is listed in System Settings), then opens the item's page there.
    func fix(_ item: SetupItem) {
        switch item.pane {
        case "Privacy_Camera" where AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined:
            return AVCaptureDevice.requestAccess(for: .video) { _ in }
        case "Privacy_Bluetooth" where PhoneSensor.undetermined:
            return phone.ask()
        case "Privacy_Bluetooth" where PhoneSensor.authorized:
            return findPhone()
        case "Privacy_Accessibility":
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        case "Privacy_ScreenCapture":
            _ = CGRequestScreenCaptureAccess()
        case "Privacy_Automation":
            // The first ask shows the system prompt and blocks until answered; a past refusal can only be undone in System Settings.
            let bundles = Browser.bundles
            Task.detached {
                guard !bundles.allSatisfy({ ActivitySensor.automationOK($0, ask: true) }) else { return }
                await MainActor.run { Self.openSettings(item.pane) }
            }
            return
        default: break
        }
        Self.openSettings(item.pane)
    }

    /// Remembers the device in use next to the Mac as the owner's iPhone; from then on only it counts.
    func findPhone() {
        guard !findingPhone else { return }
        findingPhone = true
        refreshSetup()
        phone.find { found in
            Task { @MainActor in
                self.findingPhone = false
                if let found {
                    (self.settings.iPhone, self.settings.iPhoneName) = (found.id, found.name)
                    self.saveSettings()
                    self.phone.remember(found.id)
                }
                self.refreshSetup()
            }
        }
    }

    private static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func saveSettings() {
        store.save(settings)
        engine.settings = settings
        refreshGame()   // work days decide which missed days break the streak
    }

    private func tick() {
        let now = monotonic()
        if Calendar.current.startOfDay(for: Date()) != gameDay { refreshGame() }
        // Every 2 s while something is missing, so a switch flipped in System Settings shows at once.
        if now - setupAt >= (setup.allSatisfy(\.ok) ? 60 : 2) { refreshSetup() }
        let reading = cameraOn ? cam.latest : nil
        let idle = ActivitySensor.idleSeconds()
        // The iPhone matters only to the phone rule, which waits on a break or pause and while the screen is locked.
        if cameraOn { phone.update(idle: activity.asleep || engine.breakEndsAt != nil ? 0 : idle) }
        // The microphone matters only in a session (the engine reads it nowhere else).
        let t = Tick(now: now, date: Date(), app: activity.app, appName: activity.appName, title: activity.title, url: activity.url,
                     idle: idle, camera: reading, asleep: activity.asleep, permissionsOK: trackingOK, phoneInUse: cameraOn && phone.inUse,
                     micInUse: cameraOn && Microphone.inUse())
        if settings.developerMode == true, engine.record?.outcome == .running { recent.add(t, shownAt: shownAt) } else { recent.clear() }
        perform(engine.step(t))
        cam.want(engine.wantsCamera)
        // A card raised while the camera rested gets its frame once the stream has one.
        if evidence == nil, let shot = cameraEvidence(overlay) { evidence = shot }
        set(\.camera, reading)
        mirror(now)
    }

    private func perform(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .show(let reason):
                overlay = reason; shown += 1; shownAt = monotonic()
                evidence = cameraEvidence(reason)
                screen = nil
                iPhoneInUse = reason == .phone && phone.inUse
                if reason.needsScreen { captureScreen(for: shown) }
                OverlayController.shared.show()
            case .dismiss: overlay = nil; evidence = nil; screen = nil; shown += 1; shownAt = nil; OverlayController.shared.hide()
            case .chime: NSSound(named: "Glass")?.play()
            case .alarm(let on): if on { Alarm.start() } else { Alarm.stop() }
            case .sound(let cue): Sounds.play(cue)
            case .closeTab(let bundle): Browser.closeFrontTab(bundle)
            case .hideApp(let bundle): Browser.hide(bundle)
            case .injectCSS(let bundle): Browser.injectYouTubeCSS(bundle)
            case .notify(let text): notify("Focus", text)
            case .save: if let record = engine.record { store.save(record) }
            case .ended:
                cameraOn = false; activity.readsURL = false; cam.stop(); phone.stop()
                if let record = engine.record { store.save(record); score(record) }
                reload()
            }
        }
    }

    /// Folds the finished session into the game, then plays its sound and, when completed, posts its notification.
    private func score(_ record: SessionRecord) {
        let level = game.level
        summaries.removeAll { $0.id == record.session.id }
        summaries.append(SessionSummary(record))
        refreshGame()
        guard let award = game.awards.last(where: { $0.id == record.session.id }) else { self.award = nil; return }   // a false start
        self.award = award
        let levelUp = game.level > level
        garden.show(gardenSteps, level: levelUp ? game.level : nil, award: award)
        if levelUp { Sounds.play(.levelUp) } else if award.verdict == .perfect { Sounds.play(.perfect) } else if award.verdict == .good { Sounds.play(.good) }
        guard record.outcome == .completed else { return }
        notify(levelUp ? "Level \(game.level) · \(Progression.phase(game.level))" : award.title, "\(award.detail) · \(record.session.task)")
    }

    /// The garden's growth steps for the current XP.
    private var gardenSteps: Int { Garden.shared.stepCount(Progression.growth(game.xp)) }

    /// `--garden-demo`: no sensors, engine or tick. With the window up, the garden is drawn (as after a session) and then replays its reveal
    /// every 10 s; the app's CPU over the replay and its footprint before drawing, after drawing and at the end are printed, then it quits.
    private func demo(_ seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.activate() }   // the animations run only while the window is in view
        // No text cursor: its animation (macOS's own, about 12 points of WindowServer CPU) would drown the garden's cost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.windows.first { $0.title == "Focus" }?.makeFirstResponder(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            let before = Probe.footprintMB()
            garden.demo(at: gardenSteps)
            let drawn = Probe.footprintMB(), start = (wall: monotonic(), cpu: Probe.cpuSeconds())
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let cpu = (Probe.cpuSeconds() - start.cpu) / (monotonic() - start.wall) * 100
                let inView = NSApp.windows.contains { $0.title == "Focus" && $0.occlusionState.contains(.visible) }
                print(String(format: "garden demo: %.0f s, app CPU %.2f%%; footprint %.1f MB before drawing, %.1f MB after, %.1f MB at the end; window in view: %@",
                             seconds, cpu, before, drawn, Probe.footprintMB(), inView ? "yes" : "no"))
                exit(0)
            }
        }
    }

    /// `--garden-preview`: the game at the start of `level`, and the garden drawn there as after a session, with a level-up when it went up
    /// (withering when it went down).
    func preview(level: Int) {
        let from = game.level
        var state = GameState()
        state.xp = Progression.xp(forLevel: level)
        set(\.game, state)
        garden.show(gardenSteps, level: level > from ? level : nil, animated: level != from)
    }

    private func refreshGame() {
        set(\.game, Progression.progress(summaries, since: settings.gardenStart ?? Date(), today: Date(), workDays: settings.workDays))
        gameDay = Calendar.current.startOfDay(for: Date())
    }

    /// A banner, also while Focus is frontmost (AppDelegate). Our own sound plays instead of the notification's.
    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }  // UNUserNotificationCenter.current() crashes without a bundle identifier (unbundled swift run).
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The sensors that run only during a session.
    private func startSensors() { cameraOn = true; activity.readsURL = true; cam.start(); phone.start() }

    /// The camera frame a card shows: none for the no-session and permissions cards.
    private func cameraEvidence(_ reason: Reason?) -> CameraEvidence? {
        switch reason {
        case nil, .noSession?, .permissions?: nil
        case let reason?: cam.evidence(preferPhone: reason == .phone, raw: settings.developerMode == true)
        }
    }

    /// A card's box as the camera saw it (unmirrored), as [x, y, width, height].
    private static func box(_ r: CGRect) -> [Double] {
        let r = CameraEvidence.mirrored(r)
        return [r.minX, r.minY, r.width, r.height].map(Double.init)
    }

    /// Writes a `FalseAlarm` and its images as JPEG, off the main thread: about 100–300 KB per false alarm.
    private func keep(_ alarm: FalseAlarm, camera: CGImage?, screen: CGImage?) {
        let store = store
        DispatchQueue.global(qos: .utility).async {
            let jpeg = { (image: CGImage?) -> Data? in
                guard let image else { return nil }
                let data = NSMutableData()
                guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                return CGImageDestinationFinalize(out) ? data as Data : nil
            }
            store.save(alarm, files: ["camera.jpg": jpeg(camera), "screen.jpg": jpeg(screen)].compactMapValues { $0 })
        }
    }

    /// Fills in the screen image once captured; excludes Focus's own windows, so the overlay is never in it.
    private func captureScreen(for id: Int) {
        Task {
            let image = await ScreenSnapshot.capture()
            if id == shown { screen = image }
        }
    }

    private func mirror(_ now: Double = monotonic()) {
        set(\.session, engine.record?.session)
        set(\.category, engine.category)
        set(\.overlay, engine.overlay)
        set(\.remaining, engine.remaining)
        set(\.breakAvailable, engine.breakAvailable)
        set(\.breakRemaining, engine.breakEndsAt.map { max($0 - now, 0) })
        set(\.pausing, engine.pausing)
        set(\.pausesLeft, engine.pausesLeft)
        set(\.frontmost, activity.appName)
    }

    /// Writes the property only when the value changed, so SwiftUI does not re-render every second.
    private func set<T: Equatable>(_ path: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func refreshSetup() {
        let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let accessibility = ActivitySensor.accessibilityOK(), automation = Browser.bundles.allSatisfy { ActivitySensor.automationOK($0) }
        trackingOK = accessibility && automation
        set(\.setup, [
            SetupItem(name: "Camera", ok: camera, pane: "Privacy_Camera"),
            SetupItem(name: "Accessibility", ok: accessibility, pane: "Privacy_Accessibility"),
            SetupItem(name: "Automation (Safari, Chrome)", ok: automation, pane: "Privacy_Automation"),
            SetupItem(name: "Screen Recording", ok: CGPreflightScreenCaptureAccess(), pane: "Privacy_ScreenCapture"),
            SetupItem(name: settings.iPhoneName ?? "Your iPhone", ok: PhoneSensor.authorized && settings.iPhone != nil, pane: "Privacy_Bluetooth",
                      hint: !PhoneSensor.authorized ? "Allow Bluetooth in System Settings ›"
                          : findingPhone ? "Looking… unlock your iPhone next to the Mac" : "Click, then unlock it next to the Mac ›"),
        ])
        setupAt = monotonic()
    }

    private var weekAgo: Date { Date().addingTimeInterval(-7 * 86_400) }

    private func reload() {
        records = store.records(since: weekAgo)
        journal = store.journal(since: weekAgo)
    }
}

private extension Reason {
    /// Reasons about what is on screen get a screen thumbnail on the card.
    var needsScreen: Bool { switch self { case .distraction, .idle, .offline: true; default: false } }
}

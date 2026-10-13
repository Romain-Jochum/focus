import Foundation

/// The session state machine. Pure and deterministic: the app feeds it a `Tick` every second and performs the returned actions.
/// Behaviour and every threshold: docs/design.md.
public final class Engine {
    /// A relaunch gap longer than this is booked as untracked.
    static let untrackedGap = 5.0
    /// Idle below this counts as keyboard or mouse input.
    static let activeIdle = 2.0
    /// A tick gap longer than this is sleep: the rest of the gap is booked as away.
    static let maxStep = 5.0
    static let checkInGap = 60.0
    static let driftLimit = 20.0
    static let justifiedFor = 600.0
    /// After "I wasn't drifting", the rule that fired stays quiet this long.
    static let quietFor = 600.0
    static let awayLimit = 30.0
    /// No face but the microphone in use (talking, dictating, recording, often turned away): Away waits this long instead.
    static let awayLimitTalking = 120.0
    static let awayChime = 20.0
    static let closeAfter = 30.0
    /// An unanswered check-in turns into a looping alarm after this long.
    static let alarmAfter = 30.0
    static let permissionsRepeat = 60.0
    static let phoneIdle = 10.0
    /// The iPhone must report active use this long before it counts.
    static let phoneInUseFor = 15.0
    static let headDownIdle = 45.0
    static let headDownPitch = 20.0
    static let idleLimit = 180.0
    static let offlineWindow = 120.0
    static let offlineActive = 60
    static let noSessionIdle = 5.0
    static let noSessionActive = 180.0
    static let noSessionRepeat = 900.0
    static let breakEarnedAfter = 3000.0
    static let breakLength = 300.0
    /// A quick pause ends by itself once a face is back after this long without one.
    static let pauseArmAfter = 20.0
    /// Sessions this long get a second quick pause.
    static let secondPauseFrom = 90
    static let saveEvery = 30.0
    /// The face and phone rules need input to stop first, so the camera streams only after this long without input, and stops after
    /// `cameraHold` s of input (see `wantsCamera`). A lens covered while it rests is seen at the next such gap, so Away still comes
    /// 30 s after the last input.
    static let cameraIdle = 5.0
    static let cameraHold = 30.0
    static let wrapUpAt = 300.0

    public var settings: Settings
    public private(set) var record: SessionRecord?
    /// The reason the overlay is currently shown, nil when hidden.
    public private(set) var overlay: Reason?
    /// Category of the current second; nil when no session runs.
    public private(set) var category: Bucket?
    public private(set) var breakAvailable = false
    /// Monotonic time the current break or quick pause ends, nil when neither runs.
    public private(set) var breakEndsAt: Double?
    /// The running break is a quick pause.
    public private(set) var pausing = false
    /// Whether the camera should stream: in a running session, unless on a break or asleep, once input has stopped for `cameraIdle` s,
    /// until it has lasted `cameraHold` s, and always while a card or quick pause is up or the lens reads covered.
    public private(set) var wantsCamera = false

    private var lastNow: Double?
    private var lastFaceAt = -Double.infinity
    /// During a quick pause: when the face was first missing, and whether it was missing long enough for its return to end the pause.
    private var pauseEmptySince: Double?
    private var pauseArmed = false
    /// When the last chime played; repeats are timed from here.
    private var lastChime = -Double.infinity
    private var dismissedAt = -Double.infinity
    /// When the current overlay was raised, and whether its alarm is sounding.
    private var shownAt = -Double.infinity
    private var alarming = false
    /// Throttles the idle and phone timers: they restart from the last answer.
    private var answeredAt = -Double.infinity
    private var focusedSinceBreak = 0.0
    private var savedAt = 0.0
    /// Target → monotonic time until which it is justified.
    private var justified: [String: Double] = [:]
    /// Rule → monotonic time until which it stays quiet after a false alarm.
    private var quietUntil: [Reason: Double] = [:]
    /// Wall date the flagged stretch of the current check-in began.
    private var flaggedFrom: Date?
    /// The current contiguous run: its bucket, its drift target, and the wall date it began. A lock, sleep or a closed card ends it.
    private var runBucket: Bucket?
    private var runTarget: String?
    private var runStart = Date.distantPast
    /// Wall date the current tick's slice starts.
    private var tickStart = Date.distantPast
    /// The Away card is up but the user is back: it waits for an answer.
    private var awayBack = false
    private var driftTarget: String?
    /// When `driftTarget` was first seen unjustified.
    private var driftSince: Double?
    private var phoneHits = 0
    private var phoneInUseSince: Double?
    private var lastSample = -Double.infinity
    /// Since when input has had gaps shorter than `cameraIdle`.
    private var inputSince: Double?
    /// Monotonic time of each recent tick with keyboard or mouse input, for the offline rule.
    private var activity: [Double] = []
    private var lastCSSURL: String?
    private var nagActive = 0.0
    private var nagDue = -Double.infinity
    private var wrapUpSent = false

    public init(settings: Settings = Settings()) { self.settings = settings }

    /// Zero once the session has ended, so the UI moves to the reflection.
    public var remaining: Double { record.map { $0.outcome == .running ? Double($0.session.minutes * 60) - $0.elapsed : 0 } ?? 0 }

    /// Quick pauses still available in this session.
    public var pausesLeft: Int {
        guard let rec = record, rec.outcome == .running else { return 0 }
        return max((rec.session.minutes >= Self.secondPauseFrom ? 2 : 1) - (rec.pauses ?? 0), 0)
    }

    public func start(_ session: Session, now: Double) -> [Action] {
        begin(SessionRecord(session: session), now: now)
        return [.save]
    }

    /// Resume a persisted running session after a relaunch; the gap since `lastSeen` is booked as `untracked`.
    public func resume(_ record: SessionRecord, now: Double, date: Date) -> [Action] {
        var rec = record
        let gap = date.timeIntervalSince(record.lastSeen)
        if gap > Self.untrackedGap {
            rec.add(.untracked, seconds: gap, at: date)
            rec.elapsed += gap
        }
        begin(rec, now: now)
        if rec.elapsed >= Double(rec.session.minutes * 60) { return end(.completed) }
        return [.save]
    }

    public func step(_ tick: Tick) -> [Action] {
        var out = evaluate(tick)
        inputSince = tick.idle < Self.cameraIdle ? inputSince ?? tick.now : nil
        let typing = inputSince.map { tick.now - $0 >= Self.cameraHold } ?? false
        wantsCamera = record?.outcome == .running && !tick.asleep && (breakEndsAt == nil || pausing)
            && (!typing || overlay != nil || pausing || tick.camera?.presence == .blocked)
        // Not the permissions card: it steps aside while System Settings is open.
        let alarm = overlay != nil && overlay != .permissions && tick.now - shownAt >= Self.alarmAfter
        if alarm != alarming {
            alarming = alarm
            out.append(.alarm(alarm))
        }
        return out
    }

    private func evaluate(_ tick: Tick) -> [Action] {
        let gap = lastNow.map { max(tick.now - $0, 0) } ?? 1
        let dt = min(gap, Self.maxStep)
        lastNow = tick.now
        tickStart = tick.date.addingTimeInterval(-dt)
        var out: [Action] = []
        let cameraLost = tick.camera.map { [Presence.none, .blocked, .unauthorized].contains($0.presence) } ?? false
        // Keyboard or mouse input counts as presence when the camera sees no face (talking, or prompting while recording) or is off.
        if tick.camera?.presence == .face || ((tick.camera.map { $0.presence == .none } ?? true) && tick.idle < Self.activeIdle) { lastFaceAt = tick.now }
        if let end = breakEndsAt {
            if pausing {
                pauseEmptySince = cameraLost ? pauseEmptySince ?? tick.now : nil
                if let since = pauseEmptySince, tick.now - since >= Self.pauseArmAfter { pauseArmed = true }
            }
            if tick.now >= end || (pauseArmed && tick.camera?.presence == .face) {
                stopBreak()
                lastFaceAt = min(end, tick.now)
                out.append(.sound(.resume))
            }
        }

        // Away and permissions outrank every other overlay.
        let running = record?.outcome == .running
        let onBreak = running && breakEndsAt != nil
        let awayAfter = tick.micInUse && tick.camera?.presence == Presence.none ? Self.awayLimitTalking : Self.awayLimit
        let absent = cameraLost && tick.now - lastFaceAt >= awayAfter && !quiet(.away, tick.now)
        if running && !onBreak && absent && !tick.asleep {
            if overlay != .away {
                raise(.away, now: tick.now, &out)
            } else {
                // Left again while the card waited for an answer: the chimes resume.
                awayBack = false
                if tick.now - lastChime >= Self.awayChime { chime(now: tick.now, &out) }
            }
        } else if overlay == .away, running, !onBreak, !tick.asleep {
            // Back: the card stays until answered, and its alarm stops until it has waited another 30 s.
            if !awayBack {
                awayBack = true
                shownAt = tick.now
            }
        } else if overlay == .away {
            dismiss(now: tick.now, &out)
        }
        if running && !tick.permissionsOK {
            if overlay != .away, overlay != .permissions || tick.now - lastChime >= Self.permissionsRepeat {
                raise(.permissions, now: tick.now, &out)
            }
        } else if overlay == .permissions {
            dismiss(now: tick.now, &out)
        }

        guard let session = record?.session, running else {
            if record == nil { noSessionNag(tick, dt: dt, &out) }
            return out
        }
        if overlay == .noSession { dismiss(now: tick.now, &out) }
        // Soft check-ins are suppressed for the first 180 s of a session.
        let settled = (record?.elapsed ?? 0) >= Self.idleLimit

        let target = onBreak ? nil : Rules.target(app: tick.app, appName: tick.appName, url: tick.url, title: tick.title, settings: settings)
        if !onBreak, settings.isWorkTime(tick.date), Rules.isYouTube(tick.url), let app = tick.app, tick.url != lastCSSURL {
            lastCSSURL = tick.url
            out.append(.injectCSS(app))
        }

        if let camera = tick.camera, camera.at != lastSample {
            lastSample = camera.at
            phoneHits = camera.phone >= 0.5 ? phoneHits + 1 : 0
        }
        let idle = min(tick.idle, tick.now - answeredAt)
        // A microphone in use is work (talking, dictating, recording): it excuses the gaze rules only.
        let gazeIdle = tick.micInUse ? 0 : idle
        let headDown = session.mode == .computer && tick.camera?.presence == .face
            && (tick.camera?.pitchDown ?? 0) > Self.headDownPitch && gazeIdle >= Self.headDownIdle
        phoneInUseSince = tick.phoneInUse ? phoneInUseSince ?? tick.now : nil
        let iPhone = phoneInUseSince.map { tick.now - $0 >= Self.phoneInUseFor } ?? false
        let phone = (((phoneHits >= 2 || iPhone) && idle >= Self.phoneIdle) || headDown) && !quiet(.phone, tick.now)

        var drifting: String?
        if let t = target, justified[t, default: -.infinity] <= tick.now { drifting = t }
        if let t = drifting {
            if t != driftTarget {
                driftTarget = t
                driftSince = tick.now
            }
        } else {
            driftTarget = nil
            driftSince = nil
        }

        if session.mode == .offline, tick.idle < Self.activeIdle { activity.append(tick.now) }
        activity.removeAll { $0 < tick.now - Self.offlineWindow }

        // No ticks arrive while the Mac sleeps: the missed time counts as away.
        if gap > Self.maxStep {
            record?.add(.away, seconds: gap - dt, at: tick.date.addingTimeInterval(-dt))
            record?.elapsed += gap - dt
        }

        let bucket: Bucket
        if onBreak { bucket = .onBreak }
        else if !tick.permissionsOK { bucket = .untracked }
        else if absent || tick.asleep { bucket = .away }
        else if phone { bucket = .phone }
        else if drifting != nil { bucket = .drifting }
        else { bucket = .focused }
        record?.add(bucket, target: bucket == .drifting ? drifting : nil, seconds: dt, at: tick.date)
        record?.elapsed += dt
        category = bucket
        let bucketTarget = bucket == .drifting ? drifting : nil
        if tick.asleep {
            runBucket = nil
        } else if bucket != runBucket || bucketTarget != runTarget || gap > Self.maxStep {
            runBucket = bucket
            runTarget = bucketTarget
            runStart = tickStart
        }
        if bucket == .focused { addFocused(dt) }

        let elapsed = record?.elapsed ?? 0
        if elapsed >= Double(session.minutes * 60) { return end(.completed) }
        if elapsed - savedAt >= Self.saveEvery {
            savedAt = elapsed
            out.append(.save)
        }
        if !wrapUpSent, Double(session.minutes * 60) - elapsed <= Self.wrapUpAt {
            wrapUpSent = true
            out.append(.notify("5 minutes left on \(session.task)"))
        }

        // A distraction overlay unanswered for 30 s closes its tab (or hides the app when there is no URL), then repeats every 30 s with a chime.
        if case .distraction(let shown)? = overlay {
            if shown != driftTarget {
                dismiss(now: tick.now, &out)
            } else if tick.now - lastChime >= Self.closeAfter, let app = tick.app {
                out.append(tick.url == nil ? .hideApp(app) : .closeTab(app))
                chime(now: tick.now, &out)
            }
        }

        if !onBreak, overlay == nil, tick.now - dismissedAt >= Self.checkInGap {
            if phone {
                raise(.phone, now: tick.now, &out)
            } else if settled, session.mode == .computer, tick.camera?.presence == .face, gazeIdle >= Self.idleLimit, !quiet(.idle, tick.now) {
                raise(.idle, now: tick.now, &out)
            } else if settled, session.mode == .offline, activity.count > Self.offlineActive, !quiet(.offline, tick.now) {
                raise(.offline, now: tick.now, &out)
            } else if let t = driftTarget, let since = driftSince, tick.now - since >= Self.driftLimit {
                raise(.distraction(t), now: tick.now, &out)
            }
        }
        return out
    }

    /// Returns [] and keeps the overlay when `text` is not a valid answer.
    public func answer(_ answer: Answer, text: String, now: Double, date: Date) -> [Action] {
        guard Rules.isValidAnswer(text) else { return [] }
        if record?.outcome == .running, let reason = overlay {
            // String(describing:) is the stored key; SessionSummary skips "permissions" by name.
            record?.entries.append(Entry(at: date, reason: String(describing: reason), answer: answer.rawValue, text: text))
        }
        if answer == .notDrifting, record?.outcome == .running, let reason = overlay, reason.isCheckIn {
            let falseAlarms = (record?.falseAlarms ?? 0) + 1
            record?.falseAlarms = falseAlarms
            if let bucket = reason.bucket, let from = flaggedFrom {
                let moved = record?.relabel([bucket], from: from, to: date, as: .focused) ?? 0
                addFocused(moved)
            }
            if case .distraction(let target) = reason {
                justified[target] = now + Self.justifiedFor
            } else {
                quietUntil[reason] = now + Self.quietFor
            }
        }
        // Answering is proof of presence: an Away card answered while the camera sees no face does not come back.
        lastFaceAt = now
        answeredAt = now
        activity = []
        phoneHits = 0
        driftTarget = nil
        driftSince = nil
        nagActive = 0
        nagDue = now + Self.noSessionRepeat
        if answer == .takeBreak, breakAvailable { return takeBreak(now: now) }
        var out: [Action] = []
        dismiss(now: now, &out)
        out.append(.save)
        return out
    }

    public func takeBreak(now: Double) -> [Action] {
        guard record?.outcome == .running, breakAvailable else { return [] }
        breakAvailable = false
        breakEndsAt = now + Self.breakLength
        pausing = false
        focusedSinceBreak = 0
        var out: [Action] = []
        dismiss(now: now, &out)
        out.append(.save)
        return out
    }

    /// A quick pause (a bathroom trip): up to 5 minutes of break time that keeps the earned break. Not while a check-in is up.
    public func pause(now: Double) -> [Action] {
        guard pausesLeft > 0, breakEndsAt == nil, overlay == nil else { return [] }
        let used = record?.pauses ?? 0
        record?.pauses = used + 1
        breakEndsAt = now + Self.breakLength
        pausing = true
        return [.save]
    }

    /// "I'm back": ends the break or quick pause now; the rest of it is forfeited.
    public func endBreak(now: Double) -> [Action] {
        guard record?.outcome == .running, breakEndsAt != nil else { return [] }
        stopBreak()
        lastFaceAt = now
        return [.save]
    }

    public func endEarly(date: Date) -> [Action] {
        guard record?.outcome == .running else { return [] }
        record?.lastSeen = date
        return end(.abandoned)
    }

    /// Store the end-of-session reflection and close the record.
    public func reflect(_ text: String) -> [Action] {
        guard let done = record, done.outcome != .running else { return [] }
        record?.reflection = text
        record = nil
        category = nil
        return [.save]
    }

    private func begin(_ rec: SessionRecord, now: Double) {
        record = rec
        category = .focused
        lastNow = nil
        lastFaceAt = now
        breakAvailable = false
        stopBreak()
        focusedSinceBreak = 0
        savedAt = rec.elapsed
        wrapUpSent = false
        phoneHits = 0
        phoneInUseSince = nil
        inputSince = nil
        driftTarget = nil
        driftSince = nil
        justified = [:]
        quietUntil = [:]
        flaggedFrom = nil
        runBucket = nil
        awayBack = false
        activity = []
        lastCSSURL = nil
    }

    private func addFocused(_ seconds: Double) {
        focusedSinceBreak += seconds
        if focusedSinceBreak >= Self.breakEarnedAfter {
            breakAvailable = true
            focusedSinceBreak = 0
        }
    }

    private func quiet(_ reason: Reason, _ now: Double) -> Bool { quietUntil[reason, default: -.infinity] > now }

    private func end(_ outcome: Outcome) -> [Action] {
        let silence: [Action] = alarming ? [.alarm(false)] : []
        alarming = false
        record?.outcome = outcome
        overlay = nil
        category = nil
        breakAvailable = false
        stopBreak()
        return silence + [.dismiss, .ended(outcome), .save]
    }

    private func stopBreak() {
        breakEndsAt = nil
        pausing = false
        pauseEmptySince = nil
        pauseArmed = false
    }

    /// The no-session nag: 180 s of cumulative activity in work hours, then every 15 min while unanswered.
    private func noSessionNag(_ tick: Tick, dt: Double, _ out: inout [Action]) {
        guard settings.isWorkTime(tick.date) else { return }
        if tick.idle < Self.noSessionIdle { nagActive += dt }
        guard tick.now >= nagDue, overlay == .noSession || (overlay == nil && nagActive >= Self.noSessionActive) else { return }
        nagActive = 0
        nagDue = tick.now + Self.noSessionRepeat
        raise(.noSession, now: tick.now, &out)
    }

    private func raise(_ reason: Reason, now: Double, _ out: inout [Action]) {
        if overlay != reason {
            shownAt = now
            if reason.isCheckIn, let rec = record, rec.outcome == .running { record?.checkIns = (rec.checkIns ?? 0) + 1 }
            if reason.isCheckIn {
                flaggedFrom = reason.bucket != nil && runBucket == reason.bucket ? runStart : tickStart
                awayBack = false
            }
        }
        overlay = reason
        out.append(.show(reason))
        chime(now: now, &out)
    }

    private func dismiss(now: Double, _ out: inout [Action]) {
        if alarming { out.append(.alarm(false)) }
        alarming = false
        overlay = nil
        awayBack = false
        flaggedFrom = nil
        // A flagged stretch starts after the last card: time already answered is not flagged again.
        runBucket = nil
        dismissedAt = now
        out.append(.dismiss)
    }

    /// Silent while the alarm sounds; the repeat timers keep running.
    private func chime(now: Double, _ out: inout [Action]) {
        if !alarming { out.append(.chime) }
        lastChime = now
    }
}

private extension Reason {
    /// A card about the session's focus; the no-session and permissions cards are not.
    var isCheckIn: Bool { switch self { case .noSession, .permissions: false; default: true } }
    /// The bucket a check-in books its flagged time under; nil when it books focused time.
    var bucket: Bucket? { switch self { case .distraction: .drifting; case .phone: .phone; case .away: .away; default: nil } }
}

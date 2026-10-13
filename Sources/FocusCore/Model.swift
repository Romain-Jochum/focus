import Foundation

/// Where the session's work happens.
public enum Mode: String, Codable, Sendable { case computer, offline }

/// Every second of a session lands in exactly one category.
public enum Bucket: String, Codable, Sendable, CaseIterable {
    case focused, drifting, away, phone, onBreak, untracked
}

/// How a session ended.
public enum Outcome: String, Codable, Sendable { case running, completed, abandoned }

/// User preferences, saved as settings.json.
public struct Settings: Codable, Sendable, Equatable {
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday.
    public var workDays: Set<Int> = [2, 3, 4, 5, 6]
    /// Minutes after midnight.
    public var workStart = 9 * 60
    public var workEnd = 19 * 60
    public var domains = ["youtube.com", "youtu.be", "tiktok.com", "twitch.tv", "netflix.com", "9gag.com",
                          "instagram.com", "facebook.com", "x.com", "twitter.com", "reddit.com", "news.ycombinator.com"]
    /// Bundle identifiers of distracting apps.
    public var apps: [String] = []
    /// The owner's iPhone: its Bluetooth identifier on this Mac (stable for one's own devices) and its name. Nil until found.
    public var iPhone: UUID?
    public var iPhoneName: String?
    /// When the garden first appeared; XP is folded from the sessions since. Nil until then.
    public var gardenStart: Date?
    /// Developer mode: each check-in answered as a false alarm is kept on disk as a `FalseAlarm`, to tune detection with later. Nil is off.
    public var developerMode: Bool?

    public init() {}

    public func isWorkTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return workDays.contains(c.weekday ?? 0) && minute >= workStart && minute < workEnd
    }
}

/// What the user declared before starting: the task, its plan, mode and length.
public struct Session: Codable, Sendable, Equatable {
    public var id = UUID()
    public var task: String
    /// The "If I drift, I will…" line; may be empty.
    public var plan: String
    public var mode: Mode
    public var minutes: Int
    public var started: Date

    public init(task: String, plan: String = "", mode: Mode = .computer, minutes: Int, started: Date) {
        self.task = task; self.plan = plan; self.mode = mode; self.minutes = minutes; self.started = started
    }
}

/// A contiguous stretch of one category on the session timeline.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var category: Bucket
    /// Domain or app name for `drifting`, nil otherwise.
    public var target: String?
}

/// A typed answer: a check-in, a no-session nag, or the end-of-session reflection.
public struct Entry: Codable, Sendable, Equatable {
    public var at: Date
    public var reason: String
    public var answer: String
    public var text: String
    public init(at: Date, reason: String, answer: String, text: String) {
        self.at = at; self.reason = reason; self.answer = answer; self.text = text
    }
}

/// Developer mode: a check-in answered as a false alarm, with what the sensors read before it and while it was up. Its images (the
/// camera frame and the screen the card showed) are saved next to it.
public struct FalseAlarm: Codable, Sendable, Equatable {
    public var at: Date
    /// `Entry.reason`'s key, e.g. "phone", "away" or `distraction("youtube.com")`.
    public var reason: String
    /// The typed answer.
    public var text: String
    public var task: String
    public var mode: Mode
    /// The card's camera frame: face and phone boxes as [x, y, width, height] (normalized, top-left origin, as the camera sees it, not
    /// mirrored) and the phone model's score on it; and whether the iPhone reported use.
    public var face: [Double]?, phone: [Double]?, phoneScore: Double?
    public var iPhoneInUse: Bool
    /// One per second, oldest first: the minutes before the card and the time it was up. With `settings`, enough to replay the engine.
    public var ticks: [Tick]
    public var settings: Settings
    public init(at: Date, reason: String, text: String, task: String, mode: Mode, face: [Double]?, phone: [Double]?, phoneScore: Double?,
                iPhoneInUse: Bool, ticks: [Tick], settings: Settings) {
        self.at = at; self.reason = reason; self.text = text; self.task = task; self.mode = mode
        self.face = face; self.phone = phone; self.phoneScore = phoneScore; self.iPhoneInUse = iPhoneInUse; self.ticks = ticks
        self.settings = settings
    }
}

/// Developer mode: the ticks a `FalseAlarm` keeps, the last 3 minutes and, while a card is up, everything since 3 minutes before it.
public struct TickLog: Sendable {
    public static let lead = 180.0
    public private(set) var ticks: [Tick] = []
    public init() {}
    /// `shownAt`: when the card now up was raised, nil when none is.
    public mutating func add(_ tick: Tick, shownAt: Double?) {
        ticks.append(tick)
        let from = min(shownAt ?? tick.now, tick.now) - Self.lead
        if let first = ticks.first, first.now < from { ticks.removeAll { $0.now < from } }
    }
    public mutating func clear() { if !ticks.isEmpty { ticks = [] } }
}

/// The persisted ledger of one session.
public struct SessionRecord: Codable, Sendable, Equatable {
    public var session: Session
    /// Seconds counted toward the session timer.
    public var elapsed: Double = 0
    public var segments: [Segment] = []
    public var entries: [Entry] = []
    public var outcome: Outcome = .running
    public var reflection: String?
    /// Check-in cards raised (distraction, phone, idle, offline, away), answered or not. Nil in records from before it was counted.
    public var checkIns: Int?
    /// Check-in cards answered "I wasn't drifting": they do not count against the verdict. Nil in records from before.
    public var falseAlarms: Int?
    /// Quick pauses taken.
    public var pauses: Int?
    /// Last time the app was alive during this session; a later relaunch counts the gap as `untracked`.
    public var lastSeen: Date

    public init(session: Session) { self.session = session; lastSeen = session.started; checkIns = 0; falseAlarms = 0; pauses = 0 }

    /// Adds `seconds` ending at `date`, merging into the last segment when category and target match.
    public mutating func add(_ category: Bucket, target: String? = nil, seconds: Double, at date: Date) {
        guard seconds > 0 else { return }
        if var last = segments.last, last.category == category, last.target == target,
           abs(last.end.timeIntervalSince(date.addingTimeInterval(-seconds))) < 2 {
            last.end = date
            segments[segments.count - 1] = last
        } else {
            segments.append(Segment(start: date.addingTimeInterval(-seconds), end: date, category: category, target: target))
        }
        lastSeen = date
    }

    /// Re-books the parts of `categories` segments between `from` and `to` as `category` (no target), splitting segments at the edges
    /// and merging neighbours that end up alike. Returns the seconds moved.
    @discardableResult
    public mutating func relabel(_ categories: Set<Bucket>, from: Date, to: Date, as category: Bucket) -> Double {
        guard from < to else { return 0 }
        var moved = 0.0
        var parts: [Segment] = []
        for segment in segments {
            guard categories.contains(segment.category), segment.end > from, segment.start < to else { parts.append(segment); continue }
            let lo = max(segment.start, from), hi = min(segment.end, to)
            if segment.start < lo { parts.append(Segment(start: segment.start, end: lo, category: segment.category, target: segment.target)) }
            parts.append(Segment(start: lo, end: hi, category: category, target: nil))
            moved += hi.timeIntervalSince(lo)
            if hi < segment.end { parts.append(Segment(start: hi, end: segment.end, category: segment.category, target: segment.target)) }
        }
        segments = parts.reduce(into: []) { merged, next in
            if var last = merged.last, last.category == next.category, last.target == next.target,
               abs(last.end.timeIntervalSince(next.start)) < 2 {
                last.end = next.end
                merged[merged.count - 1] = last
            } else {
                merged.append(next)
            }
        }
        return moved
    }

    public func totals() -> [Bucket: Double] {
        segments.reduce(into: [:]) { $0[$1.category, default: 0] += $1.end.timeIntervalSince($1.start) }
    }
}

/// What the camera saw in its latest sample.
public enum Presence: String, Codable, Sendable, Equatable { case face, none, blocked, unauthorized }

public struct CameraReading: Codable, Sendable, Equatable {
    /// Monotonic time of the sample (same clock as `Tick.now`).
    public var at: Double
    public var presence: Presence
    /// Degrees the head is tilted down; 0 when no face.
    public var pitchDown: Double
    /// Best "cell phone" confidence in the frame, 0…1.
    public var phone: Double
    public init(at: Double, presence: Presence, pitchDown: Double = 0, phone: Double = 0) {
        self.at = at; self.presence = presence; self.pitchDown = pitchDown; self.phone = phone
    }
}

/// One snapshot of the world, assembled by the app once per second.
public struct Tick: Codable, Sendable, Equatable {
    /// Monotonic seconds; immune to wall-clock changes.
    public var now: Double
    public var date: Date
    /// Frontmost app bundle identifier and name.
    public var app: String?
    public var appName: String?
    /// Frontmost window title.
    public var title: String?
    /// Active tab URL when the frontmost app is Safari or Chrome.
    public var url: String?
    /// Seconds since the last keyboard or mouse input.
    public var idle: Double
    public var camera: CameraReading?
    /// Display asleep or screen locked.
    public var asleep: Bool
    /// Accessibility and Automation still granted.
    public var permissionsOK: Bool
    /// The iPhone nearby reports it is unlocked and in use (its Bluetooth "Nearby Info" advert).
    public var phoneInUse: Bool
    /// Some app is using the microphone (CoreAudio's device-running flag; no audio is read).
    public var micInUse: Bool

    public init(now: Double, date: Date, app: String? = nil, appName: String? = nil, title: String? = nil, url: String? = nil,
                idle: Double = 0, camera: CameraReading? = nil, asleep: Bool = false, permissionsOK: Bool = true, phoneInUse: Bool = false,
                micInUse: Bool = false) {
        self.now = now; self.date = date; self.app = app; self.appName = appName; self.title = title; self.url = url
        self.idle = idle; self.camera = camera; self.asleep = asleep; self.permissionsOK = permissionsOK; self.phoneInUse = phoneInUse
        self.micInUse = micInUse
    }
}

/// Why the overlay is up.
public enum Reason: Sendable, Hashable {
    case distraction(String), phone, idle, offline, away, noSession, permissions
}

/// The button pressed on a card.
public enum Answer: String, Sendable, Equatable {
    case back, takeBreak, drifted
    /// I wasn't drifting: a false alarm.
    case notDrifting
}

/// Short synthesized sounds besides the check-in chime and the alarm.
public enum Cue: String, Sendable, Equatable {
    /// A break or quick pause ended by itself.
    case resume
    case perfect, good, levelUp
}

/// Side effects the engine asks the app to perform.
public enum Action: Sendable, Equatable {
    /// Present, or replace, the check-in / alarm overlay.
    case show(Reason)
    case dismiss
    case chime
    /// Start (true) or stop the looping alarm of a check-in left unanswered.
    case alarm(Bool)
    case sound(Cue)
    /// Close the frontmost tab of this browser bundle id.
    case closeTab(String)
    case hideApp(String)
    /// Hide YouTube recommendations in the frontmost tab of this browser bundle id.
    case injectCSS(String)
    case notify(String)
    /// Persist the session record now.
    case save
    case ended(Outcome)
}

/// Monotonic seconds that keep counting through sleep and ignore wall-clock changes. Use for `Tick.now` and `CameraReading.at`.
public func monotonic() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

import Foundation

/// How a finished session counts toward the garden (docs/design.md, Progression).
public enum Verdict: String, Codable, Sendable { case perfect, good, drifted, abandoned }

/// What a scored session needs from its record, small enough to keep a year of them in memory.
public struct SessionSummary: Sendable, Equatable {
    public var id: UUID
    public var started: Date
    public var minutes: Int
    public var outcome: Outcome
    public var elapsed: Double
    public var focused: Double
    /// Break and quick-pause time, left out of the focused share.
    public var breaks: Double
    /// Check-ins that count: cards raised minus false alarms.
    public var checkIns: Int

    public init(_ record: SessionRecord) {
        let totals = record.totals()
        id = record.session.id; started = record.session.started; minutes = record.session.minutes; outcome = record.outcome
        elapsed = totals.values.reduce(0, +); focused = totals[.focused] ?? 0; breaks = totals[.onBreak] ?? 0
        // Older records only kept answered check-ins. False alarms do not count.
        checkIns = max((record.checkIns ?? record.entries.filter { $0.reason != "permissions" }.count) - (record.falseAlarms ?? 0), 0)
    }

    public init(id: UUID = UUID(), started: Date, minutes: Int, outcome: Outcome = .completed, focused: Double, breaks: Double = 0,
                elapsed: Double? = nil, checkIns: Int = 0) {
        self.id = id; self.started = started; self.minutes = minutes; self.outcome = outcome; self.focused = focused; self.breaks = breaks
        self.elapsed = elapsed ?? Double(minutes * 60); self.checkIns = checkIns
    }

    /// Focused time over session time, breaks and pauses left out.
    public var focusedShare: Double { focused / max(elapsed - breaks, 1) }
}

/// One scored session: its verdict, what made up its XP, and where it left the total.
public struct Award: Sendable, Equatable {
    public var id: UUID
    public var verdict: Verdict
    public var focusedMinutes: Int
    public var early = false
    public var late = false
    /// Consecutive kept days counting this one, and the bonus they give (0 … 0.5).
    public var streak = 0
    public var streakBonus = 0.0
    /// The daily multiplier: 1 + 0.3 for each boost. A perfect session of 90 minutes or more gets one once the day already has 3 perfect sessions totalling 4 h 30 focused time. Boosts stack.
    public var multiplier = 1.0
    /// Signed; a loss stops at the level's floor.
    public var xp = 0
    /// Total XP before and after.
    public var before: Double
    public var after: Double

    public init(id: UUID, verdict: Verdict, focusedMinutes: Int, early: Bool = false, late: Bool = false, streak: Int = 0, streakBonus: Double = 0,
                multiplier: Double = 1, xp: Int = 0, before: Double, after: Double) {
        self.id = id; self.verdict = verdict; self.focusedMinutes = focusedMinutes; self.early = early; self.late = late
        self.streak = streak; self.streakBonus = streakBonus; self.multiplier = multiplier; self.xp = xp; self.before = before; self.after = after
    }
}

/// The state of the game after folding every scored session.
public struct GameState: Sendable, Equatable {
    public var xp = 0.0
    /// Consecutive kept days, today included once kept.
    public var streak = 0
    public var freezes = 0
    /// Today's perfect sessions so far, their focused minutes, and how many got the daily multiplier.
    public var todayPerfect = 0
    public var todayMinutes = 0
    public var todayBoosts = 0
    public var awards: [Award] = []
    public init() {}

    public var level: Int { Progression.level(xp) }
    /// 0 … 1 through the current level; 1 at the last level.
    public var levelFraction: Double { Progression.levelFraction(xp) }
    public var toNextLevel: Int { level >= Progression.maxLevel ? 0 : Int((Progression.xp(forLevel: level + 1) - xp).rounded(.up)) }
    /// The multiplier the next perfect session of 90 minutes or more would get today; nil while it is locked.
    public var nextMultiplier: Double? {
        guard todayPerfect >= Progression.boostAfterSessions, todayMinutes >= Progression.boostAfterMinutes else { return nil }
        return 1 + Progression.boostStep * Double(todayBoosts + 1)
    }
}

/// XP, levels, streaks and garden growth: a fold over session summaries.
public enum Progression {
    public static let maxLevel = 100
    static let perfectMinMinutes = 25
    static let perfectShare = 0.95
    static let goodShare = 0.80
    static let goodCheckIns = 2
    static let driftedLoss = 0.10
    static let abandonedLoss = 0.25
    /// An abandoned session shorter than this is a false start and does not count.
    static let falseStart = 120.0
    static let streakStep = 0.05
    static let streakCap = 0.5
    static let earlyBonus = 0.25
    static let lateBonus = 0.25
    /// Minutes after midnight: early starts from 05:00 to 08:29, late ones from 19:00 to 21:59.
    static let earlyStarts = 5 * 60 ..< 8 * 60 + 30
    static let lateStarts = 19 * 60 ..< 22 * 60
    static let freezeEvery = 5
    static let maxFreezes = 2
    public static let boostAfterSessions = 3
    public static let boostAfterMinutes = 270
    public static let boostMinMinutes = 90
    public static let boostStep = 0.3

    /// Total XP to reach `level`: 150 · (L − 1)^1.4. L2 150, L10 3,251, L50 34,863, L100 93,321.
    public static func xp(forLevel level: Int) -> Double { 150 * pow(Double(max(level, 1) - 1), 1.4) }

    public static func level(_ xp: Double) -> Int {
        var level = 1
        while level < maxLevel, Self.xp(forLevel: level + 1) <= xp { level += 1 }
        return level
    }

    public static func levelFraction(_ xp: Double) -> Double {
        let level = level(xp)
        guard level < maxLevel else { return 1 }
        let floor = Self.xp(forLevel: level)
        return min(max((xp - floor) / (Self.xp(forLevel: level + 1) - floor), 0), 1)
    }

    /// How far the garden has grown, 0 … 1: half by level (quick at first) and half by XP (steady all year).
    public static func growth(_ xp: Double) -> Double {
        let byLevel = (Double(level(xp) - 1) + levelFraction(xp)) / Double(maxLevel - 1)
        return min(0.5 * byLevel + 0.5 * min(xp / Self.xp(forLevel: maxLevel), 1), 1)
    }

    /// Nil while the session runs, and for a false start.
    public static func verdict(_ s: SessionSummary) -> Verdict? {
        switch s.outcome {
        case .running: return nil
        case .abandoned: return s.elapsed < falseStart ? nil : .abandoned
        case .completed:
            if s.minutes >= perfectMinMinutes, s.checkIns == 0, s.focusedShare >= perfectShare { return .perfect }
            if s.checkIns <= goodCheckIns, s.focusedShare >= goodShare { return .good }
            return .drifted
        }
    }

    /// Folds the sessions (any order) day by day from `since` through `today`. A missed work day breaks the streak unless a freeze is held.
    public static func progress(_ sessions: [SessionSummary], since: Date, today: Date, workDays: Set<Int>, calendar: Calendar = .current) -> GameState {
        var p = GameState()
        let byDay = Dictionary(grouping: sessions.filter { $0.started >= since }) { calendar.startOfDay(for: $0.started) }
        let last = calendar.startOfDay(for: today)
        var day = calendar.startOfDay(for: since)
        var keptForFreeze = 0
        while day <= last {
            var kept = false
            (p.todayPerfect, p.todayMinutes, p.todayBoosts) = (0, 0, 0)
            for s in (byDay[day] ?? []).sorted(by: { $0.started < $1.started }) {
                guard let verdict = verdict(s) else { continue }
                var award = Award(id: s.id, verdict: verdict, focusedMinutes: Int((s.focused / 60).rounded()), before: p.xp, after: p.xp)
                let level = Self.level(p.xp)
                switch verdict {
                case .perfect:
                    let minute = calendar.component(.hour, from: s.started) * 60 + calendar.component(.minute, from: s.started)
                    award.early = earlyStarts.contains(minute)
                    award.late = lateStarts.contains(minute)
                    award.streak = p.streak + (kept ? 0 : 1)
                    award.streakBonus = min(streakStep * Double(award.streak - 1), streakCap)
                    if p.todayPerfect >= boostAfterSessions, p.todayMinutes >= boostAfterMinutes, s.minutes >= boostMinMinutes {
                        p.todayBoosts += 1
                        award.multiplier = 1 + boostStep * Double(p.todayBoosts)
                    }
                    let bonus = 1 + (award.early ? earlyBonus : 0) + (award.late ? lateBonus : 0) + award.streakBonus
                    award.xp = Int((s.focused / 60 * bonus * award.multiplier).rounded())
                    p.todayPerfect += 1
                    p.todayMinutes += award.focusedMinutes
                case .good: break
                case .drifted, .abandoned:
                    let span = xp(forLevel: min(level + 1, maxLevel)) - xp(forLevel: min(level, maxLevel - 1))
                    let loss = (verdict == .drifted ? driftedLoss : abandonedLoss) * span
                    award.xp = -Int(min(loss, p.xp - xp(forLevel: level)).rounded(.down))
                }
                p.xp += Double(award.xp)
                award.after = p.xp
                p.awards.append(award)
                if verdict == .perfect || verdict == .good {
                    if !kept { p.streak += 1 }
                    kept = true
                }
            }
            if kept {
                keptForFreeze += 1
                if keptForFreeze == freezeEvery { p.freezes = min(p.freezes + 1, maxFreezes); keptForFreeze = 0 }
            } else if day < last, workDays.contains(calendar.component(.weekday, from: day)) {
                if p.freezes > 0 { p.freezes -= 1 } else { p.streak = 0; keptForFreeze = 0 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return p
    }

    /// The garden's phase at a level.
    public static func phase(_ level: Int) -> String {
        switch level {
        case ..<5: "Barren"
        case ..<15: "Revival"
        case ..<30: "Meadow"
        case ..<50: "Grove"
        case ..<75: "Forest"
        case ..<100: "Ecosystem"
        default: "Restored"
        }
    }
}

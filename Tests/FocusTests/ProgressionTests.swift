import Foundation
import FocusCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let weekdays: Set<Int> = [2, 3, 4, 5, 6]

/// Day 12 of October 2026 is a Monday.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

/// A completed session focused for all of it unless told otherwise.
private func done(_ start: Date, _ minutes: Int, focused: Int? = nil, checkIns: Int = 0, outcome: Outcome = .completed, elapsed: Int? = nil) -> SessionSummary {
    SessionSummary(started: start, minutes: minutes, outcome: outcome, focused: Double((focused ?? minutes) * 60),
                   elapsed: elapsed.map { Double($0 * 60) }, checkIns: checkIns)
}

private func fold(_ sessions: [SessionSummary], today: Date? = nil) -> GameState {
    Progression.progress(sessions, since: at(12, 0), today: today ?? sessions.map(\.started).max() ?? at(12, 0), workDays: weekdays, calendar: calendar)
}

func progressionTests() {
    curve()
    verdicts()
    falseAlarmsDoNotCount()
    bonuses()
    streaks()
    dailyMultiplier()
    lossesStopAtTheFloor()
    pacing()
}

private func curve() {
    check(Progression.xp(forLevel: 1) == 0 && Progression.xp(forLevel: 2) == 150, "level 2 at 150 XP")
    check(Progression.xp(forLevel: 10).rounded() == 3251 && Progression.xp(forLevel: 100).rounded() == 93321, "the curve's checkpoints")
    check(Progression.level(149) == 1 && Progression.level(150) == 2 && Progression.level(1e9) == 100, "levels from XP, capped at 100")
    check(Progression.levelFraction(1e9) == 1 && abs(Progression.levelFraction(225) - 75 / (Progression.xp(forLevel: 3) - 150)) < 1e-9, "fraction through a level")
    let samples = stride(from: 0.0, through: 100_000, by: 250).map(Progression.growth)
    check(samples.first == 0 && samples.last == 1 && zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "growth rises from 0 to 1")
    check(Progression.growth(150) > 0.004, "the first level grows the garden visibly")
}

private func verdicts() {
    let monday = at(12, 10)
    check(Progression.verdict(done(monday, 50, focused: 48)) == .perfect, "96% focused, no check-in: perfect")
    check(Progression.verdict(done(monday, 20)) == .good, "under 25 minutes is never perfect")
    check(Progression.verdict(done(monday, 50, checkIns: 1)) == .good, "one check-in: good")
    check(Progression.verdict(done(monday, 50, focused: 42)) == .good, "84% focused: good")
    check(Progression.verdict(done(monday, 50, focused: 49, checkIns: 3)) == .drifted, "three check-ins: drifted")
    check(Progression.verdict(done(monday, 50, focused: 35)) == .drifted, "70% focused: drifted")
    check(Progression.verdict(done(monday, 50, focused: 20, outcome: .abandoned, elapsed: 25)) == .abandoned, "ended early: abandoned")
    check(Progression.verdict(done(monday, 50, focused: 1, outcome: .abandoned, elapsed: 1)) == nil, "ended within 2 minutes: a false start")
    check(Progression.verdict(done(monday, 50, outcome: .running)) == nil, "running: no verdict yet")
    var withBreak = done(monday, 50, focused: 45)
    withBreak.breaks = 300
    check(Progression.verdict(withBreak) == .perfect, "break time is left out of the focused share")

    var record = SessionRecord(session: Session(task: "t", minutes: 25, started: monday))
    record.add(.focused, seconds: 1500, at: monday.addingTimeInterval(1500))
    record.outcome = .completed
    check(Progression.verdict(SessionSummary(record)) == .perfect, "a summary from a record")
    record.checkIns = nil
    record.entries = [Entry(at: monday, reason: "permissions", answer: "back", text: "granted it again")]
    check(SessionSummary(record).checkIns == 0, "older records count answered check-ins, not the permissions card")
}

private func falseAlarmsDoNotCount() {
    var record = SessionRecord(session: Session(task: "t", minutes: 50, started: at(12, 10)))
    record.add(.focused, seconds: 3000, at: at(12, 10).addingTimeInterval(3000))
    record.outcome = .completed
    record.checkIns = 1
    record.falseAlarms = 1
    check(Progression.verdict(SessionSummary(record)) == .perfect, "a check-in answered I wasn't drifting does not count: perfect")
    record.checkIns = 2
    record.falseAlarms = 0
    check(Progression.verdict(SessionSummary(record)) != .perfect, "two real check-ins are not perfect")
    check(SessionSummary(record).checkIns == 2, "check-ins that count are the cards raised minus false alarms")
    record.checkIns = nil
    record.falseAlarms = nil
    check(SessionSummary(record).checkIns == 0, "records from before false alarms count their answered check-ins")
}

private func bonuses() {
    check(fold([done(at(12, 10), 50)]).xp == 50, "a perfect 50 minutes is 50 XP")
    check(fold([done(at(12, 7, 30), 50)]).xp == 63, "early start: +25%")
    check(fold([done(at(12, 20), 50)]).xp == 63, "late start: +25%")
    check(fold([done(at(12, 22, 30), 50)]).xp == 50, "no bonus from 22:00")
    check(fold([done(at(12, 4), 50)]).xp == 50, "no early bonus before 05:00")
    check(fold([done(at(12, 10), 50, checkIns: 1)]).xp == 0, "a good session is 0 XP")
}

private func streaks() {
    let three = fold([done(at(12, 10), 50), done(at(13, 10), 50), done(at(14, 10), 50)])
    check(three.awards.map(\.streak) == [1, 2, 3] && three.awards.last?.xp == 55, "day 3 of a streak: +10%")
    let missed = fold([done(at(12, 10), 50), done(at(13, 10), 50), done(at(15, 10), 50)])
    check(missed.awards.last?.streak == 1, "a missed work day breaks the streak")
    let weekend = fold([done(at(16, 10), 50), done(at(19, 10), 50)])
    check(weekend.awards.last?.streak == 2, "the weekend never breaks it")
    let good = fold([done(at(12, 10), 50, checkIns: 1), done(at(13, 10), 50)])
    check(good.awards.last?.streak == 2, "a good session keeps the day")
    // Monday to Friday kept earns a freeze, spent on the next Monday.
    let week = (12...16).map { done(at($0, 10), 50) }
    check(fold(week).freezes == 1, "five kept days earn a freeze")
    let frozen = fold(week + [done(at(20, 10), 50)])
    check(frozen.awards.last?.streak == 6 && frozen.freezes == 0, "the freeze covers a missed day")
    check(fold(week, today: at(19, 18)).streak == 5, "today is not missed until it is over")
    check(fold([done(at(12, 10), 50)], today: at(14, 9)).streak == 0, "a missed day without a freeze ends the streak")
}

private func dailyMultiplier() {
    let day = [9, 11, 13, 15, 17].map { done(at(12, $0), 90) }
    let p = fold(day)
    check(p.awards.map(\.multiplier) == [1, 1, 1, 1.3, 1.6], "after 4 h 30 in three perfect sessions, each further 90 minutes: +30%")
    check(p.awards.map(\.xp) == [90, 90, 90, 117, 144], "boosted XP")
    check(fold(Array(day.prefix(3))).nextMultiplier == 1.3, "the next boost is shown")
    check(fold([9, 10, 11].map { done(at(12, $0), 50) }).nextMultiplier == nil, "locked under 4 h 30")
    let short = fold(Array(day.prefix(3)) + [done(at(12, 17), 50)])
    check(short.awards.last?.multiplier == 1, "a session under 90 minutes is not boosted")
}

private func lossesStopAtTheFloor() {
    let span = Progression.xp(forLevel: 3) - 150
    let p = fold([done(at(12, 8, 40), 200), done(at(12, 12), 50, checkIns: 3), done(at(12, 13), 50, outcome: .abandoned, elapsed: 10),
                  done(at(12, 14), 50, outcome: .abandoned, elapsed: 10)])
    check(p.awards.map(\.xp) == [200, -Int(0.1 * span), -26, 0], "drifted takes 10% of the level's span, abandoned 25%, never below the floor")
    check(p.level == 2 && p.xp == 150, "levels never drop")
}

/// Pacing: weeks to reach level 100 on a heavy and on a light schedule of perfect sessions.
private func pacing() {
    func weeksToLevel100(_ day: (Int) -> [SessionSummary]) -> Int? {
        let days = (0..<7 * 104).flatMap { day($0) }
        let p = Progression.progress(days, since: at(12, 0), today: days.last!.started, workDays: weekdays, calendar: calendar)
        return p.awards.first { Progression.level($0.after) >= 100 }
            .flatMap { award in days.first { $0.id == award.id } }
            .map { Int($0.started.timeIntervalSince(at(12, 0)) / (7 * 86_400)) + 1 }
    }
    func session(_ d: Int, _ hour: Int, _ minutes: Int) -> SessionSummary { done(at(12, hour).addingTimeInterval(Double(d) * 86_400), minutes) }
    let heavy = weeksToLevel100 { d in
        switch d % 7 {
        case 0...4: [session(d, 9, 50), session(d, 10, 50), session(d, 13, 90), session(d, 15, 90)]
        case 5: [session(d, 10, 50), session(d, 11, 50)]
        default: []
        }
    }
    let light = weeksToLevel100 { d in d % 7 < 5 ? [session(d, 9, 50), session(d, 14, 50)] : [] }
    check((40...70).contains(heavy ?? 0), "every session perfect on a heavy schedule: level 100 in 40 to 70 weeks (\(heavy ?? -1))")
    check((light ?? .max) > 52, "a light schedule takes more than a year (\(light ?? -1))")
}

import Foundation
import FocusCore

private typealias Log = [(t: Int, actions: [Action])]

private func date(hour: Int) -> Date {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 10; parts.day = 12; parts.hour = hour // a Monday
    return Calendar.current.date(from: parts)!
}
private let workDate = date(hour: 10)
private let eveningDate = date(hour: 20)
private let safari = "com.apple.Safari"
private let youtube = "https://www.youtube.com/"
private let distraction = Action.show(.distraction("youtube.com"))
private let phoneShow = Action.show(.phone)

private func session(_ minutes: Int = 25, mode: Mode = .computer) -> Session {
    Session(task: "write the spec", mode: mode, minutes: minutes, started: workDate)
}

private func tick(_ t: Int, app: String? = nil, url: String? = nil, idle: Double = 0, presence: Presence = .face,
                  pitch: Double = 0, phone: Double = 0, asleep: Bool = false, permissions: Bool = true,
                  iPhone: Bool = false, date: Date? = nil, mic: Bool = false, cameraOff: Bool = false) -> Tick {
    let camera = cameraOff ? nil : CameraReading(at: Double(t), presence: presence, pitchDown: pitch, phone: phone)
    return Tick(now: Double(t), date: date ?? workDate.addingTimeInterval(Double(t)), app: app, appName: app, url: url, idle: idle,
                camera: camera, asleep: asleep, permissionsOK: permissions, phoneInUse: iPhone, micInUse: mic)
}

/// Feeds one tick per second over `range` and keeps the seconds that produced actions.
private func run(_ engine: Engine, _ range: ClosedRange<Int>, _ make: (Int) -> Tick) -> Log {
    range.compactMap { t in
        let actions = engine.step(make(t))
        return actions.isEmpty ? nil : (t: t, actions: actions)
    }
}

private func actions(_ log: Log, at t: Int) -> [Action] { log.first { $0.t == t }?.actions ?? [] }

private func occurrences(_ log: Log, of action: Action) -> [Int] {
    log.filter { $0.actions.contains(action) }.map(\.t)
}

func engineTests() {
    distractionIsCaughtAndClosed()
    justifiedTargetIsAllowedForTenMinutes()
    awayAlarmStopsWhenBackAndWaitsForAnswer()
    typingMeansPresent()
    cameraStreamsOnlyWhenItMatters()
    awayFalseAlarmCostsNothing()
    falseAlarmKeepsItsLeadUp()
    distractionFalseAlarmRebooksTime()
    answeredTimeIsNotFlaggedAgain()
    newTargetIsFlaggedOnItsOwn()
    lockedTimeIsNotRebooked()
    justificationEndsWithTheSession()
    headDownFalseAlarmCostsNothing()
    microphoneMeansWorking()
    relabelRebooksSegments()
    asleepCountsAsAwayWithoutNags()
    sleepGapCountsAsAway()
    endedEarlyHasNoTimeLeft()
    phoneNeedsTwoConsecutiveSamples()
    headDownCountsAsPhone()
    idleIsSuppressedDuringSettling()
    offlineRuleFiresAfterSettling()
    noSessionNagOnlyInWorkHours()
    bothModeWorksOnPaperAndComputer()
    breakIsEarnedTakenAndOverrunIsAway()
    breakEndsEarlyWhenBack()
    quickPauseEndsWhenTheFaceReturns()
    quickPauseOverrunIsAway()
    breaksPauseTheSessionTimer()
    checkInsAreCounted()
    answerValidation()
    completionThenReflect()
    endEarlyAbandons()
    resumeBooksGapAsUntracked()
    permissionsRepeatAndClear()
    permissionsSilentWithoutSession()
    iPhoneInUseCountsAsPhone()
    checkInThrottle()
    wrapUpNotifiesOnceFiveMinutesOut()
    youtubeCSSOncePerURL()
}

private func distractionIsCaughtAndClosed() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...60) { tick($0, app: safari, url: youtube) }
    check(actions(log, at: 19).isEmpty, "no check-in before 20 s")
    check(actions(log, at: 20).contains(distraction), "check-in at 20 s")
    check(actions(log, at: 50).contains(.closeTab(safari)), "tab closed at 50 s")
}

private func justifiedTargetIsAllowedForTenMinutes() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    var log = run(engine, 0...25) { tick($0, app: safari, url: youtube) }
    let answered = engine.answer(.notDrifting, text: "reading the docs", now: 25, date: workDate)
    check(answered == [.dismiss, .save], "not drifting dismisses and saves")
    log += run(engine, 26...700) { tick($0, app: safari, url: youtube) }
    check(occurrences(log, of: distraction) == [20, 645], "justified for 600 s, then asked again after 20 s of drift")

    // "I drifted, back to the task" does not justify the target: it is asked again after the check-in gap.
    let back = Engine()
    _ = back.start(session(), now: 0)
    _ = run(back, 0...25) { tick($0, app: safari, url: youtube) }
    _ = back.answer(.back, text: "reading the docs", now: 25, date: workDate)
    let again = run(back, 26...120) { tick($0, app: safari, url: youtube) }
    check(occurrences(again, of: distraction) == [85], "back does not justify the target: asked again at 85 s, after the 60 s gap")
}

private func awayAlarmStopsWhenBackAndWaitsForAnswer() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...100) { tick($0, idle: 999, presence: $0 < 86 ? .none : .face) }
    check(occurrences(log, of: .show(.away)) == [30], "away alarm at 30 s without a face")
    check(occurrences(log, of: .chime) == [30, 50], "away chimes every 20 s until the alarm takes over")
    check(occurrences(log, of: .alarm(true)) == [60], "unanswered for 30 s, the alarm loops")
    check(occurrences(log, of: .alarm(false)) == [86], "back at the desk, the alarm stops")
    check(occurrences(log, of: .dismiss).isEmpty && engine.overlay == .away, "the away card waits for an answer once back")
    check(engine.record?.totals()[.away] == 56, "the away seconds stay booked as away")
    _ = engine.answer(.back, text: "checking the docs", now: 101, date: workDate.addingTimeInterval(101))
    check(engine.overlay == nil && engine.record?.checkIns == 1, "answering I was away dismisses it, one check-in")
}

private func typingMeansPresent() {
    let typing = Engine()
    _ = typing.start(session(), now: 0)
    let log = run(typing, 0...120) { tick($0, idle: 0, presence: .none) }
    check(occurrences(log, of: .show(.away)).isEmpty, "typing with no face in view is not away")
    check(typing.record?.totals()[.away] == nil, "typing with no face in view books no away time")

    let covered = Engine()
    _ = covered.start(session(), now: 0)
    let blocked = run(covered, 0...40) { tick($0, idle: 0, presence: .blocked) }
    check(occurrences(blocked, of: .show(.away)) == [30], "a covered camera is away at 30 s, input or not")
}

/// Runs the engine with a camera that reads only while the engine wanted it the second before, as the app does; returns the
/// seconds it was wanted after.
private func gated(_ engine: Engine, _ range: ClosedRange<Int>, _ log: inout Log, _ make: (Int, Bool) -> Tick) -> [Int] {
    range.filter { t in
        let actions = engine.step(make(t, !engine.wantsCamera))
        if !actions.isEmpty { log.append((t: t, actions: actions)) }
        return engine.wantsCamera
    }
}

private func cameraStreamsOnlyWhenItMatters() {
    // Typing from the start with no face in view, then gone at 100 s.
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    var log: Log = []
    let on = gated(engine, 0...200, &log) { t, off in tick(t, idle: t < 100 ? 0 : Double(t - 100), presence: .none, cameraOff: off) }
    check(on == Array(0...29) + Array(105...200), "the camera checks for 30 s, rests while typing, and is back 5 s after the input stops")
    let always = Engine()
    _ = always.start(session(), now: 0)
    let reference = run(always, 0...200) { t in tick(t, idle: t < 100 ? 0 : Double(t - 100), presence: .none) }
    check(occurrences(log, of: .show(.away)) == [131] && occurrences(reference, of: .show(.away)) == [131],
          "away fires at the same second as with the camera always on")

    let covered = Engine()
    _ = covered.start(session(), now: 0)
    log = []
    let blocked = gated(covered, 0...40, &log) { t, off in tick(t, idle: 0, presence: .blocked, cameraOff: off) }
    check(blocked.count == 41 && occurrences(log, of: .show(.away)) == [30], "a covered lens keeps the camera on: away at 30 s, input or not")
    let shut = Engine()
    _ = shut.start(session(), now: 0)
    log = []
    _ = gated(shut, 0...200, &log) { t, off in tick(t, idle: t < 150 ? 0 : Double(t - 150), presence: t < 40 ? .face : .blocked, cameraOff: off) }
    check(occurrences(log, of: .show(.away)) == [181], "a lens covered while the camera rests is seen once input stops: away 30 s after the last input")

    let card = Engine()
    _ = card.start(session(), now: 0)
    log = []
    let carded = gated(card, 0...60, &log) { t, off in tick(t, app: safari, url: youtube, cameraOff: off) }
    check(occurrences(log, of: distraction) == [20] && carded.count == 61, "the camera stays on while a card is up")
    _ = card.answer(.drifted, text: "back to the spec now", now: 61, date: workDate.addingTimeInterval(61))
    _ = card.step(tick(62))
    check(!card.wantsCamera, "and rests again once it is answered while typing")

    _ = card.step(tick(63, idle: 999, asleep: true))
    check(!card.wantsCamera, "off while the screen is locked")
    check(card.pause(now: 64) == [.save], "a quick pause starts")
    _ = card.step(tick(64))
    check(card.wantsCamera, "on through a quick pause, input or not: its end waits for the face")
}

private func awayFalseAlarmCostsNothing() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    var log = run(engine, 0...69) { tick($0, idle: 999, presence: .none) }
    check(occurrences(log, of: .show(.away)) == [30] && occurrences(log, of: .alarm(true)) == [60], "away card at 30 s, alarm at 60 s")
    log = run(engine, 70...80) { tick($0, idle: 0, presence: .none) }
    check(occurrences(log, of: .alarm(false)) == [70] && occurrences(log, of: .dismiss).isEmpty, "input at 70 s stops the alarm and keeps the card")
    check(engine.overlay == .away, "the card is still up after input")
    _ = engine.answer(.notDrifting, text: "I was talking to someone", now: 81, date: workDate.addingTimeInterval(81))
    check(engine.record?.falseAlarms == 1, "the answer is a false alarm")
    check(engine.record?.totals()[.away] == nil, "the away seconds are re-booked as focused")
    check(engine.record?.totals()[.focused] == 81, "the re-booked seconds count as focused: all 81 s of the session")
    let quietLog = run(engine, 82...142) { tick($0, idle: 999, presence: .none) }
    check(occurrences(quietLog, of: .show(.away)).isEmpty, "no face and no input for 60 s after a false alarm: no card")
    check(engine.record?.totals()[.away] == nil, "the quiet minute is focused")
}

/// Developer mode: the ticks kept for a false alarm cover the 3 minutes before its card and the card's whole time up.
private func falseAlarmKeepsItsLeadUp() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    var recent = TickLog(), shownAt: Double?
    for t in 0...400 {
        let tk = tick(t, idle: t < 300 ? 0 : Double(t - 300), presence: t < 300 ? .face : .none)
        if engine.step(tk).contains(.show(.away)) { shownAt = Double(t) }
        recent.add(tk, shownAt: shownAt)
    }
    check(shownAt == 331, "away card 30 s after the last input")
    check(recent.ticks.first?.now == 151 && recent.ticks.last?.now == 400 && recent.ticks.count == 250,
          "the log runs from 3 minutes before the card to now, one tick a second")
    recent.add(tick(401), shownAt: nil)
    check(recent.ticks.first?.now == 221, "with no card up, only the last 3 minutes")
    recent.clear()
    check(recent.ticks.isEmpty, "cleared when developer mode is off")
}

private func distractionFalseAlarmRebooksTime() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...20) { tick($0, app: safari, url: youtube) }
    check(engine.overlay == .distraction("youtube.com"), "youtube for 20 s raises the check-in")
    check((engine.record?.totals()[.drifting] ?? 0) > 0, "the drifting time is booked before the answer")
    _ = engine.answer(.notDrifting, text: "reading the docs", now: 21, date: workDate.addingTimeInterval(21))
    check((engine.record?.totals()[.drifting] ?? 0) == 0, "drifting time is re-booked as focused")
    check(engine.record?.falseAlarms == 1 && engine.record?.checkIns == 1, "one check-in, one false alarm")
    let log = run(engine, 21...700) { tick($0, app: safari, url: youtube) }
    check(occurrences(log, of: distraction) == [641], "the target is allowed for 10 minutes, then asked again 20 s into drift")
}

private func answeredTimeIsNotFlaggedAgain() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...20) { tick($0, app: safari, url: youtube) }
    _ = engine.answer(.drifted, text: "went to the news", now: 21, date: workDate.addingTimeInterval(21))
    let admitted = engine.record?.totals()[.drifting] ?? 0
    _ = run(engine, 21...81) { tick($0, app: safari, url: youtube) }
    check(engine.overlay == .distraction("youtube.com"), "youtube continues: the second card is up at 81 s")
    _ = engine.answer(.notDrifting, text: "reading the docs", now: 81, date: workDate.addingTimeInterval(81))
    check((engine.record?.totals()[.drifting] ?? 0) >= admitted, "the seconds admitted as drifting before 21 s stay drifting")
    check(engine.record?.falseAlarms == 1 && engine.record?.checkIns == 2, "two check-ins, one false alarm")
}

private func newTargetIsFlaggedOnItsOwn() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...20) { tick($0, app: safari, url: youtube) }
    check(engine.overlay == .distraction("youtube.com"), "youtube for 20 s raises the check-in")
    let log = run(engine, 21...81) { tick($0, app: safari, url: "https://www.reddit.com/") }
    check(occurrences(log, of: .dismiss) == [21], "a new distracting site closes the youtube card")
    check(occurrences(log, of: .show(.distraction("reddit.com"))) == [81], "reddit gets its own card after the check-in gap")
    _ = engine.answer(.notDrifting, text: "reading a thread for work", now: 82, date: workDate.addingTimeInterval(82))
    let youtubeTime = engine.record?.segments.filter { $0.target == "youtube.com" }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    check(youtubeTime == 21, "a false alarm on reddit leaves the unanswered youtube seconds drifting")
}

private func lockedTimeIsNotRebooked() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...9) { tick($0) }
    _ = run(engine, 10...309) { tick($0, idle: 999, presence: .none, asleep: true) }
    let log = run(engine, 310...315) { tick($0, idle: 999, presence: .none) }
    check(occurrences(log, of: .show(.away)) == [310], "unlocked with no face and no input: the away card at once")
    _ = engine.answer(.notDrifting, text: "reading the printed spec", now: 316, date: workDate.addingTimeInterval(316))
    check(engine.record?.totals()[.away] == 300, "I was here re-books the seconds since the unlock, not the locked time")
}

private func justificationEndsWithTheSession() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...20) { tick($0, app: safari, url: youtube) }
    _ = engine.answer(.notDrifting, text: "reading the docs", now: 21, date: workDate.addingTimeInterval(21))
    _ = engine.endEarly(date: workDate.addingTimeInterval(30))
    _ = engine.reflect("cut short")
    _ = engine.start(session(), now: 200)
    let log = run(engine, 200...220) { tick($0, app: safari, url: youtube) }
    check(occurrences(log, of: distraction) == [220], "a new session does not inherit the justified target: asked again 20 s into drift")
}

private func headDownFalseAlarmCostsNothing() {
    let engine = Engine()
    _ = engine.start(session(90), now: 0)
    _ = run(engine, 0...45) { tick($0, idle: Double($0), pitch: 30) }
    check(engine.overlay == .phone, "head down with 45 s of no input raises the check-in")
    _ = engine.answer(.notDrifting, text: "reading on paper", now: 46, date: workDate.addingTimeInterval(46))
    check(engine.record?.falseAlarms == 1 && engine.record?.checkIns == 1, "one check-in, one false alarm")
    check((engine.record?.totals()[.phone] ?? 0) == 0, "the flagged phone time is re-booked as focused")
    // The idle rule (180 s without input) is separate from the phone quiet, so its card comes up at 226 and is answered too;
    // the phone quiet lasts 600 s from the first answer.
    let quietLog = run(engine, 46...226) { tick($0, idle: Double($0), pitch: 30) }
    check(occurrences(quietLog, of: phoneShow).isEmpty, "head down with no input for 3 minutes: no phone card")
    check(occurrences(quietLog, of: .show(.idle)) == [226], "the idle card follows at 180 s without input")
    check(engine.record?.totals()[.phone] == nil, "the quiet time books as focused")
    _ = engine.answer(.notDrifting, text: "reading on paper", now: 226, date: workDate.addingTimeInterval(226))
    let nineMinutes = run(engine, 227...645) { tick($0, idle: Double($0), pitch: 30) }
    let cards = nineMinutes.flatMap(\.actions).filter { if case .show = $0 { true } else { false } }
    check(cards.isEmpty, "head down with no input for the rest of the 10 minutes: no card at all")
    let again = run(engine, 646...700) { tick($0, idle: Double($0), pitch: 30) }
    check(occurrences(again, of: phoneShow) == [646], "after 600 s the phone card can fire again")
    check(engine.record?.falseAlarms == 2, "the idle false alarm is counted too")
}

private func microphoneMeansWorking() {
    let engine = Engine()
    _ = engine.start(session(90), now: 0)
    let log = run(engine, 0...240) { tick($0, idle: Double($0), pitch: 30, mic: true) }
    check(occurrences(log, of: phoneShow).isEmpty, "head down while the microphone is in use is not a phone check-in")
    check(occurrences(log, of: .show(.idle)).isEmpty, "no input while the microphone is in use is not an idle check-in")

    let iPhoneCall = Engine()
    _ = iPhoneCall.start(session(), now: 0)
    let phoneLog = run(iPhoneCall, 0...25) { tick($0, idle: Double($0), iPhone: $0 >= 5, mic: true) }
    check(occurrences(phoneLog, of: phoneShow) == [20], "the microphone does not excuse an iPhone in use")

    // Talking turned away from the camera: Away waits 2 minutes, but a covered camera is still away at 30 s.
    let talking = Engine()
    _ = talking.start(session(), now: 0)
    let talkLog = run(talking, 0...130) { tick($0, idle: 999, presence: .none, mic: true) }
    check(occurrences(talkLog, of: .show(.away)) == [120], "no face while the microphone is in use is away after 120 s, not 30 s")
    let covered = Engine()
    _ = covered.start(session(), now: 0)
    let coveredLog = run(covered, 0...40) { tick($0, idle: 999, presence: .blocked, mic: true) }
    check(occurrences(coveredLog, of: .show(.away)) == [30], "a covered camera is away at 30 s, microphone or not")
}

private func relabelRebooksSegments() {
    let start = workDate
    func at(_ s: Double) -> Date { start.addingTimeInterval(s) }
    var record = SessionRecord(session: session())
    record.add(.focused, seconds: 10, at: at(10))
    record.add(.phone, seconds: 20, at: at(30))
    record.add(.focused, seconds: 10, at: at(40))
    let moved = record.relabel([.phone], from: at(15), to: at(25), as: .focused)
    let expected = [(0.0, 10.0, Bucket.focused), (10, 15, .phone), (15, 25, .focused), (25, 30, .phone), (30, 40, .focused)]
    check(record.segments.map { ($0.start.timeIntervalSince(start), $0.end.timeIntervalSince(start), $0.category) }
            .elementsEqual(expected, by: { $0 == $1 }),
          "relabel splits the phone segment at both edges")
    check(moved == 10, "relabel returns the seconds moved")
    let all = record.relabel([.phone], from: at(0), to: at(40), as: .focused)
    check(record.segments.count == 1 && record.segments[0].category == .focused && record.segments[0].end == at(40),
          "relabel merges the focused neighbours into one segment")
    check(all == 10, "relabel moves only the phone seconds left")
}

private func sleepGapCountsAsAway() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...10) { tick($0) }
    _ = engine.step(tick(1210))
    check(engine.record?.totals()[.away] == 1195, "lid closed for 20 min counts as away")
    check(engine.record?.elapsed == 1211, "the session clock keeps running through sleep")
}

private func endedEarlyHasNoTimeLeft() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = engine.endEarly(date: workDate)
    check(engine.remaining == 0, "an abandoned session has no time left")
}

private func asleepCountsAsAwayWithoutNags() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...100) { tick($0, idle: 999, presence: .none, asleep: true) }
    let effects = log.flatMap(\.actions).filter { $0 != .save }
    check(effects.isEmpty, "sleep raises no overlay or chime")
    check(engine.record?.totals()[.away] == 101, "asleep time counts as away")
}

private func phoneNeedsTwoConsecutiveSamples() {
    let single = Engine()
    _ = single.start(session(), now: 0)
    let spike = run(single, 0...30) { tick($0, idle: 15, phone: $0 == 10 ? 0.9 : 0) }
    check(occurrences(spike, of: phoneShow).isEmpty, "one phone sample is not enough")

    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...30) { tick($0, idle: 15, phone: ($0 == 10 || $0 == 11) ? 0.9 : 0) }
    check(occurrences(log, of: phoneShow) == [11], "two consecutive phone samples raise the check-in")
}

private func headDownCountsAsPhone() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...50) { tick($0, idle: Double($0), pitch: 30) }
    check(occurrences(log, of: phoneShow) == [45], "head down with 45 s of no input raises the check-in")

    let level = Engine()
    _ = level.start(session(), now: 0)
    let flat = run(level, 0...50) { tick($0, idle: Double($0), pitch: 10) }
    check(occurrences(flat, of: phoneShow).isEmpty, "a 10 degree tilt is not head down")
}

private func idleIsSuppressedDuringSettling() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...200) { tick($0, idle: 200) }
    check(occurrences(log, of: .show(.idle)) == [180], "idle check-in waits for 180 s of session")
}

private func offlineRuleFiresAfterSettling() {
    let engine = Engine()
    _ = engine.start(session(mode: .offline), now: 0)
    let log = run(engine, 0...200) { tick($0, idle: 0) }
    check(occurrences(log, of: .show(.offline)) == [180], "offline check-in after settling with activity")

    let idle = Engine()
    _ = idle.start(session(mode: .offline), now: 0)
    let quiet = run(idle, 0...200) { tick($0, idle: 5) }
    check(occurrences(quiet, of: .show(.offline)).isEmpty, "no activity, no offline check-in")
}

private func noSessionNagOnlyInWorkHours() {
    let engine = Engine()
    let log = run(engine, 0...1100) { tick($0, idle: 0) }
    check(occurrences(log, of: .show(.noSession)) == [179, 1079], "nag after 180 active seconds, then every 15 min")

    let evening = Engine()
    let quiet = run(evening, 0...1100) { tick($0, idle: 0, date: eveningDate) }
    check(occurrences(quiet, of: .show(.noSession)).isEmpty, "no nag outside work hours")
}

private func breakIsEarnedTakenAndOverrunIsAway() {
    check(Engine().takeBreak(now: 0).isEmpty, "no break without a session")
    let engine = Engine()
    _ = engine.start(session(90), now: 0)
    _ = run(engine, 0...2999) { tick($0) }
    check(engine.breakAvailable, "50 focused minutes earn a break")
    check(engine.takeBreak(now: 3000) == [.dismiss, .save], "taking the break dismisses and saves")
    var onDuringBreak = true
    let log = run(engine, 3000...3330) { t in
        if t == 3299 { onDuringBreak = engine.wantsCamera }
        return tick(t, idle: t >= 3300 ? 999 : 0, presence: t >= 3300 ? .none : .face)
    }
    check(!onDuringBreak && engine.wantsCamera, "the camera rests during the break and is back once it ends")
    check(engine.record?.totals()[.onBreak] == 300, "break counts 300 s as onBreak")
    check(occurrences(log, of: .sound(.resume)) == [3300], "the break's end sounds")
    check(occurrences(log, of: .show(.away)) == [3330], "overrun past the break is away after 30 s without a face")
}

private func breakEndsEarlyWhenBack() {
    let engine = Engine()
    _ = engine.start(session(90), now: 0)
    _ = run(engine, 0...2999) { tick($0) }
    check(engine.endBreak(now: 3000).isEmpty, "no break to end")
    _ = engine.takeBreak(now: 3000)
    _ = run(engine, 3000...3099) { tick($0, idle: 999, presence: .none) }
    check(engine.endBreak(now: 3100) == [.save], "I'm back ends the break")
    check(engine.breakEndsAt == nil && !engine.breakAvailable, "the rest of the break is forfeited")
    let log = run(engine, 3100...3200) { tick($0) }
    check(engine.record?.totals()[.onBreak] == 100, "only the time taken counts as break")
    check(occurrences(log, of: .sound(.resume)).isEmpty && occurrences(log, of: .show(.away)).isEmpty, "no sound and no away card once back")
}

private func quickPauseEndsWhenTheFaceReturns() {
    check(Engine().pause(now: 0).isEmpty, "no pause without a session")
    let long = Engine()
    _ = long.start(session(90), now: 0)
    check(long.pausesLeft == 2, "two quick pauses from 90 minutes")
    let engine = Engine()
    _ = engine.start(session(50), now: 0)
    check(engine.pausesLeft == 1, "one quick pause below 90 minutes")
    _ = run(engine, 0...599) { tick($0) }
    check(engine.pause(now: 600) == [.save], "the pause starts")
    check(engine.pausing && engine.pausesLeft == 0 && engine.record?.pauses == 1, "the pause is used up")
    // Still at the desk, a 5 s blink of no face, then gone for 40 s and back.
    let log = run(engine, 600...700) { t in
        let gone = (610..<615).contains(t) || (620..<660).contains(t)
        return tick(t, idle: gone ? 999 : 0, presence: gone ? .none : .face)
    }
    check(occurrences(log, of: .sound(.resume)) == [660], "the face back after 20 s without one ends the pause")
    check(!engine.pausing && engine.breakEndsAt == nil, "the pause is over")
    check(engine.record?.totals()[.onBreak] == 60, "the pause counts as break time")
    check(occurrences(log, of: .show(.away)).isEmpty, "no away card during the pause")
    check(engine.pause(now: 800).isEmpty, "no second pause in a 50-minute session")
}

private func bothModeWorksOnPaperAndComputer() {
    let engine = Engine()
    _ = engine.start(session(90, mode: .both), now: 0)
    // Writing on paper (head down 35°, no keyboard/mouse input for 4 minutes) and then typing for 3 minutes: neither raises a check-in.
    let paperAndTyping = run(engine, 0...420) { t in
        tick(t, idle: t < 240 ? Double(t) : 0, pitch: t < 240 ? 35 : 5)
    }
    let cards = paperAndTyping.flatMap(\.actions).filter { if case .show = $0 { true } else { false } }
    check(cards.isEmpty, "both mode allows looking down at paper with no input and typing on the computer without check-ins")
    check(engine.record?.totals()[.focused] == 421, "both paper and computer work count as focused")

    // Visual phone, BLE iPhone, distraction and away still fire in .both mode.
    let phoneLog = run(engine, 421...431) { tick($0, idle: 15, phone: ($0 == 430 || $0 == 431) ? 0.9 : 0) }
    check(occurrences(phoneLog, of: phoneShow) == [431], "a phone seen by the camera still raises a check-in in both mode")
    _ = engine.answer(.drifted, text: "checked my phone", now: 432, date: workDate.addingTimeInterval(432))
    let driftLog = run(engine, 433...500) { tick($0, app: safari, url: youtube) }
    check(occurrences(driftLog, of: distraction) == [492], "distracting sites still raise a check-in in both mode")
    _ = engine.answer(.drifted, text: "closed the tab", now: 493, date: workDate.addingTimeInterval(493))
    let awayLog = run(engine, 494...530) { tick($0, idle: 999, presence: .none) }
    check(occurrences(awayLog, of: .show(.away)) == [523], "walking away still raises the away card after 30 s in both mode")
}

private func breaksPauseTheSessionTimer() {
    let engine = Engine()
    _ = engine.start(session(60), now: 0)
    _ = run(engine, 0...2999) { tick($0) }
    check(engine.record?.elapsed == 3000 && engine.remaining == 600, "50 minutes elapsed, 10 minutes remaining before break")
    check(engine.takeBreak(now: 3000) == [.dismiss, .save], "earned break starts at 3000 s")
    // Run through the full 5-minute break (3000...3299); at t=3300 the break ends and t=3300 is the first focused second after the break.
    let breakLog = run(engine, 3000...3299) { tick($0, idle: 999, presence: .none) }
    check(engine.record?.elapsed == 3000 && engine.remaining == 600, "the session timer stays paused throughout the 5-minute break")
    check(engine.record?.totals()[.onBreak] == 300, "the 5-minute break is still booked on the timeline as onBreak")
    check(occurrences(breakLog, of: .ended(.completed)).isEmpty, "the session does not end early from break time")

    // Take a 2-minute quick pause at 3300...3420; timer must also stay paused.
    _ = engine.step(tick(3300))
    check(engine.record?.elapsed == 3001 && engine.remaining == 599, "timer resumes once the break ends")
    check(engine.pause(now: 3301) == [.save], "quick pause starts")
    _ = run(engine, 3301...3420) { tick($0, idle: 999, presence: .none) }
    check(engine.endBreak(now: 3420) == [.save], "quick pause ended with I'm back")
    check(engine.record?.elapsed == 3001 && engine.remaining == 599, "the session timer stays paused throughout the quick pause")
    check(engine.record?.totals()[.onBreak] == 420, "both the break and the quick pause are booked as onBreak")

    // Sleeping during a break does not advance the session timer for the break portion, only for away time past the break's end.
    let sleepBreak = Engine()
    _ = sleepBreak.start(session(90), now: 0)
    _ = run(sleepBreak, 0...2999) { tick($0) }
    _ = sleepBreak.takeBreak(now: 3000)
    _ = sleepBreak.step(tick(3000))
    // Mac sleeps for 100 s during the 300 s break (still within the break: 3100 < 3300).
    _ = sleepBreak.step(tick(3100))
    check(sleepBreak.record?.elapsed == 3000 && sleepBreak.record?.totals()[.onBreak] == 101,
          "sleeping within a break books onBreak and does not advance the session timer")
    // Now sleep past the break end (from 3100 to 3400; break ends at 3300): 200 s of break + 95 s of away sleep + 5 s dt.
    _ = sleepBreak.step(tick(3400))
    check(sleepBreak.record?.totals()[.onBreak] == 301 && sleepBreak.record?.totals()[.away] == 95 && sleepBreak.record?.elapsed == 3100,
          "sleeping past the end of a break pauses the timer until the break ends, then books the overrun as away")
}

private func quickPauseOverrunIsAway() {
    let engine = Engine()
    _ = engine.start(session(90), now: 0)
    _ = run(engine, 0...20) { tick($0, app: safari, url: youtube) }
    check(engine.pause(now: 21).isEmpty, "no pause while a check-in is up")
    _ = engine.answer(.drifted, text: "three words here", now: 21, date: workDate)
    _ = run(engine, 21...99) { tick($0) }
    _ = engine.pause(now: 100)
    let log = run(engine, 100...430) { tick($0, idle: $0 > 100 ? 999 : 0, presence: $0 > 100 ? .none : .face) }
    check(occurrences(log, of: .sound(.resume)) == [400], "the pause runs out after 5 minutes")
    check(occurrences(log, of: .show(.away)) == [430], "overrun past the pause is away after 30 s without a face")
    check(engine.breakAvailable == false && engine.pausesLeft == 1, "a pause does not touch the earned break")
}

private func checkInsAreCounted() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...5) { tick($0, permissions: false) }
    check(engine.record?.checkIns == 0, "the permissions card is not a check-in")
    // The distraction card comes up 60 s after the permissions card closes (the check-in gap), and stays one check-in however long it lasts.
    _ = run(engine, 6...100) { tick($0, app: safari, url: youtube) }
    check(engine.record?.checkIns == 1, "a distraction card is one check-in, however long it stays up")
    _ = engine.answer(.back, text: "checking the docs", now: 101, date: workDate)
    _ = run(engine, 101...200) { tick($0, idle: $0 > 120 ? 999 : 0, presence: $0 > 120 ? .none : .face) }
    check(engine.record?.checkIns == 2, "an away card is another")
}

private func answerValidation() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...20) { tick($0, app: safari, url: youtube) }
    check(engine.answer(.drifted, text: "two words", now: 21, date: workDate).isEmpty, "two words are rejected")
    check(engine.overlay == .distraction("youtube.com"), "rejected answer keeps the overlay")
    check(engine.answer(.drifted, text: "three words here", now: 21, date: workDate) == [.dismiss, .save], "valid answer dismisses")
    check(engine.record?.entries.count == 1, "valid answer is logged in the session")
    check(engine.record?.entries.first?.answer == "drifted", "logged answer keeps its kind")
}

private func completionThenReflect() {
    let engine = Engine()
    _ = engine.start(session(1), now: 0)
    let log = run(engine, 0...59) { tick($0) }
    check(actions(log, at: 59) == [.dismiss, .ended(.completed), .save], "session completes at 60 s")
    check(engine.record?.outcome == .completed && engine.category == nil, "completed record waits for reflection")
    check(engine.reflect("went well") == [.save], "reflection saves")
    check(engine.record == nil, "reflection closes the record")
}

private func endEarlyAbandons() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    _ = run(engine, 0...10) { tick($0) }
    check(engine.endEarly(date: workDate) == [.dismiss, .ended(.abandoned), .save], "ending early abandons")
    check(engine.record?.outcome == .abandoned, "abandoned outcome is kept until reflection")

    let counted = Engine()
    _ = counted.start(session(), now: 0)
    _ = run(counted, 0...10) { tick($0) }
    counted.confirmEnd(now: 10)
    var log = run(counted, 11...20) { tick($0) }
    check(occurrences(log, of: .ended(.abandoned)) == [20] && counted.endsAt == nil, "the phrase typed at 10 s ends the session at 20 s, on a tick")
    let kept = Engine()
    _ = kept.start(session(), now: 0)
    kept.confirmEnd(now: 0)
    kept.keepGoing()
    log = run(kept, 0...30) { tick($0) }
    check(occurrences(log, of: .ended(.abandoned)).isEmpty && kept.record?.outcome == .running, "keep going cancels the countdown")
}

private func resumeBooksGapAsUntracked() {
    var stored = SessionRecord(session: session())
    stored.elapsed = 100
    let engine = Engine()
    check(engine.resume(stored, now: 500, date: workDate.addingTimeInterval(60)) == [.save], "resume saves")
    check(engine.record?.totals()[.untracked] == 60, "gap is booked as untracked")
    check(engine.record?.elapsed == 160, "gap counts toward the timer")

    let brief = Engine()
    _ = brief.resume(stored, now: 500, date: workDate.addingTimeInterval(3))
    check(brief.record?.totals()[.untracked] == nil, "gaps of 5 s or less are not booked")
}

private func permissionsRepeatAndClear() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...80) { tick($0, permissions: !(5...69).contains($0)) }
    check(occurrences(log, of: .show(.permissions)) == [5, 65], "permissions prompt repeats every 60 s")
    check(occurrences(log, of: .alarm(true)).isEmpty, "the permissions card never alarms")
    check(occurrences(log, of: .dismiss) == [70], "permissions prompt clears once granted")
    check(engine.record?.totals()[.untracked] == 65, "time without permissions is untracked")
}

private func iPhoneInUseCountsAsPhone() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let log = run(engine, 0...55) { tick($0, idle: Double($0), iPhone: $0 >= 5) }
    check(occurrences(log, of: phoneShow) == [20], "iPhone in use for 15 s with no Mac input raises the check-in, camera or not")
    check(occurrences(log, of: .alarm(true)) == [50], "unanswered check-in alarms after 30 s")
    check(engine.answer(.back, text: "checking a 2FA code", now: 56, date: workDate) == [.alarm(false), .dismiss, .save], "answering silences the alarm")
    check((engine.record?.totals()[.phone] ?? 0) >= 20, "iPhone use is booked as phone time")

    let typing = Engine()
    _ = typing.start(session(), now: 0)
    let busy = run(typing, 0...60) { tick($0, idle: 0, iPhone: true) }
    check(occurrences(busy, of: phoneShow).isEmpty, "typing on the Mac while the iPhone is unlocked is not a phone check-in")

    let glance = Engine()
    _ = glance.start(session(), now: 0)
    let brief = run(glance, 0...40) { tick($0, idle: Double($0), iPhone: (5...15).contains($0)) }
    check(occurrences(brief, of: phoneShow).isEmpty, "a 10 s glance at the iPhone is not enough")
}

private func permissionsSilentWithoutSession() {
    let engine = Engine()
    let log = run(engine, 0...130) { tick($0, permissions: false, date: eveningDate) }
    check(log.isEmpty, "missing permissions never alarm outside a session")
}

private func checkInThrottle() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let first = run(engine, 0...45) { tick($0, idle: Double($0), pitch: 30) }
    check(occurrences(first, of: phoneShow) == [45], "first head-down check-in at 45 s")
    _ = engine.answer(.drifted, text: "three words here", now: 46, date: workDate)
    let second = run(engine, 46...120) { tick($0, idle: Double($0), pitch: 30) }
    check(occurrences(second, of: phoneShow) == [106], "no check-in within 60 s of the last dismissal")
}

private func youtubeCSSOncePerURL() {
    let engine = Engine()
    _ = engine.start(session(), now: 0)
    let urls = [youtube, youtube, "https://www.youtube.com/watch?v=1"]
    let log = run(engine, 0...2) { tick($0, app: safari, url: urls[$0]) }
    check(occurrences(log, of: .injectCSS(safari)) == [0, 2], "hide-CSS injected once per distinct URL")
}

private func wrapUpNotifiesOnceFiveMinutesOut() {
    let engine = Engine()
    _ = engine.start(session(10), now: 0)
    let log = run(engine, 0...400) { tick($0) }
    check(occurrences(log, of: .notify("5 minutes left on write the spec")) == [299], "wrap-up notification fires once when 300 s remain")
}

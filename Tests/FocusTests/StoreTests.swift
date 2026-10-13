import Foundation
import FocusCore

func storeTests() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(root: root)
    // Whole seconds only: the .iso8601 date strategy drops fractions.
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    check(store.loadSettings() == Settings(), "defaults when settings missing")
    var settings = Settings()
    settings.apps = ["com.apple.Notes"]
    settings.workStart = 8 * 60
    store.save(settings)
    check(store.loadSettings() == settings, "settings round-trip")
    // Written before the iPhone fields existed: still loads, keeping the user's values.
    try? Data(#"{"workDays":[2],"workStart":480,"workEnd":1080,"domains":["a.com"],"apps":[]}"#.utf8).write(to: root.appendingPathComponent("settings.json"))
    check(store.loadSettings().domains == ["a.com"] && store.loadSettings().iPhone == nil && store.loadSettings().developerMode == nil,
          "older settings still load")

    var done = SessionRecord(session: Session(task: "Write", minutes: 25, started: t0))
    done.add(.focused, seconds: 60, at: t0.addingTimeInterval(60))
    done.add(.drifting, target: "reddit.com", seconds: 30, at: t0.addingTimeInterval(90))
    done.outcome = .completed
    let running = SessionRecord(session: Session(task: "Later", minutes: 50, started: t0.addingTimeInterval(3600)))
    store.save(done)
    store.save(running)
    check(store.records(since: t0) == [done, running], "records sorted by start")
    check(store.records(since: t0.addingTimeInterval(1800)) == [running], "records since filters")
    check(store.active() == running, "active is the running record")

    try? "not json".write(to: root.appendingPathComponent("sessions/corrupt.json"), atomically: true, encoding: .utf8)
    check(store.records(since: .distantPast).count == 2, "corrupt session skipped")

    let first = Entry(at: t0, reason: "noSession", answer: "drifted", text: "Reading news")
    let second = Entry(at: t0.addingTimeInterval(120), reason: "distraction", answer: "back", text: "Checking the docs")
    store.append(first)
    store.append(second)
    check(store.journal(since: .distantPast) == [first, second], "journal append and read")
    check(store.journal(since: t0.addingTimeInterval(60)) == [second], "journal since filters")

    // Developer mode: a false alarm with its images, in a folder of its own named after its time and reason.
    let tick = Tick(now: 12.5, date: t0, app: "com.apple.Safari", url: "https://example.com", idle: 3,
                    camera: CameraReading(at: 12, presence: .face, pitchDown: 20, phone: 0.7), phoneInUse: true)
    let alarm = FalseAlarm(at: t0, reason: "phone", text: "Reading my notes on paper", task: "Write", mode: .computer, face: [0.4, 0.2, 0.2, 0.3],
                           phone: [0.1, 0.6, 0.2, 0.2], phoneScore: 0.7, iPhoneInUse: false, ticks: [tick], settings: settings)
    store.save(alarm, files: ["camera.jpg": Data([0xFF, 0xD8])])
    let saved = (try? FileManager.default.contentsOfDirectory(at: store.falseAlarmsURL, includingPropertiesForKeys: nil)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let read = saved.first.flatMap { try? Data(contentsOf: $0.appendingPathComponent("alarm.json")) }.flatMap { try? decoder.decode(FalseAlarm.self, from: $0) }
    check(saved.count == 1 && saved[0].lastPathComponent.hasSuffix("-phone") && read == alarm, "false alarm saved and read back")
    check(saved.first.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("camera.jpg").path) } == true, "false alarm keeps its image")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func day(_ d: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour, minute: minute))!
    }
    // Starts at 23:50 on the 11th and runs past midnight: counts toward the 11th.
    var late = SessionRecord(session: Session(task: "late", minutes: 25, started: day(11, 23, 50)))
    late.add(.focused, seconds: 1200, at: day(12, 0, 10))
    late.add(.drifting, target: "reddit.com", seconds: 300, at: day(12, 10, 5))
    var old = SessionRecord(session: Session(task: "old", minutes: 25, started: day(1, 9)))
    old.add(.focused, seconds: 600, at: day(1, 9, 10))
    old.add(.drifting, target: "x.com", seconds: 900, at: day(1, 9, 30))
    let all = [late, old]

    let rows = Stats.byDay(all, days: 3, today: day(12, 15), calendar: calendar)
    check(rows.map(\.day) == [day(10), day(11), day(12)], "byDay returns days oldest first")
    check(rows[0].totals.isEmpty, "byDay empty day")
    check(rows[1].totals[.focused] == 1200, "segment counted on its start day")
    check(rows[2].totals[.drifting] == 300, "byDay today drifting")
    check(Stats.totals(all)[.focused] == 1800, "totals sum across records")
    check(Stats.totals(all)[.drifting] == 1200, "totals drifting")
    let top = Stats.topTargets(all, limit: 1)
    check(top.count == 1 && top[0].target == "x.com" && top[0].seconds == 900, "topTargets sorted and limited")
    check(Stats.topTargets(all, limit: 5).map(\.target) == ["x.com", "reddit.com"], "topTargets order")
}

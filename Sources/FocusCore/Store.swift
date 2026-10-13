import Foundation

/// JSON files under ~/Library/Application Support/Focus.
public struct Store: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Focus")) { self.root = root }

    public func loadSettings() -> Settings { read(Settings.self, root.appendingPathComponent("settings.json")) ?? Settings() }

    public func save(_ settings: Settings) { write(settings, to: root.appendingPathComponent("settings.json")) }

    public func save(_ record: SessionRecord) {
        let s = record.session
        write(record, to: sessionsURL.appendingPathComponent("\(dayString(s.started))-\(s.id.uuidString).json"))
    }

    public func records(since: Date) -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { read(SessionRecord.self, $0) }
            .filter { $0.session.started >= since }
            .sorted { $0.session.started < $1.session.started }
    }

    /// The latest record whose outcome is still `.running`.
    public func active() -> SessionRecord? {
        records(since: .distantPast).last { $0.outcome == .running }
    }

    /// Answers given outside a session (no-session nags).
    public func append(_ entry: Entry) {
        guard var line = encode(entry) else { return }
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: journalURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: journalURL)
            }
        } catch { log(journalURL, error) }
    }

    public func journal(since: Date) -> [Entry] {
        guard let text = try? String(contentsOf: journalURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .compactMap { decode(Entry.self, Data($0.utf8)) }
            .filter { $0.at >= since }
    }

    private var sessionsURL: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    private var journalURL: URL { root.appendingPathComponent("journal.jsonl") }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { decode(type, $0) }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = encode(value) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { log(url, error) }
    }

    /// A failed write loses data, so it goes to the unified log (`log show --predicate 'process == "Focus"'`).
    private func log(_ url: URL, _ error: Error) { NSLog("Focus: could not write %@: %@", url.path, error.localizedDescription) }

    private func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

/// Totals and rollups over session records, for the stats window.
public enum Stats {
    public static func totals(_ records: [SessionRecord]) -> [Bucket: Double] {
        records.reduce(into: [:]) { $0.merge($1.totals(), uniquingKeysWith: +) }
    }

    /// Per-day totals for the last `days` days ending today, oldest first. Each segment counts toward the day it starts on.
    public static func byDay(_ records: [SessionRecord], days: Int, today: Date, calendar: Calendar = .current) -> [(day: Date, totals: [Bucket: Double])] {
        let last = calendar.startOfDay(for: today)
        let starts = (0..<max(days, 0)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: last) }
        var sums = Dictionary(uniqueKeysWithValues: starts.map { ($0, [Bucket: Double]()) })
        for segment in records.flatMap(\.segments) {
            let day = calendar.startOfDay(for: segment.start)
            sums[day]?[segment.category, default: 0] += segment.end.timeIntervalSince(segment.start)
        }
        return starts.map { (day: $0, totals: sums[$0] ?? [:]) }
    }

    public static func topTargets(_ records: [SessionRecord], limit: Int) -> [(target: String, seconds: Double)] {
        var sums: [String: Double] = [:]
        for segment in records.flatMap(\.segments) where segment.category == .drifting {
            if let target = segment.target { sums[target, default: 0] += segment.end.timeIntervalSince(segment.start) }
        }
        return sums.map { (target: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.target < $1.target }
            .prefix(limit).map { $0 }
    }
}

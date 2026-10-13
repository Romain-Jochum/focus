import Charts
import FocusCore
import SwiftUI

/// Today's totals, the last 7 days, each session's timeline, top distractions and every typed answer.
struct StatsView: View {
    @Environment(AppModel.self) private var model

    private struct DayTotal: Identifiable {
        let id = UUID()
        let day: Date
        let bucket: Bucket
        let minutes: Double
    }

    var body: some View {
        Form {
            Section("Today") {
                ForEach(Bucket.allCases, id: \.self) { bucket in
                    LabeledContent(bucket.badge.text) { Text(today[bucket, default: 0].minutesText).monospacedDigit() }
                }
            }
            Section("Last 7 days") {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", day.minutes)).foregroundStyle(by: .value("Bucket", day.bucket.badge.text))
                }
                .chartForegroundStyleScale(domain: Bucket.allCases.map { $0.badge.text }, range: Bucket.allCases.map { $0.badge.tint })
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) } }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
            }
            Section("Sessions") {
                ForEach(model.records.sorted { $0.session.started > $1.session.started }, id: \.session.id) { TimelineRow(record: $0) }
            }
            Section("Top distractions") {
                if distractions.isEmpty { Text("No distractions recorded.").foregroundStyle(.secondary) }
                ForEach(distractions, id: \.target) { item in LabeledContent(item.target) { Text(item.seconds.minutesText).monospacedDigit() } }
            }
            Section("Journal") {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.at.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(reasonLabel(entry.reason)) · \(answerLabel(entry))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(entry.text).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 760)
    }

    private var today: [Bucket: Double] { Stats.byDay(model.records, days: 1, today: .now).first?.totals ?? [:] }

    private var days: [DayTotal] {
        Stats.byDay(model.records, days: 7, today: .now).flatMap { row in
            Bucket.allCases.map { DayTotal(day: row.day, bucket: $0, minutes: row.totals[$0, default: 0] / 60) }
        }
    }

    private var distractions: [(target: String, seconds: Double)] { Stats.topTargets(model.records, limit: 5) }

    private var entries: [Entry] { (model.records.flatMap(\.entries) + model.journal).sorted { $0.at > $1.at } }

    /// "back" is the Away card's "I was away", the no-session card's answer, and "Back to it" in older records.
    private func answerLabel(_ entry: Entry) -> String {
        if entry.answer == "back", entry.reason == "away" { return "I was away" }
        if entry.answer == "back", entry.reason == "noSession" { return "Answered" }
        return ["back": "Back to it", "takeBreak": "Break", "drifted": "Drifted", "notDrifting": "False alarm"][entry.answer, default: entry.answer]
    }

    /// The engine stores `String(describing: reason)`, so `distraction("youtube.com")` arrives raw.
    private func reasonLabel(_ raw: String) -> String {
        if raw.hasPrefix("distraction(") { return "Distraction" }
        return ["phone": "Phone", "idle": "Idle", "offline": "Offline", "away": "Away", "noSession": "No session", "permissions": "Permissions"][raw, default: raw]
    }
}

/// One session: its start, task and total, and a strip of its segments coloured by category.
private struct TimelineRow: View {
    let record: SessionRecord

    var body: some View {
        let total = max(record.segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.session.started.formatted(.dateTime.weekday(.abbreviated).hour().minute())).monospacedDigit()
                Text(record.session.task).lineLimit(1)
                Spacer()
                Text(record.totals().values.reduce(0, +).minutesText).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(record.segments, id: \.start) { segment in
                        segment.category.badge.tint.frame(width: geometry.size.width * segment.end.timeIntervalSince(segment.start) / total)
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
        }
    }
}

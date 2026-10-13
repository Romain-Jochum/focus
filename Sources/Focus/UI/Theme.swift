import FocusCore
import SwiftUI

/// A symbol and a label; the symbol carries the tint, the text stays primary.
struct Badge: View {
    let text: String, symbol: String
    var tint: Color = .secondary
    var body: some View { Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) } }
}

extension Bucket {
    var badge: Badge {
        switch self {
        case .focused: Badge(text: "Focused", symbol: "checkmark.circle.fill", tint: .green)
        case .drifting: Badge(text: "Drifting", symbol: "arrow.turn.up.right", tint: .orange)
        case .away: Badge(text: "Away", symbol: "figure.walk", tint: .red)
        case .phone: Badge(text: "Phone", symbol: "iphone", tint: .purple)
        case .onBreak: Badge(text: "Break", symbol: "cup.and.saucer.fill", tint: .teal)
        case .untracked: Badge(text: "Untracked", symbol: "questionmark.circle", tint: .gray)
        }
    }
}

extension Award {
    var title: String {
        switch verdict {
        case .perfect: "Perfect session"
        case .good: "Session complete"
        case .drifted: "Session complete, with drift"
        case .abandoned: "Ended early"
        }
    }

    /// "+62 XP · early +25% · 4-day streak +15% · ×1.3".
    var detail: String {
        switch verdict {
        case .perfect: ([xpText] + bonuses).joined(separator: " · ")
        case .good: "No XP, streak kept"
        case .drifted, .abandoned: xp == 0 ? "No XP lost" : xpText
        }
    }

    var xpText: String { xp > 0 ? "+\(xp) XP" : xp < 0 ? "−\(-xp) XP" : "0 XP" }

    var bonuses: [String] {
        [early ? "early +25%" : nil, late ? "late +25%" : nil,
         streakBonus > 0 ? "\(streak)-day streak +\(Int((streakBonus * 100).rounded()))%" : nil,
         multiplier > 1 ? "×\(multiplier.formatted(.number.precision(.fractionLength(1))))" : nil].compactMap { $0 }
    }

    var badge: Badge {
        switch verdict {
        case .perfect: Badge(text: title, symbol: "star.circle.fill", tint: .yellow)
        case .good: Badge(text: title, symbol: "checkmark.circle.fill", tint: .green)
        case .drifted: Badge(text: title, symbol: "arrow.turn.up.right", tint: .orange)
        case .abandoned: Badge(text: title, symbol: "xmark.circle", tint: .orange)
        }
    }
}

extension AppModel {
    var isRunning: Bool { session != nil && remaining > 0 }
    /// The session's time is up and the reflection is due.
    var isEnded: Bool { session != nil && remaining <= 0 }
    /// The bucket now; nil before the first sample.
    var stateBucket: Bucket? { breakRemaining == nil ? category : .onBreak }
}

extension Double {
    /// "1 hr 5 min", "12 min".
    var minutesText: String { Duration.seconds(self).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)) }
    /// "24:03".
    var clockText: String { Duration.seconds(self).formatted(.time(pattern: .minuteSecond)) }
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespaces) } }

/// Shared metrics, so every view sits on the same grid.
enum Metrics {
    static let gutter: CGFloat = 16   // popover and window inset, and gaps between popover sections
    static let card: CGFloat = 20     // check-in card inset
    static let group: CGFloat = 12    // between the fields of a group
    static let row: CGFloat = 8       // between controls in a row
    static let label: CGFloat = 4     // a caption to its field
    static let control: CGFloat = 6   // corner radius of controls
    static let box: CGFloat = 10      // corner radius of boxes
}

/// A selectable chip: accent when on, quaternary when off.
struct Chip: View {
    let text: String, on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(text).monospacedDigit().frame(maxWidth: .infinity).padding(.vertical, 5) }
            .buttonStyle(.plain)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: Metrics.control))
    }
}

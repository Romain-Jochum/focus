import AppKit
import CoreGraphics
import FocusCore
import SwiftUI

/// The menu-bar popover, and the left side of the Focus window: the start form or the running or ended session, the setup checklist, and the footer.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// The Focus window shows the level in its garden panel instead.
    var showsLevel = true

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            if let session = model.session, model.isRunning { RunningView(session: session) }
            else if let session = model.session, model.isEnded { EndedView(session: session) }
            else { StartForm() }
            if model.setup.contains(where: { !$0.ok }) { SetupChecklist() }
            if showsLevel { LevelLine() }
            Divider()
            HStack(spacing: Metrics.gutter) {
                Button("Stats…") { openWindow(id: "stats"); NSApp.activate() }
                Button("Settings…") { openWindow(id: "settings"); NSApp.activate() }
                Spacer()
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).font(.callout)
        }
        .padding(Metrics.gutter)
        .frame(width: 300)
    }
}

/// The idle state and the no-session card: task, plan, mode and duration, then Start.
struct StartForm: View {
    @Environment(AppModel.self) private var model
    @State private var task = ""
    @State private var plan = ""
    @State private var mode = Mode.computer
    @State private var minutes = 50

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.group) {
            field("Task", "One sentence", $task)
            field("If I drift, I will…", "Optional", $plan)
            HStack(spacing: Metrics.row) {
                Chip(text: "On computer", on: mode == .computer) { mode = .computer }
                Chip(text: "Offline", on: mode == .offline) { mode = .offline }
            }
            Text("Duration").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Metrics.row) {
                ForEach([25, 50, 90], id: \.self) { preset in Chip(text: "\(preset)", on: minutes == preset) { minutes = preset } }
                Stepper(value: $minutes, in: 5...240, step: 5) { Text("\(minutes) min").monospacedDigit() }.fixedSize()
            }
            Button("Start") { model.start(task: task.trimmed, plan: plan.trimmed, mode: mode, minutes: minutes) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(task.trimmed.isEmpty).frame(maxWidth: .infinity)
        }
    }

    private func field(_ title: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Metrics.label) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(prompt, text: text).textFieldStyle(.roundedBorder) }
    }
}

/// A running session: task, countdown, state, Break, and End early behind a typed phrase and a 10 s countdown.
struct RunningView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var typing = false
    @State private var phrase = ""

    private static let confirmation = "I am ending this session early"
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.group) {
            Text(session.task).font(.headline).lineLimit(2)
            Text(model.remaining.clockText).font(.system(size: 40, weight: .light)).monospacedDigit()
            HStack {
                if model.pausing { Badge(text: "Paused", symbol: "pause.circle.fill", tint: .teal) }
                else { model.stateBucket?.badge ?? Badge(text: "Starting", symbol: "circle.dotted") }
                Spacer()
                if let app = model.frontmost { Text(app).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            breakControls
            endFlow
        }
    }

    /// On a break or pause: its time left and I'm back. Otherwise: Break (when earned) and Quick pause.
    @ViewBuilder private var breakControls: some View {
        if let left = model.breakRemaining {
            HStack {
                Text("\(left.clockText) left").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("I'm back") { model.endBreak() }.buttonStyle(.borderedProminent)
            }
        } else {
            HStack(spacing: Metrics.row) {
                Button { model.takeBreak() } label: { Text("Break").frame(maxWidth: .infinity) }
                    .disabled(!model.breakAvailable).help("5 minutes, earned after every 50 focused minutes")
                Button { model.pause() } label: { Text("Quick pause").frame(maxWidth: .infinity) }
                    .disabled(model.pausesLeft == 0 || model.overlay != nil)
                    .help("Up to 5 minutes away, for a short trip. It ends when you're back. \(model.pausesLeft) left in this session")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var endFlow: some View {
        if let left = model.endingIn {
            HStack {
                Text("Ending in \(Int(left.rounded(.up))) s").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Keep going") { model.keepGoing(); reset() }
            }
        } else if typing {
            VStack(alignment: .leading, spacing: Metrics.row) {
                Text("Type “\(Self.confirmation)” to end it.").font(.callout).foregroundStyle(.secondary)
                TextField("", text: $phrase).textFieldStyle(.roundedBorder).accessibilityLabel("Type the confirmation phrase")
                HStack {
                    Button("Cancel") { reset() }
                    Spacer()
                    Button("End session") { model.confirmEnd() }.disabled(phrase.trimmed != Self.confirmation)
                }
            }
        } else {
            Button("End early") { typing = true }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    private func reset() { (typing, phrase) = (false, "") }
}

/// The session's time is up: the one-line reflection, stored with the session.
struct EndedView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var reflection = ""

    var body: some View {
        let early = model.records.first { $0.session.id == session.id }?.outcome == .abandoned
        VStack(alignment: .leading, spacing: Metrics.group) {
            Text(session.task).font(.headline).lineLimit(2)
            if let award = model.award, award.id == session.id {
                VStack(alignment: .leading, spacing: Metrics.label) {
                    award.badge
                    Text(award.detail).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Badge(text: early ? "Ended early" : "Session complete", symbol: early ? "xmark.circle" : "checkmark.circle.fill", tint: early ? .orange : .green)
            }
            VStack(alignment: .leading, spacing: Metrics.label) {
                Text("How did it go?").font(.caption).foregroundStyle(.secondary)
                TextField("One line", text: $reflection).textFieldStyle(.roundedBorder)
            }
            HStack { Spacer(); Button("Save") { model.reflect(reflection.trimmed) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(reflection.trimmed.isEmpty) }
        }
    }
}

/// The garden in one line: level and phase, the streak, and the way to the next level.
struct LevelLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let game = model.game
        VStack(alignment: .leading, spacing: Metrics.label) {
            HStack {
                Label("Level \(game.level) · \(Progression.phase(game.level))", systemImage: "leaf.fill").labelStyle(TintedIcon(tint: .green))
                Spacer()
                if game.streak > 0 { Text("\(game.streak)-day streak").foregroundStyle(.secondary) }
            }
            .font(.callout)
            Meter(value: game.levelFraction)
                .help(game.level < Progression.maxLevel ? "\(game.toNextLevel) XP to level \(game.level + 1)" : "The garden is restored")
        }
    }
}

/// A thin green bar, drawn rather than a ProgressView so it keeps its colour in inactive windows.
struct Meter: View {
    let value: Double
    var body: some View {
        Capsule().fill(.quaternary).frame(height: 5)
            .overlay(alignment: .leading) { GeometryReader { Capsule().fill(.green).frame(width: max(5, $0.size.width * min(max(value, 0), 1))) } }
    }
}

/// A label whose icon alone is tinted.
struct TintedIcon: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Metrics.label + 2) { configuration.icon.foregroundStyle(tint); configuration.title }
    }
}

/// Until every permission is granted: each item with its state and, when missing, how to fix it.
struct SetupChecklist: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.row) {
            Text("Setup").font(.headline)
            ForEach(model.setup) { item in
                if item.ok {
                    row(item.name, "checkmark.circle.fill", .green)
                } else {
                    Button { model.fix(item) } label: { row(item.name, "exclamationmark.circle", .orange, hint: item.hint) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(Metrics.group).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Metrics.box))
    }

    /// The icon sits in a fixed column, so the name and its hint share one leading edge.
    private func row(_ name: String, _ symbol: String, _ tint: Color, hint: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Metrics.label + 2) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let hint { Text(hint).font(.caption).foregroundStyle(.tint) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

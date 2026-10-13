import FocusCore
import SwiftUI

/// The Focus window: the session controls on the left, the garden on the right (the garden alone in `--garden-preview`).
struct MainView: View {
    /// False in snapshots (see `GardenPanel.live`).
    var live = true
    var card: GardenModel.Reveal?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !AppModel.gardenPreview {
                PopoverView(showsLevel: false)
                Divider()
            }
            GardenPanel(live: live, card: card)
        }
        .fixedSize()
    }
}

/// The level, XP, streak and today's multiplier above the island, and the reward card after a session (docs/design.md, Garden › Window).
struct GardenPanel: View {
    @Environment(AppModel.self) private var model
    /// False in snapshots, which cannot draw Core Animation layers: the picture as a plain image.
    var live = true
    @State private var card: GardenModel.Reveal?

    init(live: Bool = true, card: GardenModel.Reveal? = nil) {
        self.live = live
        _card = State(initialValue: card)
    }

    var body: some View {
        let game = model.game
        VStack(alignment: .leading, spacing: Metrics.group) {
            VStack(alignment: .leading, spacing: Metrics.label + 2) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Level \(game.level) · \(Progression.phase(game.level))", systemImage: "leaf.fill").labelStyle(TintedIcon(tint: .green))
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(Int(game.xp).formatted()) XP").monospacedDigit().foregroundStyle(.secondary)
                }
                Meter(value: game.levelFraction)
                HStack(spacing: Metrics.group) {
                    Text(game.level < Progression.maxLevel ? "\(game.toNextLevel.formatted()) XP to level \(game.level + 1)" : "The garden is restored")
                        .monospacedDigit()
                    Spacer()
                    if game.streak > 0 { Label("\(game.streak)-day streak", systemImage: "flame.fill").labelStyle(TintedIcon(tint: .orange)) }
                    if game.freezes > 0 {
                        Label(game.freezes == 1 ? "1 freeze" : "\(game.freezes) freezes", systemImage: "snowflake").labelStyle(TintedIcon(tint: .cyan))
                            .help("A freeze covers a missed work day. One is earned every 5 kept days, 2 at most.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                Text(multiplier(game)).font(.caption).foregroundStyle(.secondary)
            }
            island
            if AppModel.gardenPreview { LevelSlider() }
        }
        .padding(Metrics.gutter)
    }

    private var island: some View {
        let garden = model.garden
        return ZStack(alignment: .top) {
            if live {
                GardenStage(image: garden.image, reveal: garden.reveal, life: garden.life, still: model.isRunning) { reveal in
                    garden.reveal = nil
                    show(reveal)
                }
            } else if let image = garden.image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
            }
            if let card { RewardCard(reveal: card, animated: live).padding(Metrics.group).transition(.opacity) }
        }
        .frame(width: 520, height: 400)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Metrics.box))
    }

    /// The card shows for 6 s with the reveal.
    private func show(_ reveal: GardenModel.Reveal) {
        guard reveal.award != nil || reveal.level != nil else { return }
        withAnimation(.easeOut(duration: 0.3)) { card = reveal }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if card?.id == reveal.id { withAnimation(.easeIn(duration: 0.6)) { card = nil } }
        }
    }

    private func multiplier(_ game: GameState) -> String {
        let boost = 1 + Progression.boostStep
        if let next = game.nextMultiplier {
            return "Multiplier on: ×\(next.formatted(.number.precision(.fractionLength(1)))) for today's next perfect session of \(Progression.boostMinMinutes) min or more"
        }
        let unlock = "\(Progression.boostAfterSessions) perfect sessions and \(Double(Progression.boostAfterMinutes * 60).minutesText) today unlock ×\(boost.formatted())"
        guard game.todayPerfect > 0 else { return unlock }
        return "\(unlock): \(game.todayPerfect) of \(Progression.boostAfterSessions), \(Double(game.todayMinutes * 60).minutesText) so far"
    }
}

/// `--garden-preview` only: letting go of the slider, or a click on the stepper, shows the garden at the start of that level as it would
/// appear after a session (AppModel.preview).
private struct LevelSlider: View {
    @Environment(AppModel.self) private var model
    @State private var level = 1.0

    var body: some View {
        let target = Int(level.rounded())
        let steps = Garden.shared.stepCount(Progression.growth(Progression.xp(forLevel: target)))
        VStack(alignment: .leading, spacing: Metrics.label) {
            HStack(spacing: Metrics.group) {
                Slider(value: $level, in: 1...Double(Progression.maxLevel)) { editing in
                    if !editing { go(to: Int(level.rounded())) }
                }
                Stepper {
                    Text("Level \(target)").monospacedDigit().frame(minWidth: 64, alignment: .leading)
                } onIncrement: { go(to: target + 1) } onDecrement: { go(to: target - 1) }
            }
            Text("Preview, nothing is saved · \(steps) of \(Garden.shared.steps.count) growth steps · \(Int(Progression.xp(forLevel: target)).formatted()) XP")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .onAppear { level = Double(model.game.level) }
    }

    private func go(to target: Int) {
        let target = min(max(target, 1), Progression.maxLevel)
        level = Double(target)
        model.preview(level: target)
    }
}

/// The verdict, the XP counting up and the bonuses; on a level-up, the new level's name first.
struct RewardCard: View {
    let reveal: GardenModel.Reveal
    @State private var shown: Double

    init(reveal: GardenModel.Reveal, animated: Bool = true) {
        self.reveal = reveal
        _shown = State(initialValue: animated ? 0 : Double(reveal.award?.xp ?? 0))
    }

    var body: some View {
        VStack(spacing: Metrics.label) {
            if let level = reveal.level {
                Label("Level \(level) · \(Progression.phase(level))", systemImage: "leaf.fill").labelStyle(TintedIcon(tint: .green)).font(.title3.weight(.semibold))
            }
            if let award = reveal.award {
                award.badge.font(.headline)
                if award.xp != 0 { CountUp(value: shown).font(.title2.weight(.semibold)) }
                let note = award.xp != 0 ? award.bonuses.joined(separator: " · ") : award.detail
                if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, Metrics.gutter).padding(.vertical, Metrics.group)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.box))
        .onAppear { withAnimation(.easeOut(duration: StageView.revealSeconds)) { shown = Double(reveal.award?.xp ?? 0) } }
    }
}

/// "+69 XP", counting through every value as it animates.
struct CountUp: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let xp = Int(value.rounded())
        Text(xp > 0 ? "+\(xp) XP" : xp < 0 ? "−\(-xp) XP" : "0 XP").monospacedDigit()
    }
}

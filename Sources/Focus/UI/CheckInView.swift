import FocusCore
import SwiftUI

/// The check-in card: a quiet dialog over the dimmed screen. The no-session card also starts a session.
struct CheckInView: View {
    @Environment(AppModel.self) private var model
    let reason: Reason
    @State private var text = ""
    @State private var rejected = false
    /// Copy variant, drawn per check-in so the card stays noticeable without repeating itself.
    @State private var variant = Int.random(in: 0..<3)
    @State private var caught = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            VStack(alignment: .leading, spacing: 6) {
                copy.badge.font(.callout)
                Text(copy.titles[variant % copy.titles.count]).font(.headline)
                Text(copy.detail).font(.callout).foregroundStyle(.secondary)
                if let plan = model.session?.plan, !plan.isEmpty { Text("If I drift, I will \(plan)").font(.callout).foregroundStyle(.secondary) }
            }
            if model.evidence != nil || model.screen != nil { evidenceRow }
            switch reason {
            case .away:
                answerField
                HStack(spacing: 8) {
                    Button("I was here") { submit(.notDrifting) }
                    Spacer()
                    Button("I was away") { submit(.back) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            case .permissions:
                // The overlay covers System Settings: step aside; the engine shows it again in 60 s if still missing.
                if let missing = model.setup.first(where: { !$0.ok }) {
                    HStack {
                        Spacer()
                        Button("Open System Settings") { model.fix(missing); OverlayController.shared.hide() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
            case .noSession:
                StartForm()
                Divider()
                answerField
                HStack { Spacer(); Button("Save") { submit(.back) } }
            default:
                answerField
                HStack(spacing: 8) {
                    Button("I wasn't drifting") { submit(.notDrifting) }
                    Spacer()
                    if model.breakAvailable { Button("Take my break") { submit(.takeBreak) } }
                    Button("I drifted — back to it") { submit(.drifted) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Metrics.card)
        .frame(width: 448, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: Metrics.box).fill(.background).shadow(color: .black.opacity(0.25), radius: 20, y: 6) }
    }

    /// What the app saw: the camera frame with its boxes, and the screen for screen reasons.
    private var evidenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            let pair = model.evidence != nil && model.screen != nil   // two images share the row; one keeps its aspect
            HStack(spacing: Metrics.row) {
                if let e = model.evidence { EvidenceImage(image: e.image, face: e.face, phone: e.phone, phoneScore: e.phoneScore, pair: pair) }
                if let s = model.screen { EvidenceImage(image: s, pair: pair) }
            }
            Text("Caught at \(caught.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var answerField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(reason == .noSession ? "Why not?" : "What is happening?", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3).onChange(of: text) { rejected = false }
            if rejected { Text("At least three words.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func submit(_ answer: Answer) {
        if !model.answer(answer, text: text) { rejected = true }
    }

    /// What the card says for a reason: its badge, the titles (one is drawn per check-in) and the detail line.
    private var copy: (badge: Badge, titles: [String], detail: String) {
        let task = model.session?.task ?? "your task"
        switch reason {
        case .distraction(let target):
            return (Bucket.drifting.badge, ["Still on \(task)?", "Is \(target) part of \(task)?", "What is \(target) for right now?"], "\(target) for 20 s")
        case .phone:
            return (Bucket.phone.badge, ["Phone?", "Is the phone part of \(task)?", "Phone in hand?"],
                    model.iPhoneInUse ? "Your iPhone has been unlocked and in use, with nothing typed or clicked here." : "A phone is in view and nothing has been typed or clicked.")
        case .idle:
            return (Bucket.drifting.badge, ["Still on \(task)?", "Still with \(task)?", "Where is your attention?"], "No keyboard or mouse input for 3 minutes.")
        case .offline:
            return (Bucket.drifting.badge, ["Your task is offline. What's this?", "What is this, while \(task) is offline?", "Is this part of \(task)?"], "Keyboard or mouse active while the task is offline.")
        case .away:
            return (Bucket.away.badge, ["Where were you?"], "No face in view and nothing typed or clicked. Answer when you are back.")
        case .noSession:
            return (Badge(text: "No session", symbol: "moon.zzz"), ["Start a session or say why not"], "It is work time and the computer is in use.")
        case .permissions:
            let missing = model.setup.first { !$0.ok }
            return (Badge(text: "Permission", symbol: "exclamationmark.triangle.fill", tint: .orange), ["Permission removed"], missing.map { "\($0.name) is off in System Settings." } ?? "Focus has lost a permission it needs.")
        }
    }
}

/// A frame scale-filled into its box, with its boxes drawn in the same crop.
private struct EvidenceImage: View {
    let image: CGImage
    var face: CGRect?, phone: CGRect?
    var phoneScore = 0.0
    /// Beside another image: an equal half of the row, 150 pt tall. Alone: the full row at the image's own aspect.
    var pair = false

    var body: some View {
        let aspect = CGFloat(image.width) / CGFloat(image.height), slot = Color.clear.frame(maxWidth: .infinity)
        Group {
            if pair { slot.frame(height: 150) } else { slot.aspectRatio(aspect, contentMode: .fit) }
        }
        .overlay {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                    if let face { box(face, in: geo.size, "You", tint: .white, ink: .black) }
                    if let phone { box(phone, in: geo.size, "Phone \(Int((phoneScore * 100).rounded()))%", tint: .red, ink: .white) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.box))
    }

    /// A normalized top-left box, mapped through the scale-fill crop.
    private func box(_ r: CGRect, in size: CGSize, _ label: String, tint: Color, ink: Color) -> some View {
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        let s = max(size.width / w, size.height / h), dx = (size.width - w * s) / 2, dy = (size.height - h * s) / 2
        let f = CGRect(x: dx + r.minX * w * s, y: dy + r.minY * h * s, width: r.width * w * s, height: r.height * h * s)
        return RoundedRectangle(cornerRadius: 4).stroke(tint, lineWidth: 2)
            .frame(width: f.width, height: f.height)
            .overlay(alignment: .topLeading) {
                Text(label).font(.caption.weight(.semibold)).fixedSize().foregroundStyle(ink).padding(.horizontal, 4)
                    .background(tint, in: RoundedRectangle(cornerRadius: 4)).offset(x: 3, y: 3)
            }
            .offset(x: f.minX, y: f.minY)
    }
}

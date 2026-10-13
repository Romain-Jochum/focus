import CoreGraphics
import FocusCore
import Foundation

/// The states the snapshots render.
enum Sample: CaseIterable { case idle, running, onBreak, paused, ended, setupMissing }

extension AppModel {
    /// A fresh model (never `.shared`) in one state, with a week of records and a journal.
    static func sample(_ state: Sample) -> AppModel {
        let model = AppModel(), now = Date()
        let current = Session(task: "Write the Focus design notes", plan: "go back to the notes and close the tab", minutes: 50, started: now.addingTimeInterval(-1200))
        model.records = (1...6).map { day in
            record("Review the sales deck", now.addingTimeInterval(-Double(day) * 86_400 - 14_400), .completed,
                   [(.focused, nil, 1500), (.drifting, "youtube.com", 180), (.focused, nil, 900), (.away, nil, 120), (.focused, nil, 1200)])
        } + [
            record("Plan the sprint", now.addingTimeInterval(-10_800), .abandoned, [(.focused, nil, 1200), (.phone, nil, 300), (.focused, nil, 600)]),
            record(current.task, current.started, plan: current.plan, state == .ended ? .completed : .running,
                   [(.focused, nil, 600), (.drifting, "reddit.com", 90), (.focused, nil, 510)]),
        ]
        model.journal = [
            Entry(at: now.addingTimeInterval(-2 * 86_400), reason: "noSession", answer: "back", text: "Reviewing the sales deck before starting"),
            Entry(at: now.addingTimeInterval(-86_400), reason: "distraction(\"news.ycombinator.com\")", answer: "drifted", text: "Was reading the news while the build ran"),
            Entry(at: now.addingTimeInterval(-3_600), reason: "idle", answer: "notDrifting", text: "Reading a paper printout while I take notes"),
        ]
        let ok = state != .setupMissing
        model.setup = [
            SetupItem(name: "Camera", ok: true, pane: "Privacy_Camera"),
            SetupItem(name: "Accessibility", ok: ok, pane: "Privacy_Accessibility"),
            SetupItem(name: "Automation (Safari, Chrome)", ok: ok, pane: "Privacy_Automation"),
            SetupItem(name: "Screen Recording", ok: ok, pane: "Privacy_ScreenCapture"),
            SetupItem(name: "Your iPhone", ok: ok, pane: "Privacy_Bluetooth", hint: "Click, then unlock it next to the Mac ›"),
        ]
        model.frontmost = "Xcode"
        model.game = sampleGame(xp: 4_120)
        switch state {
        case .idle, .setupMissing: break
        case .running: (model.session, model.remaining, model.category, model.breakAvailable, model.pausesLeft) = (current, 1800, .focused, true, 1)
        case .onBreak: (model.session, model.remaining, model.category, model.breakRemaining) = (current, 1500, .onBreak, 204)
        case .paused: (model.session, model.remaining, model.category, model.breakRemaining, model.pausing) = (current, 1500, .onBreak, 251, true)
        case .ended:
            (model.session, model.remaining, model.category) = (current, 0, .focused)
            model.award = Award(id: current.id, verdict: .perfect, focusedMinutes: 49, early: true, streak: 4, streakBonus: 0.15, xp: 69, before: 4_051, after: 4_120)
        }
        return model
    }

    /// A game at `xp` with a 4-day streak, a freeze and two perfect sessions today.
    static func sampleGame(xp: Double) -> GameState {
        var game = GameState()
        (game.xp, game.streak, game.freezes, game.todayPerfect, game.todayMinutes) = (xp, 4, 1, 2, 140)
        return game
    }

    /// Synthetic camera frame and screen for a check-in card, drawn in code. Nothing real.
    static func sampleEvidence(for reason: Reason) -> (camera: CameraEvidence?, screen: CGImage?) {
        let face = CGRect(x: 0.36, y: 0.12, width: 0.26, height: 0.46), phone = CGRect(x: 0.56, y: 0.52, width: 0.13, height: 0.20)
        switch reason {
        case .noSession, .permissions: return (nil, nil)
        case .away: return (CameraEvidence(image: sampleFrame(person: false), face: nil, phone: nil, phoneScore: 0), nil)
        case .phone: return (CameraEvidence(image: sampleFrame(person: true), face: face, phone: phone, phoneScore: 0.82), nil)
        case .distraction, .idle, .offline: return (CameraEvidence(image: sampleFrame(person: true), face: face, phone: nil, phoneScore: 0), sampleScreen())
        }
    }

    /// A 480x270 frame, 16:9 like the camera's: a wall and a chair, and a person holding a phone when `person` is set.
    private static func sampleFrame(person: Bool) -> CGImage {
        bitmap(480, 270) { ctx in
            paint(ctx, CGRect(x: 0, y: 0, width: 1, height: 1), (0.27, 0.31, 0.36))
            paint(ctx, CGRect(x: 0.30, y: 0.62, width: 0.40, height: 0.38), (0.36, 0.30, 0.24))
            guard person else { return }
            paint(ctx, CGRect(x: 0.20, y: 0.66, width: 0.60, height: 0.40), (0.22, 0.36, 0.52), ellipse: true)
            paint(ctx, CGRect(x: 0.34, y: 0.08, width: 0.30, height: 0.20), (0.18, 0.14, 0.12), ellipse: true)
            paint(ctx, CGRect(x: 0.36, y: 0.12, width: 0.26, height: 0.46), (0.84, 0.68, 0.58), ellipse: true)
            paint(ctx, CGRect(x: 0.56, y: 0.52, width: 0.13, height: 0.20), (0.10, 0.10, 0.12))
            paint(ctx, CGRect(x: 0.575, y: 0.55, width: 0.10, height: 0.14), (0.55, 0.75, 0.95))
        }
    }

    /// A 640x400 screen: a page with a toolbar, a red badge and a grid of thumbnails.
    private static func sampleScreen() -> CGImage {
        bitmap(640, 400) { ctx in
            paint(ctx, CGRect(x: 0, y: 0, width: 1, height: 1), (0.97, 0.97, 0.97))
            paint(ctx, CGRect(x: 0, y: 0, width: 1, height: 0.07), (0.85, 0.85, 0.85))
            paint(ctx, CGRect(x: 0.06, y: 0.12, width: 0.20, height: 0.12), (0.80, 0.10, 0.10))
            for i in 0..<6 {
                let x = 0.06 + Double(i % 3) * 0.31, y = 0.32 + Double(i / 3) * 0.32
                paint(ctx, CGRect(x: x, y: y, width: 0.27, height: 0.22), (0.62, 0.66, 0.72))
                paint(ctx, CGRect(x: x, y: y + 0.24, width: 0.18, height: 0.03), (0.30, 0.30, 0.30))
            }
        }
    }

    private static func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    /// Fills a normalized rect (top-left origin) or ellipse with a flat colour.
    private static func paint(_ ctx: CGContext, _ r: CGRect, _ rgb: (Double, Double, Double), ellipse: Bool = false) {
        let (w, h) = (CGFloat(ctx.width), CGFloat(ctx.height))
        let p = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        if ellipse { ctx.fillEllipse(in: p) } else { ctx.fill(p) }
    }

    private static func record(_ task: String, _ started: Date, plan: String = "", _ outcome: Outcome, _ parts: [(Bucket, String?, Double)]) -> SessionRecord {
        var record = SessionRecord(session: Session(task: task, plan: plan, minutes: 50, started: started)), time = started
        for (bucket, target, seconds) in parts {
            time = time.addingTimeInterval(seconds)
            record.add(bucket, target: target, seconds: seconds, at: time)
        }
        record.outcome = outcome
        if let target = parts.first(where: { $0.0 == .drifting })?.1 {
            record.entries = [Entry(at: time, reason: "distraction(\"\(target)\")", answer: "drifted", text: "Checking one thread for the deadline")]
        }
        return record
    }
}

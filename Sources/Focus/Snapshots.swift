import AppKit
import FocusCore
import QuartzCore
import SwiftUI

/// `Focus --snapshots <dir>`: renders every view in light and dark to PNG.
@MainActor enum Snapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cards: [(String, Reason, Sample)] = [
            ("distraction", .distraction("youtube.com"), .running), ("phone", .phone, .running), ("idle", .idle, .running),
            ("offline", .offline, .running), ("away", .away, .running), ("nosession", .noSession, .idle), ("permissions", .permissions, .setupMissing),
        ]
        let picture = samplePicture()
        for scheme in [ColorScheme.light, .dark] {
            let tag = scheme == .dark ? "dark" : "light"
            let backdrop = scheme == .dark ? Color(white: 0.12) : Color(white: 0.86)
            for state in Sample.allCases { write(PopoverView().frame(width: 300), "popover-\(state)-\(tag)", scheme, .sample(state), dir) }
            for (name, reason, state) in cards {
                let model = AppModel.sample(state), evidence = AppModel.sampleEvidence(for: reason)
                (model.evidence, model.screen) = (evidence.camera, evidence.screen)
                let screen = ZStack { backdrop; Color.black.opacity(0.35); CheckInView(reason: reason) }.frame(width: 640, height: 720)
                write(screen, "checkin-\(name)-\(tag)", scheme, model, dir)
            }
            for state in [Sample.idle, .running, .ended] {
                let model = AppModel.sample(state)
                if let picture { model.garden.preview(picture.image, steps: picture.steps, centres: picture.centres) }
                let card = state == .ended ? GardenModel.Reveal(level: model.game.level, award: model.award) : nil
                write(MainView(live: false, card: card), "main-\(state)-\(tag)", scheme, model, dir)
            }
            AppModel.gardenPreview = true   // the `--garden-preview` window
            let preview = AppModel.sample(.idle)
            if let picture { preview.garden.preview(picture.image, steps: picture.steps, centres: picture.centres) }
            write(MainView(live: false), "preview-\(tag)", scheme, preview, dir)
            AppModel.gardenPreview = false
            write(StatsView().frame(height: 1400), "stats-\(tag)", scheme, .sample(.running), dir)
            write(SettingsView(), "settings-\(tag)", scheme, .sample(.idle), dir)
        }
        renderGarden(to: dir)
        renderStage(to: dir)
    }

    /// The island at the sample model's XP, for the window snapshots.
    private static func samplePicture() -> (image: CGImage, steps: Int, centres: [CGPoint])? {
        let steps = Garden.shared.stepCount(Progression.growth(AppModel.sampleGame(xp: 4_120).xp))
        guard let renderer = GardenRenderer(), let image = renderer.render(Garden.shared.stages(after: steps)) else { return nil }
        return (image, steps, renderer.tileCentres())
    }

    /// The reward moment, withering and life at a few moments (`stage-*.png`, transparent): the stage plays in an offscreen window and its
    /// presentation tree is drawn at each moment. Core Animation's `render(in:)` leaves out masks, so the reveal shows without its circles.
    static func renderStage(to dir: URL) {
        let garden = Garden.shared, steps = garden.stepCount(Progression.growth(Progression.xp(forLevel: 40)))
        guard let renderer = GardenRenderer(), let before = renderer.render(garden.stages(after: steps - 6)),
              let after = renderer.render(garden.stages(after: steps)) else { return }
        let centres = renderer.tileCentres()
        let old = garden.stages(after: steps - 6), new = garden.stages(after: steps)
        let tiles = old.indices.filter { old[$0] != new[$0] }.map { centres[$0] }
        let model = GardenModel()
        model.preview(after, steps: steps, centres: centres)
        let award = Award(id: UUID(), verdict: .perfect, focusedMinutes: 50, xp: 72, before: 0, after: 72)
        func frames(_ name: String, _ times: [Double], _ setup: (StageView) -> Void) {
            let view = StageView(frame: CGRect(x: 0, y: 0, width: 520, height: 400))
            view.forceVisible = true
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 520, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFrontRegardless()
            view.layout()
            let start = Date()
            setup(view)
            for t in times {
                RunLoop.main.run(until: start.addingTimeInterval(t))
                guard let layer = view.layer?.presentation(), let image = draw(layer) else { print("stage frame failed: \(name)"); continue }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appending(path: "stage-\(name)-\(t)s.png"))
            }
            window.orderOut(nil)
        }
        frames("reveal", [0.2, 0.5, 0.8, 1.6]) { $0.update(image: after, reveal: .init(before: before, after: after, tiles: tiles, level: 40, award: award), life: model.life, still: false) }
        frames("wither", [1.0, 2.2]) { $0.update(image: before, reveal: .init(before: after, after: before, wither: true), life: model.life, still: false) }
        frames("life", [2.0, 6.0, 12.0]) { $0.update(image: after, reveal: nil, life: model.life, still: false) }
    }

    /// A layer tree at 2×, origin bottom left as Core Animation draws it.
    private static func draw(_ layer: CALayer) -> CGImage? {
        let width = Int(layer.bounds.width * 2), height = Int(layer.bounds.height * 2)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// The island at a few levels, as the renderer draws it (transparent PNGs), with the time each render took.
    /// Also the first steps, where the water runs from the spring to the edge (`garden-water-<step>.png`).
    static func renderGarden(to dir: URL, levels: [Int] = [1, 2, 4, 8, 15, 25, 40, 60, 80, 100]) {
        guard let renderer = GardenRenderer() else { return print("garden models missing") }
        let garden = Garden.shared
        func write(_ image: CGImage, _ name: String) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
        }
        for level in levels {
            let steps = garden.stepCount(Progression.growth(Progression.xp(forLevel: level)))
            let start = ContinuousClock.now
            guard let image = renderer.render(garden.stages(after: steps)) else { continue }
            write(image, "garden-L\(level)")
            print("garden level \(level): step \(steps) of \(garden.steps.count), \(ContinuousClock.now - start)")
        }
        let water = 2 * garden.stream.count
        for steps in [1, 2, 3, 4, water / 2, water - 1, water] {
            if let image = renderer.render(garden.stages(after: steps)) { write(image, "garden-water-\(steps)") }
        }
        let level = (1...Progression.maxLevel).first { garden.stepCount(Progression.growth(Progression.xp(forLevel: $0))) >= water }!
        print("the water reaches the edge at step \(water), during level \(level - 1)")
    }

    /// Hosts the view in an offscreen window so AppKit controls draw as they do on screen.
    private static func write(_ view: some View, _ name: String, _ scheme: ColorScheme, _ model: AppModel, _ dir: URL) {
        let host = NSHostingView(rootView: view.environment(model).environment(\.colorScheme, scheme).background(.background))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return print("snapshot failed: \(name)") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return print("snapshot failed: \(name)") }
        try? png.write(to: dir.appending(path: "\(name).png"))
    }
}

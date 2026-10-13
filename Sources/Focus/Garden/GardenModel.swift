import AppKit
import FocusCore
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The garden picture in the Focus window. It is drawn only when the growth step changes, by a short-lived child process (this binary with
/// `--render-garden`) so SceneKit's memory never stays in the app, and cached in Application Support with the tile centres
/// (docs/design.md, Garden › Rendering).
@MainActor @Observable final class GardenModel {
    /// A change for the window to play when it is next visible: the picture before and after, the tiles that changed, and the award.
    struct Reveal: Identifiable {
        let id = UUID()
        var before: CGImage?
        var after: CGImage?
        /// Centres of the tiles that changed, 0 … 1 from the image's top left.
        var tiles: [CGPoint] = []
        var wither = false
        /// The new level, on a level-up.
        var level: Int?
        var award: Award?
    }

    private(set) var image: CGImage?
    /// The growth steps `image` shows; nil before the first picture.
    private(set) var steps: Int?
    /// Each tile's top centre in the picture, 0 … 1 from the top left.
    private(set) var centres: [CGPoint] = []
    /// Set after a scored session; the stage clears it once played.
    var reveal: Reveal?

    /// Bump when the renderer's look changes, so the cached picture is drawn again.
    nonisolated static let version = 2
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let queue = DispatchQueue(label: "focus.garden", qos: .utility)
    /// The steps last asked for; a picture that finishes after a newer request is dropped.
    @ObservationIgnored private var wanted: Int?
    /// The level-up and award to play once the asked-for picture is drawn.
    @ObservationIgnored private var moment: (level: Int?, award: Award?)?

    init(dir: URL = Store().root) { self.dir = dir }

    private struct Meta: Codable { var version: Int; var steps: Int; var total: Int; var centres: [[Double]] }

    /// The cached picture, if this version of the renderer drew it for this island.
    func load() {
        guard let cached = Self.read(dir) else { return }
        (image, steps, centres) = (cached.image, cached.steps, cached.centres)
    }

    /// Shows the garden after `target` growth steps, drawing it when it changed. A level-up or an award (or `animated`, for the preview)
    /// turns the change into a reveal.
    func show(_ target: Int, level: Int? = nil, award: Award? = nil, animated: Bool = false) {
        if level != nil || award != nil || animated { moment = (level, award) }
        if target == wanted, target != steps { return }   // being drawn; the moment plays when it is
        guard target != steps || image == nil else {
            wanted = target
            if let m = moment { moment = nil; reveal = Reveal(before: image, after: image, level: m.level, award: m.award) }
            return
        }
        wanted = target
        let dir = dir
        queue.async {
            let drawn = Self.draw(target, to: dir) ? Self.read(dir).flatMap { $0.steps == target ? ($0.image, $0.centres) : nil } : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self.drawn(target, drawn) } }
        }
    }

    private func drawn(_ target: Int, _ result: (image: CGImage, centres: [CGPoint])?) {
        guard target == wanted else { return }
        let m = moment
        moment = nil
        guard let result else {
            wanted = steps
            if let m { reveal = Reveal(before: image, after: image, level: m.level, award: m.award) }
            return
        }
        let before = image, old = steps
        (image, steps, centres) = (result.image, target, result.centres)
        guard let m else { return }
        reveal = Self.reveal(from: before, old, to: result.image, target, centres: result.centres, level: m.level, award: m.award)
    }

    private static func reveal(from before: CGImage?, _ old: Int?, to after: CGImage, _ new: Int, centres: [CGPoint], level: Int?, award: Award?) -> Reveal {
        var tiles: [CGPoint] = []
        if let old {
            let a = Garden.shared.stages(after: old), b = Garden.shared.stages(after: new)
            tiles = a.indices.filter { a[$0] != b[$0] }.map { centres[$0] }
        }
        return Reveal(before: before, after: after, tiles: tiles, wither: new < (old ?? 0), level: level, award: award)
    }

    /// Where life starts: flowering tiles for butterflies, mature trees for birds.
    var life: (flowers: [CGPoint], trees: [CGPoint]) {
        guard let steps, centres.count == Garden.shared.tiles.count else { return ([], []) }
        let stages = Garden.shared.stages(after: steps)
        var flowers: [CGPoint] = [], trees: [CGPoint] = []
        for (i, tile) in Garden.shared.tiles.enumerated() {
            switch tile.destiny {
            case .meadow where stages[i] >= 5, .rock where stages[i] >= 6: flowers.append(centres[i])
            case .forest where stages[i] >= 6: trees.append(centres[i])
            default: break
            }
        }
        return (flowers, trees)
    }

    // MARK: Drawing and the cache

    /// Draws the garden after `steps` into `dir` in a child process and waits for it. Blocks, so call it off the main thread.
    nonisolated static func draw(_ steps: Int, to dir: URL) -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--render-garden", String(steps), dir.path]
        do { try process.run() } catch { NSLog("Focus: garden renderer did not start: %@", error.localizedDescription); return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// `Focus --render-garden <steps> <dir>`, the child side of `draw`: renders and writes `garden.png` and `garden.json`.
    nonisolated static func render(_ steps: Int, to dir: URL) -> Bool {
        guard let renderer = GardenRenderer(), let image = renderer.render(Garden.shared.stages(after: steps)) else { return false }
        return write(image, steps: steps, centres: renderer.tileCentres(), to: dir)
    }

    nonisolated private static func read(_ dir: URL) -> (image: CGImage, steps: Int, centres: [CGPoint])? {
        guard let data = try? Data(contentsOf: dir.appending(path: "garden.json")), let meta = try? JSONDecoder().decode(Meta.self, from: data),
              meta.version == version, meta.total == Garden.shared.steps.count, meta.centres.count == Garden.shared.tiles.count,
              let source = CGImageSourceCreateWithURL(dir.appending(path: "garden.png") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image, meta.steps, meta.centres.map { CGPoint(x: $0[0], y: $0[1]) })
    }

    nonisolated private static func write(_ image: CGImage, steps: Int, centres: [CGPoint], to dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appending(path: "garden.png")
        guard let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        let meta = Meta(version: version, steps: steps, total: Garden.shared.steps.count, centres: centres.map { [$0.x, $0.y] })
        guard CGImageDestinationFinalize(destination), let json = try? JSONEncoder().encode(meta),
              (try? json.write(to: dir.appending(path: "garden.json"), options: .atomic)) != nil
        else { NSLog("Focus: garden cache not written"); return false }
        return true
    }

    // MARK: Snapshots and the demo

    /// Sets the picture directly, for snapshots.
    func preview(_ image: CGImage, steps: Int, centres: [CGPoint]) { (self.image, self.steps, self.centres, wanted) = (image, steps, centres, steps) }

    /// `--garden-demo`: every 10 s a reveal, growing (a perfect session, every other one a level-up) and withering in turn,
    /// between the picture at `steps` and 8 steps before, both drawn as the app draws them (into a temporary folder, then removed).
    func demo(at steps: Int) {
        let low = max(steps - 8, 0), scratch = FileManager.default.temporaryDirectory.appending(path: "focus-garden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard Self.draw(low, to: scratch), let small = Self.read(scratch)?.image,
              Self.draw(steps, to: scratch), let drawn = Self.read(scratch) else { return print("garden demo: drawing failed") }
        let large = drawn.image, centres = drawn.centres
        preview(small, steps: low, centres: centres)
        var round = 0
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated {
                round += 1
                let grow = round % 2 == 1
                let award = grow ? Award(id: UUID(), verdict: .perfect, focusedMinutes: 50, early: true, streak: 4, streakBonus: 0.15, xp: 72, before: 0, after: 72)
                                 : Award(id: UUID(), verdict: .abandoned, focusedMinutes: 20, xp: -96, before: 96, after: 0)
                let (from, to) = grow ? ((small, low), (large, steps)) : ((large, steps), (small, low))
                self.reveal = Self.reveal(from: from.0, from.1, to: to.0, to.1, centres: centres, level: grow && round % 4 == 1 ? 12 : nil, award: award)
                (self.image, self.steps) = (to.0, to.1)
            }
        }
    }
}

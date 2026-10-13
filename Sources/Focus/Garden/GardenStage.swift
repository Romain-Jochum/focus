import AppKit
import QuartzCore
import SwiftUI

/// The island in the Focus window, drawn with Core Animation: the reveal, sparkles, leaves and life run in the render server, so they
/// cost the app almost nothing. Nothing moves while the window is covered or minimised, or during a session (docs/design.md, Garden).
struct GardenStage: NSViewRepresentable {
    let image: CGImage?
    let reveal: GardenModel.Reveal?
    let life: (flowers: [CGPoint], trees: [CGPoint])
    /// A session is running: no life.
    let still: Bool
    /// A reveal started playing.
    let played: (GardenModel.Reveal) -> Void

    func makeNSView(context: Context) -> StageView { StageView() }

    func updateNSView(_ view: StageView, context: Context) {
        view.played = played
        view.update(image: image, reveal: reveal, life: life, still: still)
    }
}

final class StageView: NSView {
    static let revealSeconds = 1.2
    static let witherSeconds = 3.0
    static let lifeSeconds = 20.0

    var played: (GardenModel.Reveal) -> Void = { _ in }
    /// Plays without a visible window, for the snapshots.
    var forceVisible = false

    private let base = CALayer()
    private var image: CGImage?
    private var life: (flowers: [CGPoint], trees: [CGPoint]) = ([], [])
    private var still = false
    /// A reveal waiting for the window to be visible; `base` shows its picture before until then.
    private var pending: GardenModel.Reveal?
    private var lastReveal: UUID?
    private var revealing = false
    private var wasVisible = false
    /// The window came into view and life has not run since (the tiles may arrive after the window does).
    private var lifeDue = false
    private var lifeLayers: [CALayer] = []
    /// Counts life rounds, so a round's timer does not end a later one.
    private var lifeRound = 0
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.box
        layer?.masksToBounds = true
        base.contentsGravity = .resizeAspect
        layer?.addSublayer(base)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        CATransaction.commit()
        playIfVisible()
    }

    func update(image: CGImage?, reveal: GardenModel.Reveal?, life: (flowers: [CGPoint], trees: [CGPoint]), still: Bool) {
        self.life = life
        if still, !self.still { stopLife(); lifeDue = false }
        self.still = still
        if let reveal, reveal.id != lastReveal { pending = reveal }
        self.image = image
        if !revealing { show(pending != nil ? pending!.before : image) }
        if !playIfVisible(), lifeDue { startLife() }
    }

    private func show(_ picture: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.contents = picture
        CATransaction.commit()
    }

    private var visible: Bool { forceVisible || window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } == true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
        }
        visibilityChanged()
    }

    private func visibilityChanged() {
        let now = visible
        defer { wasVisible = now }
        lifeDue = now && (lifeDue || !wasVisible)
        guard now else { return stopLife() }
        if lifeDue, !playIfVisible() { startLife() }
    }

    @discardableResult private func playIfVisible() -> Bool {
        guard let reveal = pending, !revealing, visible, bounds.width > 0 else { return false }
        pending = nil
        lastReveal = reveal.id
        play(reveal)
        let played = played
        DispatchQueue.main.async { played(reveal) }   // it changes SwiftUI state, so not during this view update
        return true
    }

    // MARK: The reward moment

    /// The new picture spreads from the tiles that grew, with a sparkle on each; a level-up adds a burst of leaves; withering fades in slowly.
    private func play(_ reveal: GardenModel.Reveal) {
        revealing = true
        stopLife()
        let scale = imageRect.width / 520
        let tiles = reveal.tiles.map(point)
        var layers: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.base.contents = self.pending != nil ? self.pending!.before : self.image
                layers.forEach { $0.removeFromSuperlayer() }
                CATransaction.commit()
                self.revealing = false
                if !self.playIfVisible() { self.startLife() }
            }
        }
        let now = CACurrentMediaTime()
        if let after = reveal.after, after !== reveal.before {
            let top = CALayer()
            top.frame = bounds
            top.contents = after
            top.contentsGravity = .resizeAspect
            layer?.insertSublayer(top, above: base)
            layers.append(top)
            if reveal.wither || reveal.before == nil || tiles.isEmpty {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = reveal.wither ? Self.witherSeconds : Self.revealSeconds
                top.add(fade, forKey: "fade")
            } else {
                // Circles centred a little above each tile, wide enough for a grown tree and its shadow.
                let centres = tiles.map { CGPoint(x: $0.x, y: $0.y + 18 * scale) }
                let mask = CAShapeLayer()
                mask.frame = bounds
                mask.path = Self.circles(centres, radius: 80 * scale)
                let grow = CABasicAnimation(keyPath: "path")
                grow.fromValue = Self.circles(centres, radius: 1)
                grow.duration = Self.revealSeconds
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                mask.add(grow, forKey: "grow")
                top.mask = mask
            }
        }
        var effects: [CALayer] = []
        if !reveal.wither { effects += sparkles(at: tiles, begin: now + 0.2, scale: scale) }
        if reveal.level != nil { effects += leaves(from: point(CGPoint(x: 0.5, y: 0.42)), begin: now + 0.1, scale: scale) }
        effects.forEach { layer?.addSublayer($0) }
        layers += effects
        CATransaction.commit()
    }

    private func sparkles(at points: [CGPoint], begin: CFTimeInterval, scale: CGFloat) -> [CALayer] {
        points.prefix(16).enumerated().flatMap { k, p in
            (0..<3).map { j in
                let star = CAShapeLayer()
                star.path = Self.star([7, 5, 6][j] * scale)
                star.fillColor = Self.rgb(1, 0.97, 0.78)
                star.position = CGPoint(x: p.x + [-9, 10, 1][j] * scale, y: p.y + [12, 22, 34][j] * scale)
                star.opacity = 0
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 0]
                fade.keyTimes = [0, 0.35, 1]
                let size = CAKeyframeAnimation(keyPath: "transform.scale")
                size.values = [0.3, 1.15, 0.5]
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.toValue = Double.pi / 3
                star.add(Self.group([fade, size, spin], begin: begin + Double(k) * 0.06 + Double(j) * 0.15, duration: 0.9), forKey: "sparkle")
                return star
            }
        }
    }

    private func leaves(from origin: CGPoint, begin: CFTimeInterval, scale: CGFloat) -> [CALayer] {
        let colours = [Self.rgb(0.38, 0.63, 0.33), Self.rgb(0.50, 0.71, 0.35), Self.rgb(0.62, 0.76, 0.38), Self.rgb(0.88, 0.70, 0.30)]
        return (0..<28).map { k in
            let leaf = CAShapeLayer()
            leaf.path = CGPath(ellipseIn: CGRect(x: -5 * scale, y: -2.2 * scale, width: 10 * scale, height: 4.4 * scale), transform: nil)
            leaf.fillColor = colours[k % colours.count]
            leaf.position = origin
            leaf.opacity = 0
            let angle = CGFloat.random(in: 0.2 ... .pi - 0.2), reach = CGFloat.random(in: 80...190) * scale
            let end = CGPoint(x: origin.x + cos(angle) * reach * 1.3, y: origin.y + sin(angle) * reach * 0.3 - 60 * scale)
            let path = CGMutablePath()
            path.move(to: origin)
            path.addQuadCurve(to: end, control: CGPoint(x: origin.x + cos(angle) * reach * 0.8, y: origin.y + sin(angle) * reach * 1.1))
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.toValue = CGFloat.random(in: -3...3) * .pi
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.08, 0.65, 1]
            leaf.add(Self.group([move, spin, fade], begin: begin + Double(k % 7) * 0.02, duration: 1.8), forKey: "burst")
            return leaf
        }
    }

    // MARK: Life

    /// Up to 4 butterflies wander over flowering tiles and up to 2 birds leave mature trees, for 20 s.
    private func startLife() {
        guard !still, visible, !revealing, lifeLayers.isEmpty, bounds.width > 0 else { return }
        let scale = imageRect.width / 520, start = CACurrentMediaTime(), end = start + Self.lifeSeconds
        lifeLayers = life.flowers.shuffled().prefix(4).enumerated().map { k, p in butterfly(from: point(p), begin: start + Double(k) * 1.5, end: end, scale: scale) }
            + life.trees.shuffled().prefix(2).enumerated().map { k, p in bird(from: point(p), begin: start + 1.5 + Double(k) * 8, scale: scale) }
        guard !lifeLayers.isEmpty else { return }
        lifeDue = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lifeLayers.forEach { layer?.addSublayer($0) }
        CATransaction.commit()
        lifeRound += 1
        let round = lifeRound
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifeSeconds) { [weak self] in
            if self?.lifeRound == round { self?.stopLife() }
        }
    }

    private func stopLife() {
        lifeRound += 1
        guard !lifeLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lifeLayers.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        lifeLayers = []
    }

    private func butterfly(from flower: CGPoint, begin: CFTimeInterval, end: CFTimeInterval, scale: CGFloat) -> CALayer {
        let colour = [Self.rgb(0.98, 0.96, 0.88), Self.rgb(0.98, 0.84, 0.36), Self.rgb(0.95, 0.62, 0.32), Self.rgb(0.80, 0.70, 0.95)].randomElement()!
        let body = CALayer()
        body.opacity = 0
        let beat = 0.09 + Double.random(in: 0...0.03)
        for side in [-1.0, 1.0] {
            let wing = CAShapeLayer()
            wing.path = CGPath(ellipseIn: CGRect(x: side < 0 ? -4.5 * scale : 0, y: -3.5 * scale, width: 4.5 * scale, height: 7 * scale), transform: nil)
            wing.fillColor = colour
            let flap = CABasicAnimation(keyPath: "transform.scale.x")
            flap.fromValue = 1
            flap.toValue = 0.2
            flap.duration = beat
            flap.autoreverses = true
            flap.repeatCount = .infinity
            wing.add(flap, forKey: "flap")
            body.addSublayer(wing)
        }
        // A wander around the flower, a little above the ground, settling back at the end.
        var points = [CGPoint(x: flower.x, y: flower.y + 4 * scale)]
        for _ in 0..<8 { points.append(CGPoint(x: flower.x + .random(in: -45...45) * scale, y: flower.y + .random(in: 8...50) * scale)) }
        points.append(CGPoint(x: flower.x + .random(in: -20...20) * scale, y: flower.y + 4 * scale))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = Self.smooth(points)
        move.calculationMode = .paced
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.06, 0.94, 1]
        body.add(Self.group([move, fade], begin: begin, duration: end - begin), forKey: "life")
        return body
    }

    private func bird(from tree: CGPoint, begin: CFTimeInterval, scale: CGFloat) -> CALayer {
        let bird = CAShapeLayer()
        let wings = CGMutablePath()
        wings.move(to: CGPoint(x: -6 * scale, y: 2 * scale))
        wings.addQuadCurve(to: .zero, control: CGPoint(x: -3 * scale, y: 4 * scale))
        wings.addQuadCurve(to: CGPoint(x: 6 * scale, y: 2 * scale), control: CGPoint(x: 3 * scale, y: 4 * scale))
        bird.path = wings
        bird.strokeColor = Self.rgb(0.22, 0.24, 0.27, 0.85)
        bird.fillColor = nil
        bird.lineWidth = 1.4 * scale
        bird.lineCap = .round
        bird.opacity = 0
        let flap = CABasicAnimation(keyPath: "transform.scale.y")
        flap.fromValue = 1
        flap.toValue = -0.5
        flap.duration = 0.18
        flap.autoreverses = true
        flap.repeatCount = .infinity
        bird.add(flap, forKey: "flap")
        // Up from the treetop and away over the nearer side of the window.
        let start = CGPoint(x: tree.x, y: tree.y + 34 * scale)
        let end = CGPoint(x: tree.x < bounds.midX ? -20 : bounds.width + 20, y: bounds.height - .random(in: 10...70) * scale)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + 30 * scale))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.85, 1]
        bird.add(Self.group([move, fade], begin: begin, duration: 7), forKey: "flight")
        return bird
    }

    // MARK: Geometry

    /// Where the picture sits in the view (aspect fit).
    private var imageRect: CGRect {
        let aspect = GardenRenderer.pixelSize.width / GardenRenderer.pixelSize.height
        let width = min(bounds.width, bounds.height * aspect), height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// A picture point (0 … 1 from the top left) in layer coordinates (origin bottom left).
    private func point(_ p: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height)
    }

    private static func group(_ animations: [CAAnimation], begin: CFTimeInterval, duration: CFTimeInterval) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.beginTime = begin
        group.duration = duration
        group.fillMode = .backwards
        return group
    }

    private static func circles(_ centres: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for c in centres { path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)) }
        return path
    }

    /// A four-pointed star of radius `r`.
    private static func star(_ r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for k in 0..<8 {
            let angle = CGFloat(k) * .pi / 4, d = k % 2 == 0 ? r : r * 0.28
            let p = CGPoint(x: cos(angle) * d, y: sin(angle) * d)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// A smooth curve through `points` (quadratic segments between midpoints).
    private static func smooth(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 1..<points.count - 1 {
            path.addQuadCurve(to: CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2), control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

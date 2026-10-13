import AppKit
import FocusCore
import SceneKit

/// Draws the island at given tile stages, offscreen, from the Kenney Nature Kit models in Resources/Garden (CC0), recoloured by material name.
/// The app uses it only in its `--render-garden` child process (GardenModel.draw), so SceneKit's memory never stays in the app; the
/// snapshots use it directly. Nothing here touches the screen. SceneKit is deprecated since WWDC 2025 but ships on macOS 26; it stays
/// confined to this file. What each stage looks like: docs/design.md, Garden, and `Destiny`.
final class GardenRenderer {
    /// 2× a 520 × 400 pt panel.
    static let pixelSize = CGSize(width: 1040, height: 800)
    /// Half the visible height, in tiles.
    private static let orthoScale = 6.2

    private let garden: Garden
    private let dir: URL
    private var models: [String: SCNGeometry] = [:]
    /// One geometry per model and colour override, shared by every node that uses it.
    private var geometries: [String: SCNGeometry] = [:]
    private let camera: SCNNode

    /// Nil when the models are missing (an unbundled build run outside the repo).
    init?(garden: Garden = .shared) {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Garden"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Garden")]
        guard let dir = dirs.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cliff_block_rock.obj").path) })
        else { NSLog("Focus: garden models missing"); return nil }
        self.garden = garden
        self.dir = dir
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = Self.orthoScale
        cam.zNear = 1
        cam.zFar = 60
        camera = SCNNode()
        camera.camera = cam
        // A 2:1 dimetric view: 45° around, atan(1/2) down.
        let elevation = atan(0.5), distance = 30.0
        camera.position = SCNVector3(distance * cos(elevation) * sin(.pi / 4), distance * sin(elevation) + 1.2, distance * cos(elevation) * cos(.pi / 4))
        camera.look(at: SCNVector3(0, 1.2, 0))
    }

    /// The island at `stages` (one per tile), with a transparent background.
    func render(_ stages: [Int]) -> CGImage? {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        for (i, tile) in garden.tiles.enumerated() { build(tile, stages: stages, index: i, in: scene.rootNode) }
        scene.rootNode.addChildNode(camera)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 950
        sun.light!.castsShadow = true
        sun.light!.shadowMode = .forward
        sun.light!.shadowSampleCount = 16
        sun.light!.shadowRadius = 3
        sun.light!.shadowColor = NSColor(white: 0, alpha: 0.3)
        sun.light!.automaticallyAdjustsShadowProjection = false
        sun.light!.orthographicScale = 10
        sun.light!.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.light!.zNear = 1
        sun.light!.zFar = 60
        sun.position = SCNVector3(-9, 18, 6)
        sun.look(at: SCNVector3(0, 0, 0))
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 470
        scene.rootNode.addChildNode(sun)
        scene.rootNode.addChildNode(ambient)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        let image = renderer.snapshot(atTime: 0, with: Self.pixelSize, antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Where each tile's top centre lands in the image, 0 … 1 from the top left.
    func tileCentres() -> [CGPoint] {
        garden.tiles.map { project(SCNVector3(Double($0.x) - offset, 1, Double($0.z) - offset)) }
    }

    /// A world point in the image, 0 … 1 from the top left.
    func project(_ point: SCNVector3) -> CGPoint {
        let p = camera.convertPosition(point, from: nil)
        let aspect = Self.pixelSize.width / Self.pixelSize.height
        return CGPoint(x: 0.5 + p.x / (Self.orthoScale * aspect) / 2, y: 0.5 - p.y / Self.orthoScale / 2)
    }

    private var offset: Double { Double(Garden.size - 1) / 2 }

    // MARK: Building a tile

    private func build(_ tile: GardenTile, stages: [Int], index: Int, in root: SCNNode) {
        let stage = stages[index]
        var rng = Rng(tile.seed)
        // Draw every random number up front, so a stage only adds to what the earlier stages placed.
        let r = (0..<24).map { _ in rng.next() }
        let x = Double(tile.x) - offset, z = Double(tile.z) - offset
        let slots = Self.slots.indices.sorted { r[$0] < r[$1] }.map { i in (Self.slots[i].0 + (r[i + 8] - 0.5) * 0.12, Self.slots[i].1 + (r[i + 14] - 0.5) * 0.12) }
        func put(_ name: String, _ colours: [String: NSColor] = [:], _ slot: (Double, Double), y: Double = 1, scale: Double = 1, turn: Double) {
            let node = self.node(name, colours)
            node.position = SCNVector3(x + slot.0, y, z + slot.1)
            node.eulerAngles.y = turn * 2 * .pi
            node.scale = SCNVector3(scale, scale, scale)
            root.addChildNode(node)
        }

        if tile.destiny == .stream, stage >= 1 {
            buildStream(tile, stages: stages, index: index, x: x, z: z, root: root, r: r)
            return
        }
        // Three shades per ground colour, so the ground reads as patches rather than one flat board.
        let top = Self.top(tile.destiny, stage).shaded([0.95, 1, 1.05][Int(r[22] * 3)])
        put("cliff_block_rock", ["grass": top, "dirt": Palette.dirt], (0, 0), y: 0, turn: 0)

        // Barren land: the odd dead stump, log or stone, cleared once grass grows.
        if stage < 3, r[0] < 0.32 {
            let dead = ["stump_old", "log", "rock_smallA", "rock_smallC", "rock_smallF", "stump_round"][Int(r[1] * 6)]
            put(dead, ["grass": Palette.barren, "dirt": Palette.deadStone, "woodBark": Palette.deadWood, "woodInner": Palette.deadWood], slots[5], scale: 0.8, turn: r[2])
        }
        if stage >= 2 { put("grass", ["grass": stage == 2 ? Palette.sprout : Palette.plant], slots[0], scale: stage == 2 ? 0.45 : 0.75, turn: r[3]) }

        switch tile.destiny {
        case .meadow:
            if stage >= 4 {
                put(r[4] < 0.5 ? "grass" : "grass_large", ["grass": Palette.plant], slots[1], scale: 0.7, turn: r[5])
                put("grass", ["grass": Palette.plant], slots[2], scale: 0.6, turn: r[6])
            }
            let colours = ["red", "yellow", "purple"], first = Int(r[7] * 3)
            if stage >= 5 { put("flower_\(colours[first])A", ["grass": Palette.plant], slots[3], scale: 0.9, turn: r[8]) }
            if stage >= 6 {
                put("flower_\(colours[(first + 1) % 3])B", ["grass": Palette.plant], slots[4], scale: 0.8, turn: r[9])
                put("flower_\(colours[first])A", ["grass": Palette.plant], slots[5], scale: 0.7, turn: r[10])
            }
            if stage >= 7 { put(r[11] < 0.5 ? "plant_bush" : "plant_bushDetailed", ["grass": Palette.bush], slots[6], scale: 0.7, turn: r[12]) }
            if stage >= 8 { put(r[13] < 0.5 ? "grass_leafsLarge" : "plant_flatTall", ["grass": Palette.plant], slots[7], scale: 0.7, turn: r[14]) }
        case .forest:
            if stage >= 4 {
                let tree = Self.trees[Int(r[15] * Double(Self.trees.count))]
                put(tree, [:], (slots[1].0 * 0.4, slots[1].1 * 0.4), scale: [0.35, 0.55, 0.8, 1][min(stage - 4, 3)], turn: r[16])
            }
            if stage >= 8 {
                let floor = ["plant_bushSmall", "mushroom_redGroup", "grass_leafs", "plant_flatShort"][Int(r[17] * 4)]
                put(floor, ["grass": Palette.bush], slots[2], scale: 0.75, turn: r[18])
            }
            if stage >= 9 {
                let tree = Self.trees[Int(r[19] * Double(Self.trees.count))]
                put(tree, [:], (slots[3].0 * 1.1, slots[3].1 * 1.1), scale: 0.6, turn: r[20])
            }
        case .rock:
            if stage >= 4 {
                let stone = stage >= 5 ? Palette.moss : Palette.stone
                put(["stone_largeA", "stone_largeB", "stone_tallA", "stone_tallC"][Int(r[15] * 4)], ["stone": stone, "_defaultMat": stone], (0, 0), scale: 0.85, turn: r[16])
                put("stone_smallA", ["stone": stone], slots[2], scale: 0.9, turn: r[17])
            }
            if stage >= 6 { put("flower_yellowA", ["grass": Palette.plant], slots[3], scale: 0.7, turn: r[18]) }
            if stage >= 7 { put("mushroom_tanGroup", [:], slots[4], scale: 0.8, turn: r[19]) }
        case .stream: break
        }
    }

    /// A stream tile: a lowered block with a river piece turned to join the stream tiles next to it that are dug already, so a stream still
    /// on its way ends in a rounded end (a lone tile is a pool); dry at stage 1, water from 2, green banks from 3.
    private func buildStream(_ tile: GardenTile, stages: [Int], index: Int, x: Double, z: Double, root: SCNNode, r: [Double]) {
        let stage = stages[index], along = garden.stream.firstIndex(of: index)!
        let n = Garden.size
        func direction(to other: Int) -> (Int, Int) { (other % n - tile.x, other / n - tile.z) }
        var openings = [(Int, Int)]()
        if along > 0, stages[garden.stream[along - 1]] >= 1 { openings.append(direction(to: garden.stream[along - 1])) }
        if along + 1 == garden.stream.count { openings.append((1, 0)) }   // the last one runs off the edge
        else if stages[garden.stream[along + 1]] >= 1 { openings.append(direction(to: garden.stream[along + 1])) }
        let (piece, turn) = Self.riverPiece(openings)
        let bank = stage >= 3 ? Palette.grass : stage >= 2 ? Palette.soil : Palette.barren
        let water = stage >= 2 ? Palette.water : Palette.channel
        let block = node("cliff_block_rock", ["grass": bank, "dirt": Palette.dirt])
        block.position = SCNVector3(x, -0.1, z)
        root.addChildNode(block)
        let river = node(piece, ["grass": bank, "water": water, "dirt": Palette.dirt, "dirtDark": Palette.channel])
        river.position = SCNVector3(x, 0.96, z)
        river.eulerAngles.y = turn
        root.addChildNode(river)
        if along == garden.stream.count - 1, stage >= 2 {
            // The stream spills over the island's edge: a sheet of water down the side.
            let sheet = SCNBox(width: 0.02, height: 1.02, length: 0.4, chamferRadius: 0)
            let material = SCNMaterial()
            material.diffuse.contents = Palette.water.blended(withFraction: 0.25, of: Palette.foam)
            material.lightingModel = .lambert
            sheet.materials = [material]
            let fall = SCNNode(geometry: sheet)
            fall.position = SCNVector3(x + 0.51, 0.4, z)
            root.addChildNode(fall)
        }
        if stage >= 4, along > 0 {
            let lily = node(r[4] < 0.5 ? "lily_large" : "lily_small", [:])
            lily.position = SCNVector3(x + (r[5] - 0.5) * 0.2, 0.92, z + (r[6] - 0.5) * 0.2)
            lily.eulerAngles.y = r[7] * 2 * .pi
            root.addChildNode(lily)
        }
        if stage >= 5 {
            // Reeds in a corner of the bank.
            let corner = [(-0.38, -0.38), (0.38, -0.38), (-0.38, 0.38), (0.38, 0.38)][Int(r[8] * 4)]
            let reeds = node("plant_flatTall", [:])
            reeds.position = SCNVector3(x + corner.0, 0.96, z + corner.1)
            reeds.scale = SCNVector3(0.55, 0.55, 0.55)
            reeds.eulerAngles.y = r[9] * 2 * .pi
            root.addChildNode(reeds)
        }
    }

    /// The river piece and its turn about y for a tile open toward `openings` (tile steps: (1, 0) is +x).
    /// Straight runs along z, the corner joins −x and −z, the closed end opens to −z, the pool is closed all round; a quarter turn maps
    /// −z → −x → +z → +x.
    static func riverPiece(_ openings: [(Int, Int)]) -> (String, Double) {
        let pieces: [(String, [(Int, Int)])] = [("ground_riverStraight", [(0, 1), (0, -1)]), ("ground_riverCorner", [(-1, 0), (0, -1)]),
                                                ("ground_riverEndClosed", [(0, -1)]), ("ground_riverTile", [])]
        let want = Set(openings.map { "\($0.0),\($0.1)" })
        for (name, open) in pieces where open.count == want.count {
            var dirs = open
            for k in 0..<4 {
                if Set(dirs.map { "\($0.0),\($0.1)" }) == want { return (name, Double(k) * .pi / 2) }
                dirs = dirs.map { ($0.1, -$0.0) }
            }
        }
        return ("ground_riverStraight", 0)
    }

    // MARK: Models and colours

    /// A node of `name` with the palette applied, `colours` overriding it by material name.
    private func node(_ name: String, _ colours: [String: NSColor]) -> SCNNode {
        let key = name + colours.keys.sorted().map { "|\($0)=\(colours[$0]!.description)" }.joined()
        if let geometry = geometries[key] { return SCNNode(geometry: geometry) }
        // Each Kenney OBJ holds one mesh at the origin. (flattenedClone() comes back empty before the first render.)
        let base = models[name] ?? {
            let mesh = (try? SCNScene(url: dir.appendingPathComponent("\(name).obj"), options: nil))?.rootNode.childNodes.first { $0.geometry != nil }?.geometry
            if mesh == nil { NSLog("Focus: garden model %@ missing", name) }
            models[name] = mesh ?? SCNGeometry()
            return models[name]!
        }()
        guard let geometry = base.copy() as? SCNGeometry else { return SCNNode() }
        geometry.materials = geometry.materials.map { m in
            let c = m.copy() as! SCNMaterial
            c.diffuse.contents = colours[m.name ?? ""] ?? Palette.byMaterial[m.name ?? ""] ?? m.diffuse.contents
            c.lightingModel = .lambert
            return c
        }
        geometries[key] = geometry
        return SCNNode(geometry: geometry)
    }

    /// Where things stand on a tile, before seeded jitter; shuffled per tile.
    private static let slots: [(Double, Double)] = [(-0.24, -0.22), (0.22, -0.26), (-0.26, 0.2), (0.24, 0.24), (0.02, 0.02), (-0.04, -0.3), (0.3, 0.0), (-0.3, -0.02)]
    private static let trees = ["tree_oak", "tree_default", "tree_detailed", "tree_fat", "tree_tall", "tree_pineRoundA", "tree_pineDefaultA",
                                "tree_pineTallA", "tree_cone", "tree_simple", "tree_blocks", "tree_oak_fall"]

    /// A tile's top colour: dust, then moist soil, sprouts and grass, lusher with age.
    private static func top(_ destiny: Destiny, _ stage: Int) -> NSColor {
        switch stage {
        case 0: Palette.barren
        case 1: Palette.soil
        case 2: Palette.sproutGround
        default: destiny == .forest && stage >= 7 ? Palette.forestFloor : stage >= 5 ? Palette.lush : Palette.grass
        }
    }
}

extension NSColor {
    /// The same colour, its RGB scaled by `factor`.
    func shaded(_ factor: Double) -> NSColor {
        guard factor != 1, let c = usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: min(c.redComponent * factor, 1), green: min(c.greenComponent * factor, 1), blue: min(c.blueComponent * factor, 1), alpha: c.alphaComponent)
    }
}

/// The garden's colours (sRGB), replacing Kenney's by material name.
enum Palette {
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    static let barren = rgb(0.74, 0.66, 0.55), soil = rgb(0.55, 0.43, 0.32), sproutGround = rgb(0.60, 0.60, 0.38)
    static let grass = rgb(0.58, 0.74, 0.40), lush = rgb(0.50, 0.71, 0.35), forestFloor = rgb(0.42, 0.62, 0.32)
    static let sprout = rgb(0.62, 0.76, 0.38), plant = rgb(0.45, 0.68, 0.33), bush = rgb(0.36, 0.60, 0.32)
    static let dirt = rgb(0.56, 0.44, 0.33), channel = rgb(0.46, 0.36, 0.27), water = rgb(0.40, 0.68, 0.84), foam = rgb(0.86, 0.93, 0.96)
    static let stone = rgb(0.64, 0.64, 0.62), moss = rgb(0.54, 0.62, 0.50), deadStone = rgb(0.62, 0.56, 0.48), deadWood = rgb(0.52, 0.45, 0.39)
    static let byMaterial: [String: NSColor] = [
        "dirt": dirt, "dirtDark": channel, "grass": grass, "leafsGreen": rgb(0.38, 0.63, 0.33), "leafsDark": rgb(0.24, 0.47, 0.32),
        "leafsFall": rgb(0.88, 0.58, 0.27), "woodBark": rgb(0.47, 0.34, 0.24), "woodBarkDark": rgb(0.36, 0.26, 0.19),
        "woodBirch": rgb(0.90, 0.88, 0.82), "woodInner": rgb(0.80, 0.64, 0.44), "water": water, "stone": stone,
        "stoneDark": rgb(0.50, 0.50, 0.49), "colorRed": rgb(0.86, 0.33, 0.33), "colorYellow": rgb(0.96, 0.82, 0.32),
        "colorPurple": rgb(0.62, 0.45, 0.82), "colorTan": rgb(0.80, 0.68, 0.52), "colorWhite": rgb(0.96, 0.95, 0.92), "_defaultMat": rgb(0.92, 0.88, 0.80),
    ]
}

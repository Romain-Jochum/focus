import Foundation

/// What a tile grows into. Every tile starts barren (stage 0); land tiles then go soil (1), young grass (2), grass (3) and on into their own stages.
public enum Destiny: String, Sendable, CaseIterable {
    /// 4 tufts, 5 first flowers, 6 more flowers, 7 a bush, 8 tall grass.
    case meadow
    /// 4 sapling, 5 young tree, 6 grown tree, 7 mature tree, 8 undergrowth, 9 a second tree.
    case forest
    /// 4 boulders, 5 moss, 6 flowers in the cracks, 7 mushrooms.
    case rock
    /// 1 dry channel, 2 water, 3 green banks, 4 lilies, 5 reeds. The spring is the first stream tile.
    case stream

    public var stages: Int { switch self { case .meadow: 8; case .forest: 9; case .rock: 7; case .stream: 5 } }
}

/// One tile of the island: its grid position, what it grows into, and the seed for its look.
public struct GardenTile: Sendable, Equatable {
    public let x: Int
    public let z: Int
    public let destiny: Destiny
    /// Seeds the renderer's choices for this tile (models, turns, offsets), so it looks the same every time.
    public let seed: UInt64
}

/// The island and its fixed growth sequence (docs/design.md, Garden). Pure and deterministic: the same seed gives the same island.
public struct Garden: Sendable {
    public static let size = 11
    public static let shared = Garden()
    /// Rank per tile of distance from the spring, and per stage after grass (see `init`).
    static let spread = 1.0
    static let stageGap = 0.6
    static let forestReach = 2.7

    /// Row-major: index = z · size + x.
    public let tiles: [GardenTile]
    /// Tile indices from the spring to the island's edge.
    public let stream: [Int]
    /// The tile each step advances by one stage, in order.
    public let steps: [Int]

    public var spring: Int { stream[0] }

    public init(seed: UInt64 = 2026) {
        var rng = Rng(seed)
        let n = Self.size
        // The stream: from the spring, wandering toward the front edge without touching itself.
        var path = [(3, 4)]
        while path.last!.0 < n - 1 {
            let (x, z) = path.last!
            let options = [(x + 1, z), (x, z - 1), (x, z + 1)].filter { c in
                (1..<n - 1).contains(c.1) && !path.contains { $0 == c }
                    && path.dropLast().allSatisfy { abs($0.0 - c.0) + abs($0.1 - c.1) > 1 }
            }
            let sideways = options.filter { $0.0 == x }
            path.append(rng.next() < 0.4 && !sideways.isEmpty ? sideways[Int(rng.next() * Double(sideways.count))] : options.first { $0.0 > x } ?? options[0])
        }
        let streamSet = Set(path.map { $0.1 * n + $0.0 })
        // A forest in each quarter of the island, away from the spring; rocks mostly on the rim; meadows between.
        let quarter = Double(n) / 4
        let centres = [(1.0, 1.0), (3.0, 1.0), (1.0, 3.0), (3.0, 3.0)].map { ($0.0 * quarter + (rng.next() - 0.5) * 2.4, $0.1 * quarter + (rng.next() - 0.5) * 2.4) }
        var tiles: [GardenTile] = []
        for z in 0..<n {
            for x in 0..<n {
                let i = z * n + x
                let near = centres.map { hypot(Double(x) - $0.0, Double(z) - $0.1) }.min()!
                let rim = min(x, z, n - 1 - x, n - 1 - z) == 0
                let fromSpring = hypot(Double(x - path[0].0), Double(z - path[0].1))
                let roll = rng.next(), noise = rng.next()
                let destiny: Destiny = streamSet.contains(i) ? .stream
                    : fromSpring >= 2 && near + noise * 1.2 < Self.forestReach ? .forest
                    : fromSpring >= 2 && roll < (rim ? 0.3 : 0.06) ? .rock
                    : .meadow
                tiles.append(GardenTile(x: x, z: z, destiny: destiny, seed: rng.bits()))
            }
        }
        self.tiles = tiles
        stream = path.map { $0.1 * n + $0.0 }

        // The water comes first: from the spring down to the edge, each stream tile is dug (stage 1) and filled (stage 2) before anything
        // else grows. Then each (tile, stage) gets a rank: later stages and tiles farther from the spring come later, with a little seeded
        // noise. Soil, sprouts and grass follow each other quickly, so the green spreads as a wave with the growth behind it. Stream tiles
        // count their distance along the stream.
        struct Candidate { var tile: Int; var stage: Int; var rank: Double }
        var candidates: [Candidate] = []
        for (i, tile) in tiles.enumerated() {
            let along = stream.firstIndex(of: i)
            let d = along.map(Double.init) ?? hypot(Double(tile.x - path[0].0), Double(tile.z - path[0].1))
            let jitter = along == nil ? rng.next() * 0.8 : 0
            for stage in 1...tile.destiny.stages {
                if let along, stage <= 2 {
                    candidates.append(Candidate(tile: i, stage: stage, rank: Double(2 * along + stage) - 1_000))
                    continue
                }
                let wobble = along == nil ? rng.next() * 0.25 : 0
                let base = Double(stage) <= 3 ? 0.3 * Double(stage) : 0.9 + Self.stageGap * Double(stage - 3)
                candidates.append(Candidate(tile: i, stage: stage, rank: (along == 0 ? 0.5 : 1) * base + Self.spread * d + jitter + wobble))
            }
        }
        candidates.sort { $0.rank < $1.rank }

        // Replay in rank order, holding back any step whose condition is not met yet (soil spreads, grass needs green next to it, water flows down).
        var stages = [Int](repeating: 0, count: tiles.count)
        var steps: [Int] = []
        var pending: [Candidate] = []
        let stream = self.stream
        for c in candidates {
            guard Self.allowed(c.tile, c.stage, stages, tiles: tiles, stream: stream) else { pending.append(c); continue }
            stages[c.tile] = c.stage
            steps.append(c.tile)
            while let k = pending.firstIndex(where: { Self.allowed($0.tile, $0.stage, stages, tiles: tiles, stream: stream) }) {
                let held = pending.remove(at: k)
                stages[held.tile] = held.stage
                steps.append(held.tile)
            }
        }
        precondition(pending.isEmpty, "garden growth stalled")
        self.steps = steps
    }

    /// Each tile's stage once the first `count` steps have happened.
    public func stages(after count: Int) -> [Int] {
        var stages = [Int](repeating: 0, count: tiles.count)
        for tile in steps.prefix(max(count, 0)) { stages[tile] += 1 }
        return stages
    }

    /// The number of steps done at a growth fraction (`Progression.growth`).
    public func stepCount(_ growth: Double) -> Int { min(Int((max(growth, 0) * Double(steps.count)).rounded(.down)), steps.count) }

    /// Whether `tile` may move to `stage` now. Land is green from stage 3, a stream tile once it holds water (stage 2).
    static func allowed(_ tile: Int, _ stage: Int, _ stages: [Int], tiles: [GardenTile], stream: [Int]) -> Bool {
        guard stages[tile] == stage - 1 else { return false }
        if let along = stream.firstIndex(of: tile) {
            // Water only flows from water; the spring needs nothing.
            return stage != 2 || along == 0 || stages[stream[along - 1]] >= 2
        }
        let neighbours = Self.neighbours(tile)
        switch stage {
        case 1: return neighbours.contains { stages[$0] >= 1 }
        case 3: return neighbours.contains { stages[$0] >= (tiles[$0].destiny == .stream ? 2 : 3) }
        default: return true
        }
    }

    /// The tiles sharing an edge with `tile`.
    public static func neighbours(_ tile: Int) -> [Int] {
        let n = size, x = tile % n, z = tile / n
        return [(x - 1, z), (x + 1, z), (x, z - 1), (x, z + 1)].filter { (0..<n).contains($0.0) && (0..<n).contains($0.1) }.map { $0.1 * n + $0.0 }
    }
}

/// A small deterministic generator (64-bit LCG with an xorshift output), so the island never depends on the system's random source.
public struct Rng {
    private var state: UInt64
    public init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    public mutating func bits() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
    /// Uniform in 0 ..< 1.
    public mutating func next() -> Double { Double(bits() >> 11) / Double(1 << 53) }
}

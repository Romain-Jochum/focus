import Foundation
import FocusCore

func gardenTests() {
    let garden = Garden()
    let again = Garden()
    check(garden.tiles == again.tiles && garden.steps == again.steps, "the same seed grows the same island")
    check(Garden(seed: 7).steps != garden.steps, "another seed, another island")
    let total = garden.tiles.reduce(0) { $0 + $1.destiny.stages }
    check(garden.steps.count == total, "every tile climbs all its stages, one step each")
    check((900...1050).contains(total), "about a thousand steps (\(total))")
    check(garden.stages(after: 0).allSatisfy { $0 == 0 }, "barren at first")
    check(zip(garden.stages(after: total), garden.tiles).allSatisfy { $0 == $1.destiny.stages }, "fully grown at the end")
    check(garden.steps.first == garden.spring, "the spring comes first")

    let counts = Dictionary(grouping: garden.tiles, by: \.destiny).mapValues(\.count)
    check(Destiny.allCases.allSatisfy { counts[$0, default: 0] > 0 }, "all four kinds of tile")
    check(counts[.forest, default: 0] >= 25 && counts[.meadow, default: 0] >= 35, "forest and meadow make most of it (\(counts))")
    let edge = garden.tiles[garden.stream.last!]
    check(edge.x == Garden.size - 1 && garden.stream.count >= 7, "the stream runs to the edge")
    check(zip(garden.stream, garden.stream.dropFirst()).allSatisfy { Garden.neighbours($0).contains($1) }, "the stream is continuous")

    // Replay: the green always touches green, water flows only from water.
    var stages = [Int](repeating: 0, count: garden.tiles.count)
    var connected = true, flows = true
    for tile in garden.steps {
        stages[tile] += 1
        let isStream = garden.tiles[tile].destiny == .stream
        if !isStream, stages[tile] == 3 {
            connected = connected && Garden.neighbours(tile).contains { stages[$0] >= (garden.tiles[$0].destiny == .stream ? 2 : 3) }
        }
        if isStream, stages[tile] == 2, let along = garden.stream.firstIndex(of: tile), along > 0 {
            flows = flows && stages[garden.stream[along - 1]] >= 2
        }
    }
    check(connected, "grass only grows next to green")
    check(flows, "water only flows from water")
    // The water comes first: each stream tile is dug, then filled, from the spring down to the edge, before anything else grows.
    let water = garden.stream.flatMap { [$0, $0] }
    check(Array(garden.steps.prefix(water.count)) == water, "the water runs to the edge before anything else grows")

    check(garden.stepCount(0) == 0 && garden.stepCount(1) == total && garden.stepCount(0.5) == total / 2, "growth maps onto the steps")
    // Pacing: the first session grows something, and growth stays visible all year.
    let first = garden.stepCount(Progression.growth(50))
    let lastLevel = Progression.xp(forLevel: 99)
    let late = garden.stepCount(Progression.growth(lastLevel + 120)) - garden.stepCount(Progression.growth(lastLevel))
    check(first >= 1, "a first perfect session grows at least one step (\(first))")
    check(late >= 1, "even at level 99, a long perfect session grows a step (\(late))")
}

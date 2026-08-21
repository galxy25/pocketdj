import XCTest
import AVFoundation
@testable import PocketDJ

/// The arpeggiator's PURE core (`ArpPattern`) — order permutations, octave replication, swing
/// timing, step math. No audio: the scheduling loop in `InstrumentEngine.startArpPlayback` is a
/// thin sleep-and-strike shell over exactly these functions, so pinning them here pins the arp.
final class ArpeggiatorTests: XCTestCase {

    /// Seeded deterministic RNG (SplitMix64) — the `.random` mode's injected generator.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func cycle(_ notes: [Int], _ order: ArpOrder, octaves: Int = 1,
                       seed: UInt64 = 1) -> [Int] {
        var rng: any RandomNumberGenerator = SeededRNG(seed: seed)
        return ArpPattern.cycle(notes: notes, order: order, octaves: octaves, rng: &rng)
    }

    // MARK: Orders

    func testUpDownAcrossOctaves() {
        XCTAssertEqual(cycle([64, 60, 67], .up), [60, 64, 67])
        XCTAssertEqual(cycle([64, 60, 67], .up, octaves: 2), [60, 64, 67, 72, 76, 79])
        XCTAssertEqual(cycle([64, 60, 67], .down), [67, 64, 60])
        XCTAssertEqual(cycle([64, 60, 67], .down, octaves: 2), [79, 76, 72, 67, 64, 60])
    }

    func testExclusiveOmitsRepeatedEndpoints() {
        XCTAssertEqual(cycle([60, 64, 67], .exclusive), [60, 64, 67, 64])
        XCTAssertEqual(cycle([60, 64], .exclusive), [60, 64], "n=2 has no interior")
        XCTAssertEqual(cycle([60], .exclusive), [60], "n=1 degenerates to the single note")
        // Period 2n−2 across octaves too: 6 pool notes → 10 steps.
        XCTAssertEqual(cycle([60, 64, 67], .exclusive, octaves: 2).count, 10)
    }

    func testInclusiveRepeatsEndpoints() {
        XCTAssertEqual(cycle([60, 64, 67], .inclusive), [60, 64, 67, 67, 64, 60])
        XCTAssertEqual(cycle([60], .inclusive), [60, 60], "n=1 repeats the endpoint")
    }

    func testOrderIsRecordedOrderReplicatedPerOctave() {
        XCTAssertEqual(cycle([67, 60, 64], .order), [67, 60, 64])
        XCTAssertEqual(cycle([67, 60, 64], .order, octaves: 2), [67, 60, 64, 79, 72, 76],
                       "octave replication preserves the played order")
    }

    func testRandomDrawsFromPoolDeterministicallySeeded() {
        let pool = Set(ArpPattern.pool(notes: [60, 64, 67], octaves: 2))
        let a = cycle([60, 64, 67], .random, octaves: 2, seed: 7)
        XCTAssertEqual(a.count, pool.count, "cycle length == pool size")
        XCTAssertTrue(a.allSatisfy { pool.contains($0) }, "every slot drawn from the pool")
        XCTAssertEqual(a, cycle([60, 64, 67], .random, octaves: 2, seed: 7),
                       "same seed ⇒ same cycle")
        var different = false
        for seed: UInt64 in 8...16 where cycle([60, 64, 67], .random, octaves: 2, seed: seed) != a {
            different = true
            break
        }
        XCTAssertTrue(different, "different seeds eventually differ")
    }

    func testOctaveReplicationClampsAbove127AndDedupes() {
        XCTAssertEqual(ArpPattern.pool(notes: [120], octaves: 4), [120],
                       "132/144/156 are out of MIDI range and dropped")
        XCTAssertEqual(ArpPattern.pool(notes: [120, 110], octaves: 2), [120, 110, 122],
                       "only the in-range octave-up survives")
        XCTAssertEqual(ArpPattern.pool(notes: [60, 72], octaves: 2), [60, 72, 84],
                       "the overlapping octave duplicate (72) appears once")
        XCTAssertEqual(ArpPattern.pool(notes: [60, 60, 64], octaves: 1), [60, 64],
                       "duplicate presses dedupe (first occurrence wins)")
    }

    // MARK: Swing timing

    func testSwingTiming() {
        // Straight (50%): onsets sit on the grid.
        for (k, want) in [0, 250, 500, 750].enumerated() {
            XCTAssertEqual(ArpPattern.onsetMs(step: k, stepMs: 250, swingPct: 50), want)
        }
        // Triplet-ish (66.7%): odd steps pushed to 2/3 of the pair.
        XCTAssertEqual(ArpPattern.onsetMs(step: 0, stepMs: 250, swingPct: 66.7), 0)
        XCTAssertEqual(Double(ArpPattern.onsetMs(step: 1, stepMs: 250, swingPct: 66.7)),
                       333.5, accuracy: 1.0)
        XCTAssertEqual(ArpPattern.onsetMs(step: 2, stepMs: 250, swingPct: 66.7), 500)
        XCTAssertEqual(Double(ArpPattern.onsetMs(step: 3, stepMs: 250, swingPct: 66.7)),
                       833.5, accuracy: 1.0)
        // Hard cap (75%).
        XCTAssertEqual(ArpPattern.onsetMs(step: 1, stepMs: 250, swingPct: 75), 375)
        XCTAssertEqual(ArpPattern.onsetMs(step: 3, stepMs: 250, swingPct: 75), 875)
        // Out-of-range swing input clamps to the 50…75 band.
        XCTAssertEqual(ArpPattern.onsetMs(step: 1, stepMs: 250, swingPct: 40),
                       ArpPattern.onsetMs(step: 1, stepMs: 250, swingPct: 50))
        XCTAssertEqual(ArpPattern.onsetMs(step: 1, stepMs: 250, swingPct: 90),
                       ArpPattern.onsetMs(step: 1, stepMs: 250, swingPct: 75))
        // The gate always releases BEFORE the next onset (never overlapping its successor).
        for swing in [50.0, 66.7, 75.0] {
            for k in 0..<8 {
                XCTAssertLessThan(ArpPattern.gateOffMs(step: k, stepMs: 250, swingPct: swing),
                                  ArpPattern.onsetMs(step: k + 1, stepMs: 250, swingPct: swing))
                XCTAssertGreaterThan(ArpPattern.gateOffMs(step: k, stepMs: 250, swingPct: swing),
                                     ArpPattern.onsetMs(step: k, stepMs: 250, swingPct: swing))
            }
        }
    }

    func testStepMsFromLengthAndBpm() {
        XCTAssertEqual(ArpPattern.stepMs(length: .sixteenth, bpm: 120), 125, accuracy: 0.001)
        XCTAssertEqual(ArpPattern.stepMs(length: .quarter, bpm: 120), 500, accuracy: 0.001)
        XCTAssertEqual(ArpPattern.stepMs(length: .eighth, bpm: 60), 500, accuracy: 0.001)
        XCTAssertEqual(ArpPattern.stepMs(length: .thirtysecond, bpm: 120), 62.5, accuracy: 0.001)
        // Degenerate bpm degrades to 120 (the barSeconds convention), never traps.
        XCTAssertEqual(ArpPattern.stepMs(length: .sixteenth, bpm: 0), 125, accuracy: 0.001)
        XCTAssertEqual(ArpPattern.stepMs(length: .sixteenth, bpm: .nan), 125, accuracy: 0.001)
        XCTAssertEqual(ArpPattern.stepMs(length: .sixteenth, bpm: -3), 125, accuracy: 0.001)
    }

    func testEmptyAndAllOutOfRangeSetsProduceEmptyCycles() {
        XCTAssertEqual(cycle([], .up), [])
        XCTAssertEqual(cycle([], .random), [])
        XCTAssertEqual(cycle([200, -5], .up), [], "out-of-range notes are dropped entirely")
    }
}

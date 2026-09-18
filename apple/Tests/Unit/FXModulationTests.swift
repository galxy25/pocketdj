import XCTest
@testable import PocketDJ

/// The FX modulation PURE layer — `SlotMod`/`ModRate`/`ModShape`, `FXParams` modulation math, and
/// `BeatMath.cyclePhase`. Runs with no audio device; this is the table the mod tick will trust, so
/// a wrong value here is a silently-wrong wobble on stage.
@MainActor
final class FXModulationTests: XCTestCase {

    // MARK: - Rates

    func testRateBeatsAreMusical() {
        XCTAssertEqual(ModRate.bar.beats, 4)
        XCTAssertEqual(ModRate.half.beats, 2)
        XCTAssertEqual(ModRate.quarter.beats, 1)
        XCTAssertEqual(ModRate.quarterTriplet.beats, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(ModRate.eighth.beats, 0.5)
        // The ceiling decision: nothing faster than 1/8 ships (see the enum doc).
        XCTAssertEqual(ModRate.allCases.map(\.beats).min(), 0.5)
    }

    // MARK: - Waves

    func testWaveShapesAtCanonicalPhases() {
        // sine: trough on the downbeat, rising.
        XCTAssertEqual(FXParams.wave(.sine, phase01: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.sine, phase01: 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.sine, phase01: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.sine, phase01: 0.75), 0.5, accuracy: 1e-9)
        // triangle
        XCTAssertEqual(FXParams.wave(.triangle, phase01: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.triangle, phase01: 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.triangle, phase01: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.triangle, phase01: 0.75), 0.5, accuracy: 1e-9)
        // saw FALLS from the downbeat; ramp rises.
        XCTAssertEqual(FXParams.wave(.saw, phase01: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.saw, phase01: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.ramp, phase01: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(FXParams.wave(.ramp, phase01: 0.75), 0.75, accuracy: 1e-9)
        // square gates the first half-cycle on.
        XCTAssertEqual(FXParams.wave(.square, phase01: 0.25), 1)
        XCTAssertEqual(FXParams.wave(.square, phase01: 0.75), 0)
    }

    func testEveryWaveStaysInUnitRangeAndWraps() {
        for shape in ModShape.allCases {
            for p in stride(from: -2.0, through: 3.0, by: 0.09) {
                let v = FXParams.wave(shape, phase01: p)
                XCTAssertTrue((0...1).contains(v), "\(shape) at \(p) left 0…1: \(v)")
                XCTAssertEqual(v, FXParams.wave(shape, phase01: p + 1), accuracy: 1e-9,
                               "\(shape) must be periodic in 1")
            }
        }
    }

    // MARK: - modulated(): the off ⇒ identity guarantee

    /// THE compatibility contract: modulation off (or zero depth) must return the base EXACTLY, so
    /// a non-modulated deck is byte-identical to the pre-modulation build.
    func testModulatedIsIdentityWhenOffOrZeroDepth() {
        for base in [0.0, 0.3, 0.5, 1.0] {
            XCTAssertEqual(FXParams.modulated(base: base, mod: SlotMod(), phase01: 0.7, env: 0.9),
                           base, accuracy: 0, "source .off must be the exact identity")
            var m = SlotMod(source: .lfo, depth: 0)
            XCTAssertEqual(FXParams.modulated(base: base, mod: m, phase01: 0.7, env: 0.9),
                           base, accuracy: 0, "zero depth must be the exact identity")
            m = SlotMod(source: .envelope, depth: 0)
            XCTAssertEqual(FXParams.modulated(base: base, mod: m, phase01: nil, env: 0.9),
                           base, accuracy: 0)
        }
    }

    /// An LFO with nothing to lock to (nil phase — no grid, no BPM) must not wobble on garbage.
    func testLFOWithNilPhaseIsIdentity() {
        let m = SlotMod(source: .lfo, depth: 0.8)
        XCTAssertEqual(FXParams.modulated(base: 0.4, mod: m, phase01: nil, env: 0.5), 0.4, accuracy: 0)
    }

    func testLFOIsBipolarAroundBase() {
        let m = SlotMod(source: .lfo, rate: .bar, depth: 0.3, shape: .sine)
        // sine at phase 0.5 = peak (wave 1 → offset +depth); at 0 = trough (offset −depth).
        XCTAssertEqual(FXParams.modulated(base: 0.5, mod: m, phase01: 0.5, env: 0), 0.8, accuracy: 1e-9)
        XCTAssertEqual(FXParams.modulated(base: 0.5, mod: m, phase01: 0.0, env: 0), 0.2, accuracy: 1e-9)
    }

    func testEnvelopeIsUnipolarAndSignedDepthDucks() {
        var m = SlotMod(source: .envelope, depth: 0.4)
        XCTAssertEqual(FXParams.modulated(base: 0.3, mod: m, phase01: nil, env: 1.0), 0.7, accuracy: 1e-9)
        XCTAssertEqual(FXParams.modulated(base: 0.3, mod: m, phase01: nil, env: 0.0), 0.3, accuracy: 1e-9)
        m = SlotMod(source: .envelope, depth: -0.4)   // negative depth DUCKS
        XCTAssertEqual(FXParams.modulated(base: 0.5, mod: m, phase01: nil, env: 1.0), 0.1, accuracy: 1e-9)
    }

    func testModulatedClampsAtBothRails() {
        let deep = SlotMod(source: .lfo, depth: 1, shape: .sine)
        XCTAssertEqual(FXParams.modulated(base: 0.9, mod: deep, phase01: 0.5, env: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(FXParams.modulated(base: 0.1, mod: deep, phase01: 0.0, env: 0), 0.0, accuracy: 1e-9)
        let duck = SlotMod(source: .envelope, depth: -1)
        XCTAssertEqual(FXParams.modulated(base: 0.2, mod: duck, phase01: nil, env: 1), 0.0, accuracy: 1e-9)
    }

    func testSlotModInitClampsAndFolds() {
        XCTAssertEqual(SlotMod(source: .lfo, depth: 7).depth, 1)
        XCTAssertEqual(SlotMod(source: .lfo, depth: -7).depth, -1)
        XCTAssertEqual(SlotMod(source: .lfo, phase: 1.25).phase, 0.25, accuracy: 1e-9)
        XCTAssertEqual(SlotMod(source: .lfo, phase: -0.25).phase, 0.75, accuracy: 1e-9)
    }

    // MARK: - The target table: what modulation may touch

    /// `delayTime` must NEVER be a modulation target (un-ramped read-pointer jump = clicks), and
    /// reverb/compressor are out of scope this phase. The table IS the enforcement.
    func testModulatesTableScopesTargets() {
        XCTAssertEqual(FXParams.modulates(.filter) != nil, true)
        XCTAssertEqual(FXParams.modulates(.flanger) != nil, true)
        XCTAssertNil(FXParams.modulates(.reverb), "reverb is out of scope this phase")
        XCTAssertNil(FXParams.modulates(.compressor), "compressor is out of scope this phase")
        if case .wetFeedback = FXParams.modulates(.flanger)! {} else {
            XCTFail("the modulation family target is wet/feedback — never delayTime")
        }
    }

    // MARK: - Envelope curve + ballistics

    func testEnvelopeCurveEndpointsAndMonotonicity() {
        XCTAssertEqual(FXParams.envelopeCurve(rms: 0), 0)
        XCTAssertEqual(FXParams.envelopeCurve(rms: 1.0), 1.0, accuracy: 1e-6)          // 0 dBFS
        XCTAssertEqual(FXParams.envelopeCurve(rms: 0.01), 0, accuracy: 1e-6)           // −40 dBFS
        XCTAssertEqual(FXParams.envelopeCurve(rms: 0.1), 0.5, accuracy: 1e-6)          // −20 dBFS (Float rms)
        var last = -1.0
        for rms in stride(from: 0.001, through: 1.0, by: 0.013) {
            let v = FXParams.envelopeCurve(rms: Float(rms))
            XCTAssertGreaterThanOrEqual(v, last, "envelope curve must be monotone")
            last = v
        }
    }

    /// The reason the ballistics are time-constant based: the SAME wall-time of signal, chopped
    /// into different callback sizes, must converge to the same envelope value.
    func testBallisticsAreBufferSizeIndependent() {
        func settle(bufFrames: Int, seconds: Double, tau: Double, target: Float) -> Float {
            let sr = 44_100.0
            let dt = Double(bufFrames) / sr
            let steps = Int((seconds / dt).rounded())
            var v: Float = 0
            let coef = FXParams.ballisticsCoef(dt: dt, tau: tau)
            for _ in 0..<steps { v += (target - v) * coef }
            return v
        }
        let small = settle(bufFrames: 1024, seconds: 0.5, tau: 0.18, target: 1)
        let large = settle(bufFrames: 4096, seconds: 0.5, tau: 0.18, target: 1)
        XCTAssertEqual(small, large, accuracy: 0.02,
                       "1024- and 4096-frame callbacks must converge identically in wall time")
        // And after ~5τ it should be essentially settled.
        XCTAssertGreaterThan(settle(bufFrames: 1024, seconds: 1.0, tau: 0.18, target: 1), 0.99)
    }

    // MARK: - FXSlot carries its mod

    func testSlotModSurvivesEffectAndVariantChanges() {
        var s = FXSlot(.filter)
        XCTAssertEqual(s.mod.source, .off, "default is off")
        s.mod = SlotMod(source: .lfo, rate: .quarter, depth: 0.7, shape: .saw, phase: 0.5)
        s.setVariant(.highPass)
        XCTAssertEqual(s.mod.rate, .quarter, "picking a variety must not reset the rhythm")
        s.setEffect(.flanger)
        XCTAssertEqual(s.mod.source, .lfo, "swapping the family keeps the modulation config")
        XCTAssertEqual(s.mod.phase, 0.5, accuracy: 1e-9)
    }

    // MARK: - cyclePhase

    /// A perfectly even measured grid, downbeats every 4 beats: phase ramps 0→1 across one bar
    /// and wraps.
    func testCyclePhaseRampsAcrossABarAndWraps() {
        let beats = (0..<32).map { $0 * 500 }              // 120 BPM, beat every 500 ms
        let downs = stride(from: 0, to: 16_000, by: 2_000).map { $0 }
        func ph(_ atMs: Double) -> Double? {
            BeatMath.cyclePhase(atMs: atMs, beatsMs: beats, downbeatsMs: downs,
                                bpm: 120, firstDownbeatMs: 0, cycleBeats: 4)
        }
        XCTAssertEqual(ph(0)!, 0, accuracy: 1e-9)
        XCTAssertEqual(ph(500)!, 0.25, accuracy: 1e-9)     // one beat into the bar
        XCTAssertEqual(ph(1_000)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ph(1_999)!, 0.9995, accuracy: 1e-3)
        XCTAssertEqual(ph(2_000)!, 0, accuracy: 1e-9,      "wraps on the next downbeat")
        // Monotone within a cycle.
        var last = -1.0
        for t in stride(from: 2_000.0, to: 3_999.0, by: 77) {
            let v = ph(t)!
            XCTAssertGreaterThan(v, last); last = v
        }
    }

    /// Downbeat anchoring: a grid whose downbeats do NOT start at beat 0 must still put phase 0 on
    /// the downbeat, not on the first beat.
    func testCyclePhaseAnchorsOnTheMeasuredDownbeat() {
        let beats = (0..<16).map { 1_000 + $0 * 500 }       // beats at 1000, 1500, …
        let downs = [2_000, 4_000, 6_000]                   // downbeats start at beat 2
        let p = BeatMath.cyclePhase(atMs: 2_000, beatsMs: beats, downbeatsMs: downs,
                                    bpm: 120, firstDownbeatMs: 0, cycleBeats: 4)!
        XCTAssertEqual(p, 0, accuracy: 1e-9, "phase 0 belongs to the DOWNBEAT")
        let q = BeatMath.cyclePhase(atMs: 2_500, beatsMs: beats, downbeatsMs: downs,
                                    bpm: 120, firstDownbeatMs: 0, cycleBeats: 4)!
        XCTAssertEqual(q, 0.25, accuracy: 1e-9)
    }

    /// Triplets: a 2/3-beat cycle puts exactly three cycles into two beats.
    func testCyclePhaseTriplets() {
        let beats = (0..<32).map { $0 * 500 }
        var wraps = 0
        var last = 0.0
        for t in stride(from: 0.0, to: 1_000.0, by: 5) {    // two beats
            let v = BeatMath.cyclePhase(atMs: t, beatsMs: beats, downbeatsMs: nil,
                                        bpm: 120, firstDownbeatMs: 0,
                                        cycleBeats: ModRate.quarterTriplet.beats)!
            if v < last - 0.5 { wraps += 1 }
            last = v
        }
        XCTAssertEqual(wraps, 2, "three triplet cycles in two beats ⇒ two wraps strictly inside")
    }

    /// A drifting (slowing) grid must yield CONTINUOUS phase — interpolation between real beats,
    /// no jumps at beat boundaries.
    func testCyclePhaseContinuousOnDriftingGrid() {
        var beats: [Int] = [0]
        var gap = 400.0
        for _ in 0..<24 { beats.append(beats.last! + Int(gap)); gap *= 1.03 }   // slowing down
        var last = -1.0
        var wraps = 0
        for t in stride(from: 0.0, to: Double(beats[16]), by: 9) {
            let v = BeatMath.cyclePhase(atMs: t, beatsMs: beats, downbeatsMs: nil,
                                        bpm: 0, firstDownbeatMs: 0, cycleBeats: 4)!
            if last >= 0 {
                let delta = v - last
                XCTAssertTrue(delta > -0.5 || delta < -0.9,
                              "phase may only move forward or wrap — got \(last)→\(v)")
                if delta < -0.5 { wraps += 1 }
            }
            last = v
        }
        XCTAssertGreaterThan(wraps, 0, "several bars elapsed — it must have wrapped")
    }

    /// Past the measured grid the phase extends on the grid's own spacing — continuous, no reset.
    func testCyclePhaseExtendsPastTheMeasuredGrid() {
        let beats = (0..<8).map { $0 * 500 }               // grid ends at 3500 ms
        let inside = BeatMath.cyclePhase(atMs: 3_400, beatsMs: beats, downbeatsMs: nil,
                                         bpm: 120, firstDownbeatMs: 0, cycleBeats: 4)!
        let outside = BeatMath.cyclePhase(atMs: 3_600, beatsMs: beats, downbeatsMs: nil,
                                          bpm: 120, firstDownbeatMs: 0, cycleBeats: 4)!
        // 200 ms at 120 BPM = 0.4 beats = 0.1 cycle of a bar.
        let expected = (inside + 0.1).truncatingRemainder(dividingBy: 1)
        XCTAssertEqual(outside, expected, accuracy: 0.01, "extension must be phase-continuous")
    }

    /// Grid-less: the synthesized lattice anchors at firstDownbeatMs, and tracks before it still
    /// phase correctly (an intro before beat 0 wobbles in time).
    func testCyclePhaseSynthesizedFallback() {
        let atDown = BeatMath.cyclePhase(atMs: 10_000, beatsMs: nil, downbeatsMs: nil,
                                         bpm: 120, firstDownbeatMs: 10_000, cycleBeats: 4)!
        XCTAssertEqual(atDown, 0, accuracy: 1e-9)
        let oneBeatLater = BeatMath.cyclePhase(atMs: 10_500, beatsMs: nil, downbeatsMs: nil,
                                               bpm: 120, firstDownbeatMs: 10_000, cycleBeats: 4)!
        XCTAssertEqual(oneBeatLater, 0.25, accuracy: 1e-9)
        let beforeAnchor = BeatMath.cyclePhase(atMs: 9_500, beatsMs: nil, downbeatsMs: nil,
                                               bpm: 120, firstDownbeatMs: 10_000, cycleBeats: 4)!
        XCTAssertEqual(beforeAnchor, 0.75, accuracy: 1e-9, "pre-anchor time folds positively")
    }

    func testCyclePhaseNilWhenNothingToLockTo() {
        XCTAssertNil(BeatMath.cyclePhase(atMs: 1_000, beatsMs: nil, downbeatsMs: nil,
                                         bpm: 0, firstDownbeatMs: 0, cycleBeats: 4))
        XCTAssertNil(BeatMath.cyclePhase(atMs: 1_000, beatsMs: [], downbeatsMs: nil,
                                         bpm: 0, firstDownbeatMs: 0, cycleBeats: 4))
        XCTAssertNil(BeatMath.cyclePhase(atMs: 1_000, beatsMs: [0, 500], downbeatsMs: nil,
                                         bpm: 120, firstDownbeatMs: 0, cycleBeats: 0),
                     "a zero-length cycle is meaningless")
    }

    func testCyclePhaseOffsetShiftsExactly() {
        let beats = (0..<16).map { $0 * 500 }
        let base = BeatMath.cyclePhase(atMs: 1_000, beatsMs: beats, downbeatsMs: nil,
                                       bpm: 120, firstDownbeatMs: 0, cycleBeats: 4)!
        let shifted = BeatMath.cyclePhase(atMs: 1_000, beatsMs: beats, downbeatsMs: nil,
                                          bpm: 120, firstDownbeatMs: 0, cycleBeats: 4, offset: 0.5)!
        XCTAssertEqual(shifted, (base + 0.5).truncatingRemainder(dividingBy: 1), accuracy: 1e-9)
    }
}

import XCTest
@testable import PocketDJ

/// AutoTransition — the shared, pure Auto-DJ transition decisions (Mix tab + Now Playing DJ Mode):
/// timing plan, equal-power curve, phase align, glide params, texture roll.
@MainActor
final class AutoTransitionTests: XCTestCase {

    // MARK: - Timing plan (advance)

    /// Plenty of runway, glide off: the configured fade, no pre/post-roll, nothing to restore.
    func testAdvancePlanNormalNoGlide() {
        let p = AutoTransition.advancePlan(secondsLeft: 15, fadeSeconds: 3, glideSeconds: 10,
                                           fxGlide: false, mixGlide: false)
        XCTAssertFalse(p.isGlide)
        XCTAssertEqual(p.fadeSeconds, 3)
        XCTAssertEqual(p.preRollSeconds, 0)
        XCTAssertEqual(p.postRollSeconds, 0)
        XCTAssertNil(p.fadeRestore)
        XCTAssertFalse(p.hasPreRoll)
        XCTAssertFalse(p.hasPostRoll)
    }

    /// Mix Glide on: the pre-roll fits the runway divided by the 1.12 tempo headroom, minus the fade
    /// and the 0.3 s margin, capped at the glide length.
    func testAdvancePlanMixGlideUsesHeadroom() {
        // 15/1.12 − 3 − 0.3 = 10.093 → capped at glide 10.
        let full = AutoTransition.advancePlan(secondsLeft: 15, fadeSeconds: 3, glideSeconds: 10,
                                              fxGlide: false, mixGlide: true)
        XCTAssertTrue(full.isGlide)
        XCTAssertEqual(full.preRollSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(full.postRollSeconds, 10)
        XCTAssertTrue(full.hasPreRoll)
        XCTAssertTrue(full.hasPostRoll)
        // 10/1.12 − 3 − 0.3 = 5.6286 (runway-limited).
        let fit = AutoTransition.advancePlan(secondsLeft: 10, fadeSeconds: 3, glideSeconds: 10,
                                             fxGlide: false, mixGlide: true)
        XCTAssertEqual(fit.preRollSeconds, 10 / 1.12 - 3 - 0.3, accuracy: 1e-9)
    }

    /// FX Glide only (no tempo bend): headroom 1.0.
    func testAdvancePlanFxGlideOnlyHasNoHeadroom() {
        let p = AutoTransition.advancePlan(secondsLeft: 10, fadeSeconds: 3, glideSeconds: 10,
                                           fxGlide: true, mixGlide: false)
        XCTAssertTrue(p.isGlide)
        XCTAssertEqual(p.preRollSeconds, 10 - 3 - 0.3, accuracy: 1e-9)
        XCTAssertEqual(AutoTransition.headroom(mixGlide: false), 1.0)
        XCTAssertEqual(AutoTransition.headroom(mixGlide: true), 1.12)
    }

    /// A short runway caps the fade to max(0.5, secondsLeft) and plans a restore of the baseline.
    func testAdvancePlanShortRunwayCapsFade() {
        let p = AutoTransition.advancePlan(secondsLeft: 2, fadeSeconds: 3, glideSeconds: 10,
                                           fxGlide: false, mixGlide: false)
        XCTAssertEqual(p.fadeSeconds, 2)
        XCTAssertEqual(p.fadeRestore, 3)
        let tiny = AutoTransition.advancePlan(secondsLeft: 0.1, fadeSeconds: 3, glideSeconds: 10,
                                              fxGlide: false, mixGlide: false)
        XCTAssertEqual(tiny.fadeSeconds, 0.5, "floored at 0.5 s")
        XCTAssertEqual(tiny.fadeRestore, 3)
    }

    /// An already-pending one-off override is neither re-capped nor re-restored.
    func testAdvancePlanRespectsPendingOverride() {
        let p = AutoTransition.advancePlan(secondsLeft: 2, fadeSeconds: 3, glideSeconds: 10,
                                           fxGlide: false, mixGlide: false, fadeOverridePending: true)
        XCTAssertEqual(p.fadeSeconds, 3)
        XCTAssertNil(p.fadeRestore)
    }

    /// The pre-roll never goes negative when the runway is shorter than fade + margin.
    func testAdvancePlanPreRollClampsAtZero() {
        for left in [0.0, 0.2, 1, 2, 3.2] {
            let p = AutoTransition.advancePlan(secondsLeft: left, fadeSeconds: 3, glideSeconds: 10,
                                               fxGlide: true, mixGlide: true)
            XCTAssertGreaterThanOrEqual(p.preRollSeconds, 0, "left=\(left)")
            XCTAssertFalse(p.hasPreRoll, "left=\(left) leaves no room for a pre-roll")
        }
        let zeroGlide = AutoTransition.advancePlan(secondsLeft: 30, fadeSeconds: 3, glideSeconds: 0,
                                                   fxGlide: true, mixGlide: true)
        XCTAssertEqual(zeroGlide.preRollSeconds, 0)
        XCTAssertFalse(zeroGlide.hasPostRoll, "glide length 0 ⇒ no post-roll ramp")
    }

    // MARK: - Timing plan (immediate)

    func testImmediatePlanSkipFade() {
        let p = AutoTransition.immediatePlan(fadeSeconds: 1, baselineFadeSeconds: 3, glideSeconds: 10,
                                             fxGlide: false, mixGlide: true)
        XCTAssertTrue(p.isGlide)
        XCTAssertEqual(p.preRollSeconds, 0, "skip = advance now, no pre-roll")
        XCTAssertEqual(p.fadeSeconds, 1)
        XCTAssertEqual(p.fadeRestore, 3)
        XCTAssertEqual(p.postRollSeconds, 10)
        let floored = AutoTransition.immediatePlan(fadeSeconds: 0, baselineFadeSeconds: 3, glideSeconds: 10,
                                                   fxGlide: false, mixGlide: false)
        XCTAssertEqual(floored.fadeSeconds, 0.2)
        XCTAssertEqual(floored.postRollSeconds, 0)
        let pending = AutoTransition.immediatePlan(fadeSeconds: 1, baselineFadeSeconds: 3, glideSeconds: 10,
                                                   fxGlide: false, mixGlide: false, fadeOverridePending: true)
        XCTAssertNil(pending.fadeRestore)
    }

    func testLeadWindow() {
        XCTAssertTrue(AutoTransition.inLeadWindow(secondsLeft: 15, lead: 15))
        XCTAssertTrue(AutoTransition.inLeadWindow(secondsLeft: 3, lead: 15))
        XCTAssertFalse(AutoTransition.inLeadWindow(secondsLeft: 15.1, lead: 15))
    }

    // MARK: - Equal-power curve

    func testEqualPowerEndpointsAndMidpoint() {
        let start = AutoTransition.equalPowerGains(progress: 0)
        XCTAssertEqual(start.outgoing, 1, accuracy: 1e-6)
        XCTAssertEqual(start.incoming, 0, accuracy: 1e-6)
        let end = AutoTransition.equalPowerGains(progress: 1)
        XCTAssertEqual(end.outgoing, 0, accuracy: 1e-6)
        XCTAssertEqual(end.incoming, 1, accuracy: 1e-6)
        let mid = AutoTransition.equalPowerGains(progress: 0.5)
        XCTAssertEqual(mid.outgoing, Float(0.5.squareRoot()), accuracy: 1e-6, "−3 dB each at the midpoint")
        XCTAssertEqual(mid.incoming, mid.outgoing, accuracy: 1e-6)
        for i in 0...20 {
            let g = AutoTransition.equalPowerGains(progress: Float(i) / 20)
            XCTAssertEqual(g.outgoing * g.outgoing + g.incoming * g.incoming, 1, accuracy: 1e-5,
                           "constant power")
        }
    }

    // MARK: - Phase align

    /// Both playheads past their downbeats: the offset never exceeds half an incoming beat, and
    /// applying it lands the incoming beat phase on the outgoing's.
    func testPhaseAlignOffsetBoundedByHalfBeat() {
        let out = AutoTransition.BeatRef(bpm: 128, firstDownbeatMs: 250)
        let inc = AutoTransition.BeatRef(bpm: 120, firstDownbeatMs: 400)
        let incBeat = 60.0 / 120
        for i in 0..<200 {
            let outPos = 30 + Double(i) * 0.037
            let incPos = 1 + Double(i) * 0.011
            let off = AutoTransition.phaseAlignOffset(outgoing: out, outgoingPosition: outPos,
                                                      incoming: inc, incomingPosition: incPos)
            XCTAssertLessThanOrEqual(abs(off), incBeat / 2 + 1e-9)
            let lead = AutoTransition.beatPhase(out, at: outPos)!.phase
            let after = AutoTransition.beatPhase(inc, at: incPos + off)!.phase
            var d = (lead - after).truncatingRemainder(dividingBy: 1)
            if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
            XCTAssertEqual(d, 0, accuracy: 1e-6, "phases agree after the offset")
        }
    }

    func testPhaseAlignMissingBpmIsZero() {
        let known = AutoTransition.BeatRef(bpm: 120, firstDownbeatMs: 0)
        let unknown = AutoTransition.BeatRef(bpm: nil, firstDownbeatMs: 300)
        XCTAssertEqual(AutoTransition.phaseAlignOffset(outgoing: known, outgoingPosition: 10.13,
                                                       incoming: unknown, incomingPosition: 0.4), 0)
        XCTAssertEqual(AutoTransition.phaseAlignOffset(outgoing: unknown, outgoingPosition: 10.13,
                                                       incoming: known, incomingPosition: 0.4), 0)
        XCTAssertEqual(AutoTransition.phaseAlignOffset(outgoing: .init(bpm: 0), outgoingPosition: 10.13,
                                                       incoming: known, incomingPosition: 0.4), 0)
    }

    /// A missing downbeat is beat-0 at the song start (identical to an explicit 0).
    func testPhaseAlignMissingDownbeatTreatsAsZero() {
        let outNil = AutoTransition.BeatRef(bpm: 128), incNil = AutoTransition.BeatRef(bpm: 120)
        let out0 = AutoTransition.BeatRef(bpm: 128, firstDownbeatMs: 0)
        let inc0 = AutoTransition.BeatRef(bpm: 120, firstDownbeatMs: 0)
        let a = AutoTransition.phaseAlignOffset(outgoing: outNil, outgoingPosition: 42.3,
                                                incoming: incNil, incomingPosition: 0.7)
        let b = AutoTransition.phaseAlignOffset(outgoing: out0, outgoingPosition: 42.3,
                                                incoming: inc0, incomingPosition: 0.7)
        XCTAssertEqual(a, b)
        // Hand-computed: lead phase (42.3/0.46875) mod 1 = 0.24, follower (0.7/0.5) mod 1 = 0.4
        // → delta −0.16 beat × 0.5 s = −0.08 s.
        XCTAssertEqual(a, -0.08, accuracy: 1e-9)
    }

    /// The ms variant is the seconds variant scaled.
    func testPhaseAlignOffsetMsMatchesSeconds() {
        let out = AutoTransition.BeatRef(bpm: 126, firstDownbeatMs: 120)
        let inc = AutoTransition.BeatRef(bpm: 124, firstDownbeatMs: 80)
        let s = AutoTransition.phaseAlignOffset(outgoing: out, outgoingPosition: 61.234,
                                                incoming: inc, incomingPosition: 2.5)
        let ms = AutoTransition.phaseAlignOffsetMs(outgoing: out, outgoingPositionMs: 61_234,
                                                   incoming: inc, incomingPositionMs: 2_500)
        XCTAssertEqual(ms, s * 1000, accuracy: 1e-6)
    }

    /// The incoming just started BEFORE its first downbeat: the preserved Mix math keeps the offset
    /// forward-going (never more than one beat) so a `max(0, …)` seek doesn't swallow it.
    func testPhaseAlignBeforeDownbeatStaysWithinOneBeat() {
        let out = AutoTransition.BeatRef(bpm: 120, firstDownbeatMs: 0)
        let inc = AutoTransition.BeatRef(bpm: 120, firstDownbeatMs: 450)
        for i in 0..<50 {
            let outPos = 60 + Double(i) * 0.01
            let off = AutoTransition.phaseAlignOffset(outgoing: out, outgoingPosition: outPos,
                                                      incoming: inc, incomingPosition: 0)
            XCTAssertGreaterThan(off, -0.25 - 1e-9)
            XCTAssertLessThan(off, 0.5)
        }
    }

    /// A measured grid that brackets the playhead is used instead of the BPM lattice.
    func testBeatPhaseUsesGridWhenItBrackets() {
        // A drifting grid: beats at 0, 500, 1100, 1600 ms.
        let ref = AutoTransition.BeatRef(bpm: 120, firstDownbeatMs: 0, beatsMs: [0, 500, 1100, 1600])
        let p = AutoTransition.beatPhase(ref, at: 0.8)!
        XCTAssertEqual(p.phase, 0.5, accuracy: 1e-9, "halfway between 500 and 1100")
        XCTAssertEqual(p.beatSeconds, 0.6, accuracy: 1e-9)
        // Outside the grid → BPM lattice.
        let after = AutoTransition.beatPhase(ref, at: 2.25)!
        XCTAssertEqual(after.phase, 0.5, accuracy: 1e-9)
        XCTAssertEqual(after.beatSeconds, 0.5, accuracy: 1e-9)
        XCTAssertNil(AutoTransition.beatPhase(.init(bpm: nil, beatsMs: [0, 500]), at: 0.2),
                     "no BPM ⇒ no phase even with a grid")
    }

    // MARK: - Glide params (missing data)

    func testGlideParamsMissingBpmOrKey() {
        // Key only: pitch bend, no tempo.
        let keyOnly = AutoTransition.glideParams(fromCamelot: "8A", toCamelot: "9A", fromBPM: nil, toBPM: 124)
        XCTAssertEqual(keyOnly.outRate, 1); XCTAssertEqual(keyOnly.inRate, 1)
        XCTAssertEqual(keyOnly.outPitch, AutoTransition.semitonesPerKey * 0.5, accuracy: 1e-9)
        XCTAssertEqual(keyOnly.inPitch, -AutoTransition.semitonesPerKey * 0.5, accuracy: 1e-9)
        // BPM only: tempo split, no pitch.
        let bpmOnly = AutoTransition.glideParams(fromCamelot: nil, toCamelot: "9A", fromBPM: 120, toBPM: 130)
        XCTAssertEqual(bpmOnly.outPitch, 0); XCTAssertEqual(bpmOnly.inPitch, 0)
        XCTAssertEqual(120 * bpmOnly.outRate, 130 * bpmOnly.inRate, accuracy: 1e-6)
        // Neither: identity.
        let none = AutoTransition.glideParams(fromCamelot: nil, toCamelot: nil, fromBPM: nil, toBPM: nil)
        XCTAssertTrue(none == AutoTransition.identityGlide)
        // Zero BPM counts as missing.
        let zero = AutoTransition.glideParams(fromCamelot: nil, toCamelot: nil, fromBPM: 0, toBPM: 120)
        XCTAssertTrue(zero == AutoTransition.identityGlide)
    }

    // MARK: - Ramps

    func testGlideRampsEndpoints() {
        let o0 = AutoTransition.outgoingRamp(0, outRate: 1.05, outPitch: 1.6, fxPeak: 0.7)
        XCTAssertEqual(o0.rate, 1); XCTAssertEqual(o0.pitch, 0); XCTAssertEqual(o0.fxStrength, 0)
        let o1 = AutoTransition.outgoingRamp(1, outRate: 1.05, outPitch: 1.6, fxPeak: 0.7)
        XCTAssertEqual(o1.rate, 1.05, accuracy: 1e-12); XCTAssertEqual(o1.pitch, 1.6)
        XCTAssertEqual(o1.fxStrength, 0.7)
        let i0 = AutoTransition.incomingRamp(0, inRate: 0.95, inPitch: -1.6, fxPeak: 0.7)
        XCTAssertEqual(i0.rate, 0.95); XCTAssertEqual(i0.pitch, -1.6); XCTAssertEqual(i0.fxStrength, 0.7)
        let i1 = AutoTransition.incomingRamp(1, inRate: 0.95, inPitch: -1.6, fxPeak: 0.7)
        XCTAssertEqual(i1.rate, 1, accuracy: 1e-12); XCTAssertEqual(i1.pitch, 0, accuracy: 1e-12)
        XCTAssertEqual(i1.fxStrength, 0)
    }

    // MARK: - Texture

    /// The texture pool's raw values map 1:1 onto the Mix deck's effects (no compressor).
    func testTexturePoolMapsOntoMixEffects() {
        XCTAssertEqual(AutoTransition.texturePool.map(\.rawValue), ["filter", "reverb", "flanger"])
        XCTAssertEqual(AutoTransition.texturePool.map(\.rawValue),
                       MixEngine.fxGlidePool.map(\.rawValue), "Mix pool forwards the shared one in order")
    }

    func testFxSeedMatchesMixAdapter() {
        let items = [MixEngine.AutoMixItem(
            loadable: MixLoadable(songId: "song-a", title: "T", artist: "A", bpm: 120,
                                  camelot: nil, key: nil, albumId: nil, lengthMs: 1000),
            durationMs: 1000)]
        XCTAssertEqual(AutoTransition.fxSeed(firstSongId: "song-a", count: 1), MixEngine.fxSeed(from: items))
        XCTAssertEqual(AutoTransition.fxSeed(firstSongId: nil, count: 0), MixEngine.fxSeed(from: []))
    }
}

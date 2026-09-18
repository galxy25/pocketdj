import XCTest
import AVFoundation
@testable import PocketDJ

/// The FX rack's PURE layer — `EffectVariant` / `FXSlot` / `FXParams`. Every assertion here runs
/// with no audio device and no engine instance: this is the table that `MixEngine.applySlot`
/// writes onto real nodes, so getting it wrong is silent (a variant that sounds like another one).
@MainActor
final class FXRackTests: XCTestCase {

    // MARK: - Variant ↔ family invariants

    /// Every variant belongs to exactly one family, and the families partition the variants —
    /// no variant is orphaned (unreachable from any menu) or double-counted.
    func testVariantsPartitionExactlyAcrossFamilies() {
        var seen: [EffectVariant] = []
        for e in MixEngine.Effect.allCases {
            let vs = EffectVariant.all(for: e)
            XCTAssertFalse(vs.isEmpty, "\(e) has no variants — its menu would be empty")
            for v in vs { XCTAssertEqual(v.effect, e) }
            seen.append(contentsOf: vs)
        }
        XCTAssertEqual(Set(seen).count, EffectVariant.allCases.count,
                       "every variant must be reachable from exactly one family menu")
        XCTAssertEqual(seen.count, EffectVariant.allCases.count, "a variant is listed under two families")
    }

    func testDefaultVariantBelongsToItsFamily() {
        for e in MixEngine.Effect.allCases {
            let d = EffectVariant.default(for: e)
            XCTAssertEqual(d.effect, e)
            XCTAssertTrue(EffectVariant.all(for: e).contains(d), "the default must be offered in the menu")
        }
    }

    /// The defaults are the compatibility contract: a fresh rack must sound like the PRE-RACK build.
    func testDefaultsReproducePreRackBehaviour() {
        XCTAssertEqual(EffectVariant.default(for: .compressor), .punch)
        XCTAssertEqual(EffectVariant.default(for: .reverb), .hall)      // was .mediumHall at build
        XCTAssertEqual(EffectVariant.default(for: .flanger), .flange)   // was the 4 ms comb
        XCTAssertEqual(EffectVariant.default(for: .filter), .lowPass)
    }

    func testVariantRawValuesRoundTrip() {
        for v in EffectVariant.allCases {
            XCTAssertEqual(EffectVariant(rawValue: v.rawValue), v)
        }
    }

    // MARK: - FXSlot invariants

    func testSlotInitDefaultsVariantToItsFamily() {
        XCTAssertEqual(FXSlot(.reverb).variant, .hall)
        XCTAssertEqual(FXSlot(.filter).variant, .lowPass)
    }

    /// A corrupt/hand-edited session must never be able to build a slot whose variant belongs to
    /// another family — it falls back to the default instead of trapping.
    func testSlotInitRejectsCrossFamilyVariant() {
        let s = FXSlot(.reverb, variant: .highPass)
        XCTAssertEqual(s.effect, .reverb)
        XCTAssertEqual(s.variant, .hall, "a filter variant on a reverb slot must fall back to the default")
    }

    func testSetEffectResetsVariantToNewFamilyDefault() {
        var s = FXSlot(.filter, variant: .highPass)
        XCTAssertEqual(s.variant, .highPass)
        s.setEffect(.reverb)
        XCTAssertEqual(s.effect, .reverb)
        XCTAssertEqual(s.variant, .hall, "keeping .highPass on a reverb slot would break the invariant")
    }

    func testSetEffectToSameFamilyKeepsVariant() {
        var s = FXSlot(.filter, variant: .bandPass)
        s.setEffect(.filter)
        XCTAssertEqual(s.variant, .bandPass, "re-picking the same family must not reset a chosen variety")
    }

    func testSetVariantAcceptsSameFamilyRejectsOther() {
        var s = FXSlot(.filter)
        s.setVariant(.highPass)
        XCTAssertEqual(s.variant, .highPass)
        s.setVariant(.cathedral)                    // cross-family — ignored
        XCTAssertEqual(s.variant, .highPass)
    }

    func testSlotStrengthClamps() {
        var s = FXSlot(.reverb)
        s.setStrength(1.7);  XCTAssertEqual(s.strength, 1.0, accuracy: 1e-9)
        s.setStrength(-0.4); XCTAssertEqual(s.strength, 0.0, accuracy: 1e-9)
        s.setStrength(0.66); XCTAssertEqual(s.strength, 0.66, accuracy: 1e-9)
        XCTAssertEqual(FXSlot(.reverb, strength: 9).strength, 1.0, accuracy: 1e-9)
    }

    // MARK: - Filter params (LP/HP must match the pre-rack curves EXACTLY)

    func testLowPassCurveMatchesPreRack() {
        XCTAssertEqual(FXParams.filterFrequency(.lowPass, 0), 18_000, accuracy: 1)
        XCTAssertEqual(FXParams.filterFrequency(.lowPass, 1), 250, accuracy: 1)
        XCTAssertEqual(FXParams.filterFrequency(.lowPass, 0.5),
                       Float(18_000 * pow(250.0 / 18_000.0, 0.5)), accuracy: 1)
    }

    func testHighPassCurveMatchesPreRack() {
        XCTAssertEqual(FXParams.filterFrequency(.highPass, 0), 30, accuracy: 0.5)
        XCTAssertEqual(FXParams.filterFrequency(.highPass, 1), 2_000, accuracy: 1)
        XCTAssertEqual(FXParams.filterFrequency(.highPass, 0.5),
                       Float(30.0 * pow(2_000.0 / 30.0, 0.5)), accuracy: 1)
    }

    /// LP sweeps DOWN and HP sweeps UP as strength rises — the two build directions. If these ever
    /// invert, the filter does the opposite of what the DJ expects mid-mix.
    func testFilterSweepDirections() {
        XCTAssertGreaterThan(FXParams.filterFrequency(.lowPass, 0), FXParams.filterFrequency(.lowPass, 1))
        XCTAssertLessThan(FXParams.filterFrequency(.highPass, 0), FXParams.filterFrequency(.highPass, 1))
        XCTAssertGreaterThan(FXParams.filterFrequency(.bandPass, 0), FXParams.filterFrequency(.bandPass, 1))
    }

    func testBandPassNarrowsWithStrength() {
        XCTAssertGreaterThan(FXParams.filterBandwidth(.bandPass, 0), FXParams.filterBandwidth(.bandPass, 1))
        // LP/HP keep the pre-rack fixed bandwidth.
        XCTAssertEqual(FXParams.filterBandwidth(.lowPass, 0.3), 0.5, accuracy: 1e-6)
        XCTAssertEqual(FXParams.filterBandwidth(.highPass, 0.9), 0.5, accuracy: 1e-6)
    }

    func testFilterFrequenciesStayAudibleAcrossTheSweep() {
        for v in EffectVariant.all(for: .filter) {
            for s in stride(from: 0.0, through: 1.0, by: 0.1) {
                let f = FXParams.filterFrequency(v, s)
                XCTAssertGreaterThan(f, 20, "\(v) at \(s) dropped below audible")
                XCTAssertLessThan(f, 20_000, "\(v) at \(s) exceeded audible")
            }
        }
    }

    func testFilterTypesAreDistinctPerVariant() {
        XCTAssertEqual(FXParams.filterType(.lowPass), .resonantLowPass)
        XCTAssertEqual(FXParams.filterType(.highPass), .resonantHighPass)
        XCTAssertEqual(FXParams.filterType(.bandPass), .bandPass)
    }

    // MARK: - Reverb presets

    func testReverbPresetsAreDistinctAndHallIsPreRack() {
        XCTAssertEqual(FXParams.reverbPreset(.hall), .mediumHall, "the pre-rack build-time preset")
        let presets = EffectVariant.all(for: .reverb).map { FXParams.reverbPreset($0).rawValue }
        XCTAssertEqual(Set(presets).count, presets.count, "two reverb variants map to the same preset")
    }

    // MARK: - Modulation params

    func testModulationDelayTimesAreOrderedAndDistinct() {
        // Flanger (short comb) < Chorus (detune) < Echo (discrete repeats) at any strength.
        for s in [0.0, 0.5, 1.0] {
            let fl = FXParams.modDelayTime(.flange, s)
            let ch = FXParams.modDelayTime(.chorus, s)
            let ec = FXParams.modDelayTime(.echo, s)
            XCTAssertLessThan(fl, ch, "flanger must stay a shorter comb than chorus at s=\(s)")
            XCTAssertLessThan(ch, ec, "chorus must stay shorter than echo at s=\(s)")
        }
    }

    func testFlangerReproducesPreRackValues() {
        XCTAssertEqual(FXParams.modDelayTime(.flange, 0.5), 0.004, accuracy: 1e-9)
        XCTAssertEqual(FXParams.modFeedback(.flange, 1.0), 60, accuracy: 1e-4)
        XCTAssertEqual(FXParams.modWetDryMix(.flange, 1.0), 50, accuracy: 1e-4)
        XCTAssertEqual(FXParams.modLowPassCutoff(.flange), 15_000, accuracy: 1)
    }

    func testEchoStaysInItsDesignRange() {
        XCTAssertEqual(FXParams.modDelayTime(.echo, 0), 0.15, accuracy: 1e-9)
        XCTAssertEqual(FXParams.modDelayTime(.echo, 1), 0.50, accuracy: 1e-9)
        // Echo needs the most feedback (audible repeats); chorus the least (thicken, don't ring).
        XCTAssertGreaterThan(FXParams.modFeedback(.echo, 1), FXParams.modFeedback(.flange, 1))
        XCTAssertLessThan(FXParams.modFeedback(.chorus, 1), FXParams.modFeedback(.flange, 1))
    }

    func testModulationParamsStayInAUValidRanges() {
        for v in EffectVariant.all(for: .flanger) {
            for s in stride(from: 0.0, through: 1.0, by: 0.1) {
                XCTAssertTrue((0...2).contains(FXParams.modDelayTime(v, s)), "\(v) delayTime out of AU range")
                XCTAssertTrue((-100...100).contains(FXParams.modFeedback(v, s)), "\(v) feedback out of AU range")
                XCTAssertTrue((0...100).contains(FXParams.modWetDryMix(v, s)), "\(v) wetDryMix out of AU range")
            }
        }
    }

    // MARK: - Compressor params

    func testPunchReproducesPreRackCurve() {
        for s in [0.0, 0.33, 0.5, 1.0] {
            XCTAssertEqual(FXParams.compThreshold(.punch, s), Float(-30 * s), accuracy: 1e-4)
            XCTAssertEqual(FXParams.compMakeup(.punch, s), Float(15 * s), accuracy: 1e-4)
        }
    }

    /// The variants must actually behave like their names: Limit clamps fastest and hardest,
    /// Glue is the slowest/softest, Punch sits between.
    func testCompressorVariantCharacters() {
        XCTAssertLessThan(FXParams.compAttack(.limit), FXParams.compAttack(.punch),
                          "Limit must catch peaks faster than Punch")
        XCTAssertLessThan(FXParams.compAttack(.punch), FXParams.compAttack(.glue))
        XCTAssertGreaterThan(FXParams.compRelease(.glue), FXParams.compRelease(.punch),
                             "Glue must ride longer than Punch")
        XCTAssertLessThan(FXParams.compHeadRoom(.limit), FXParams.compHeadRoom(.punch),
                          "Limit must have the hardest knee")
        XCTAssertGreaterThan(FXParams.compHeadRoom(.glue), FXParams.compHeadRoom(.punch),
                             "Glue must have the softest knee")
    }

    func testCompressorParamsArePositiveAndSane() {
        for v in EffectVariant.all(for: .compressor) {
            XCTAssertGreaterThan(FXParams.compAttack(v), 0, "\(v) attack must be > 0")
            XCTAssertGreaterThan(FXParams.compRelease(v), 0, "\(v) release must be > 0")
            XCTAssertGreaterThan(FXParams.compHeadRoom(v), 0, "\(v) headroom must be > 0")
            XCTAssertLessThanOrEqual(FXParams.compThreshold(v, 1), 0, "\(v) threshold must not go positive")
            XCTAssertGreaterThanOrEqual(FXParams.compMakeup(v, 0), 0, "\(v) makeup must not go negative")
        }
    }

    // MARK: - Labels (they're the chip face — an empty one is a blank button)

    func testEveryVariantHasNonEmptyLabels() {
        for v in EffectVariant.allCases {
            XCTAssertFalse(v.label.isEmpty, "\(v) has no chip label")
            XCTAssertFalse(v.longLabel.isEmpty, "\(v) has no menu label")
        }
    }
}

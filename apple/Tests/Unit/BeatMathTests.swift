import XCTest
@testable import PocketDJ

/// Pure beat-grid math (Support/BeatMath.swift) — the binary searches extracted from
/// MixView's beat pulse + the Studio loop slicer (spec §5). Hermetic: fixed grids only.
final class BeatMathTests: XCTestCase {

    // MARK: lastBeat — binary-search edges

    func testLastBeatBeforeFirstBeatIsNil() {
        XCTAssertNil(BeatMath.lastBeat(beatsMs: [100, 600, 1100], downbeatsMs: nil, atMs: 99))
    }

    func testLastBeatEmptyGridIsNil() {
        XCTAssertNil(BeatMath.lastBeat(beatsMs: [], downbeatsMs: [0], atMs: 500))
    }

    func testLastBeatExactlyOnABeat() {
        let hit = BeatMath.lastBeat(beatsMs: [100, 600, 1100], downbeatsMs: nil, atMs: 600)
        XCTAssertEqual(hit?.beatMs, 600)
    }

    func testLastBeatBetweenBeatsPicksEarlier() {
        let hit = BeatMath.lastBeat(beatsMs: [100, 600, 1100], downbeatsMs: nil, atMs: 1099)
        XCTAssertEqual(hit?.beatMs, 600)
    }

    func testLastBeatAfterLastBeatPicksLast() {
        let hit = BeatMath.lastBeat(beatsMs: [100, 600, 1100], downbeatsMs: nil, atMs: 99_999)
        XCTAssertEqual(hit?.beatMs, 1100)
    }

    func testLastBeatFlagsDownbeat() {
        let hit = BeatMath.lastBeat(beatsMs: [100, 600, 1100], downbeatsMs: [100], atMs: 150)
        XCTAssertEqual(hit?.beatMs, 100)
        XCTAssertEqual(hit?.isDownbeat, true)
        let off = BeatMath.lastBeat(beatsMs: [100, 600, 1100], downbeatsMs: [100], atMs: 700)
        XCTAssertEqual(off?.isDownbeat, false)
    }

    // MARK: isDownbeat — ±30 ms near-membership

    func testIsDownbeatExactAndWithinTolerance() {
        let downs = [0, 2000, 4000]
        XCTAssertTrue(BeatMath.isDownbeat(2000, downbeatsMs: downs))
        XCTAssertTrue(BeatMath.isDownbeat(2030, downbeatsMs: downs))   // +30 inclusive
        XCTAssertTrue(BeatMath.isDownbeat(1970, downbeatsMs: downs))   // −30 inclusive
        XCTAssertFalse(BeatMath.isDownbeat(2031, downbeatsMs: downs))  // just outside
        XCTAssertFalse(BeatMath.isDownbeat(1969, downbeatsMs: downs))
    }

    func testIsDownbeatEmptyOrNilIsFalse() {
        XCTAssertFalse(BeatMath.isDownbeat(0, downbeatsMs: nil))
        XCTAssertFalse(BeatMath.isDownbeat(0, downbeatsMs: []))
    }

    // MARK: sliceBoundaries — real grid

    // A tempo-DRIFTING grid: intervals 500/510/490/520/480. The loop length must be the
    // telescoped sum of the ACTUAL intervals, not beats × 60000/bpm (which would be 2000).
    private let drifting = [0, 500, 1010, 1500, 2020, 2500]

    func testSliceRealGridDriftSummedLength() {
        let r = BeatMath.sliceBoundaries(anchorMs: 0, beats: 4,
                                         grid: (bpm: 120, firstDownbeatMs: 0, beatsMs: drifting))
        XCTAssertEqual(r?.startMs, 0)
        XCTAssertEqual(r?.endMs, 2020)
        XCTAssertEqual(r?.lengthMs, 2020)                // actual interval sum, ≠ 2000
    }

    func testSliceAnchorSnapsForwardToNextBeat() {
        let r = BeatMath.sliceBoundaries(anchorMs: 501, beats: 1,
                                         grid: (bpm: 120, firstDownbeatMs: 0, beatsMs: drifting))
        XCTAssertEqual(r?.startMs, 1010)                 // nearest beat ≥ anchor
        XCTAssertEqual(r?.endMs, 1500)
        XCTAssertEqual(r?.lengthMs, 490)
    }

    func testSliceAnchorExactlyOnABeatStaysThere() {
        let r = BeatMath.sliceBoundaries(anchorMs: 500, beats: 2,
                                         grid: (bpm: 120, firstDownbeatMs: 0, beatsMs: drifting))
        XCTAssertEqual(r?.startMs, 500)
        XCTAssertEqual(r?.endMs, 1500)
    }

    func testSliceHalfBeatEndsAtMidpoint() {
        let r = BeatMath.sliceBoundaries(anchorMs: 500, beats: 0.5,
                                         grid: (bpm: 120, firstDownbeatMs: 0, beatsMs: drifting))
        XCTAssertEqual(r?.startMs, 500)
        XCTAssertEqual(r?.endMs, 755)                    // (500 + 1010) / 2
        XCTAssertEqual(r?.lengthMs, 255)
    }

    // MARK: sliceBoundaries — walking past the measured grid

    func testSliceExtendsPastGridEndAtConstantBpm() {
        // Two measured beats, then the walk continues at 60000/120 = 500 ms spacing.
        let r = BeatMath.sliceBoundaries(anchorMs: 0, beats: 4,
                                         grid: (bpm: 120, firstDownbeatMs: 0, beatsMs: [0, 500]))
        XCTAssertEqual(r?.startMs, 0)
        XCTAssertEqual(r?.endMs, 2000)                   // 500 + 3 × 500
        XCTAssertEqual(r?.lengthMs, 2000)
    }

    func testSliceAnchorBeyondLastBeatStartsOnExtendedLattice() {
        // Anchor 1600 > last measured beat 500: first extended beat ≥ 1600 on the
        // 500 ms lattice from 500 is 2000 (phase-continuous with the real grid).
        let r = BeatMath.sliceBoundaries(anchorMs: 1600, beats: 1,
                                         grid: (bpm: 120, firstDownbeatMs: 0, beatsMs: [0, 500]))
        XCTAssertEqual(r?.startMs, 2000)
        XCTAssertEqual(r?.endMs, 2500)
    }

    func testSliceNoBpmFallsBackToGridMeanInterval() {
        // bpm 0 but ≥ 2 measured beats: extension uses the grid's own mean interval (500).
        let r = BeatMath.sliceBoundaries(anchorMs: 0, beats: 4,
                                         grid: (bpm: 0, firstDownbeatMs: 0, beatsMs: [0, 500, 1000]))
        XCTAssertEqual(r?.endMs, 2000)                   // 1000 + 2 × 500
    }

    func testSliceSingleBeatNoBpmCannotWalkIsNil() {
        XCTAssertNil(BeatMath.sliceBoundaries(anchorMs: 0, beats: 1,
                                              grid: (bpm: 0, firstDownbeatMs: 0, beatsMs: [0])))
    }

    // MARK: sliceBoundaries — constant-grid synthesis (no measured beats)

    func testSliceSynthesisFallbackLengthIsBeatsTimesBpm() {
        // 120 BPM ⇒ 500 ms/beat; anchor before the first downbeat snaps to it.
        let r = BeatMath.sliceBoundaries(anchorMs: 0, beats: 4,
                                         grid: (bpm: 120, firstDownbeatMs: 250, beatsMs: []))
        XCTAssertEqual(r?.startMs, 250)
        XCTAssertEqual(r?.lengthMs, 2000)                // 4 × 60000/120
        XCTAssertEqual(r?.endMs, 2250)
    }

    func testSliceSynthesisSnapsAnchorForwardOnLattice() {
        let r = BeatMath.sliceBoundaries(anchorMs: 300, beats: 1,
                                         grid: (bpm: 120, firstDownbeatMs: 250, beatsMs: []))
        XCTAssertEqual(r?.startMs, 750)                  // next lattice beat ≥ 300
        XCTAssertEqual(r?.lengthMs, 500)
    }

    func testSliceSynthesisHalfBeat() {
        let r = BeatMath.sliceBoundaries(anchorMs: 250, beats: 0.5,
                                         grid: (bpm: 120, firstDownbeatMs: 250, beatsMs: []))
        XCTAssertEqual(r?.startMs, 250)
        XCTAssertEqual(r?.lengthMs, 250)                 // ½ × 500
    }

    // MARK: sliceBoundaries — no usable grid / bad input

    func testSliceNoGridAtAllIsNil() {
        XCTAssertNil(BeatMath.sliceBoundaries(anchorMs: 0, beats: 4,
                                              grid: (bpm: 0, firstDownbeatMs: 0, beatsMs: [])))
    }

    func testSliceNonPositiveBeatsIsNil() {
        XCTAssertNil(BeatMath.sliceBoundaries(anchorMs: 0, beats: 0,
                                              grid: (bpm: 120, firstDownbeatMs: 0, beatsMs: drifting)))
    }
}

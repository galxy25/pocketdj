import XCTest
@testable import PocketDJ

/// ScoreQuantizer (Studio/ScoreModel.swift) — pure event-log → notation math (spec §7).
/// Hermetic: fixed events at 120 BPM (one 16th = 125 ms) unless a test says otherwise.
final class ScoreQuantizerTests: XCTestCase {

    private func ev(_ on: Int, _ off: Int, _ note: Int, vel: Int = 100) -> StudioNoteEvent {
        StudioNoteEvent(onMs: on, offMs: off, note: note, velocity: vel)
    }

    // MARK: Onset snapping

    func testOnsetSnapsToNearestSixteenth() {
        // 130 ms at 120 BPM = 1.04 sixteenths → onset 1; the 250 ms length → an eighth.
        let doc = ScoreQuantizer.quantize(events: [ev(130, 380, 60)], bpm: 120, instrument: .violin)
        XCTAssertEqual(doc.measures.count, 1)
        let items = doc.measures[0].items
        // Leading 16th rest fills onset 0, then the note at onset 1.
        XCTAssertEqual(items[0], ScoreItem(onset16ths: 0, kind: .rest, duration: .sixteenth))
        XCTAssertEqual(items[1], ScoreItem(onset16ths: 1, kind: .notes([60]), duration: .eighth))
    }

    func testEarlyHitClampsToBeatOneNeverNegative() {
        // A hit 30 ms BEFORE the anchor (recorder jitter) rounds to onset 0, not measure −1.
        let doc = ScoreQuantizer.quantize(events: [ev(-30, 220, 60)], bpm: 120, instrument: .violin)
        XCTAssertEqual(doc.measures[0].items.first?.onset16ths, 0)
    }

    // MARK: Chord grouping

    func testSameQuantizedOnsetBecomesOneChordSorted() {
        // 0/5/2 ms all round to onset 0 → ONE item with the notes sorted ascending.
        let doc = ScoreQuantizer.quantize(events: [ev(0, 250, 67), ev(5, 250, 60), ev(2, 255, 64)],
                                          bpm: 120, instrument: .piano)
        XCTAssertEqual(doc.measures[0].items.first?.kind, .notes([60, 64, 67]))
    }

    func testChordDurationIsLongestMember() {
        // A 16th + a quarter at the same onset: the single-voice item keeps the LONGEST.
        let doc = ScoreQuantizer.quantize(events: [ev(0, 125, 60), ev(0, 500, 64)],
                                          bpm: 120, instrument: .piano)
        XCTAssertEqual(doc.measures[0].items.first?.duration, .quarter)
    }

    // MARK: Rest filling

    func testRestsFillLeadingAndTrailingGaps() {
        // One eighth on beat 2 (onset 4): quarter rest before, half + eighth rests after —
        // the measure always sums to exactly 16 sixteenths.
        let doc = ScoreQuantizer.quantize(events: [ev(500, 750, 62)], bpm: 120, instrument: .violin)
        XCTAssertEqual(doc.measures[0].items, [
            ScoreItem(onset16ths: 0, kind: .rest, duration: .quarter),
            ScoreItem(onset16ths: 4, kind: .notes([62]), duration: .eighth),
            ScoreItem(onset16ths: 6, kind: .rest, duration: .half),
            ScoreItem(onset16ths: 14, kind: .rest, duration: .eighth),
        ])
    }

    func testFullyEmptyLeadingMeasureIsAWholeRest() {
        // First note in measure 1 → measure 0 is one whole rest, never 16 fragments.
        let doc = ScoreQuantizer.quantize(events: [ev(2000, 2250, 60)], bpm: 120, instrument: .violin)
        XCTAssertEqual(doc.measures.count, 2)
        XCTAssertEqual(doc.measures[0].items, [ScoreItem(onset16ths: 0, kind: .rest, duration: .whole)])
        XCTAssertEqual(doc.measures[1].items.first?.kind, .notes([60]))
    }

    func testEveryMeasureSumsToSixteen() {
        // A messy take: overlaps, gaps, a barline crossing — the packing invariant must hold.
        let events = [ev(0, 900, 60), ev(300, 700, 64), ev(1900, 2600, 67), ev(3100, 3400, 71)]
        let doc = ScoreQuantizer.quantize(events: events, bpm: 120, instrument: .piano)
        for measure in doc.measures {
            XCTAssertEqual(measure.items.map(\.duration.sixteenths).reduce(0, +), 16,
                           "measure \(measure.index) must pack to exactly 16 sixteenths")
        }
    }

    // MARK: Duration snapping (incl. dotted values)

    func testDottedDurationsSnap() {
        // 375/750/1500 ms at 120 BPM = 3/6/12 sixteenths = dotted 8th/quarter/half.
        XCTAssertEqual(ScoreQuantizer.quantize(events: [ev(0, 375, 60)], bpm: 120, instrument: .piano)
            .measures[0].items.first?.duration, .dottedEighth)
        XCTAssertEqual(ScoreQuantizer.quantize(events: [ev(0, 750, 60)], bpm: 120, instrument: .piano)
            .measures[0].items.first?.duration, .dottedQuarter)
        XCTAssertEqual(ScoreQuantizer.quantize(events: [ev(0, 1500, 60)], bpm: 120, instrument: .piano)
            .measures[0].items.first?.duration, .dottedHalf)
    }

    func testSnapNearestWithTiesRoundingDown() {
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 5), .quarter)        // tie 4|6 → shorter
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 7), .dottedQuarter)  // tie 6|8 → shorter
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 10), .half)          // tie 8|12 → shorter
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 14), .dottedHalf)    // tie 12|16 → shorter
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 13), .dottedHalf)    // plain nearest
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 15), .whole)
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 0), .sixteenth)      // floor clamp
        XCTAssertEqual(NoteDuration.snapped(toSixteenths: 40), .whole)         // no-ties cap
    }

    func testTapShorterThanASixteenthStillNotates() {
        // A 10 ms tap is a note, not nothing — minimum one 16th.
        let doc = ScoreQuantizer.quantize(events: [ev(0, 10, 60)], bpm: 120, instrument: .piano)
        XCTAssertEqual(doc.measures[0].items.first?.duration, .sixteenth)
    }

    // MARK: Single-voice truncation

    func testOverlappingNoteTruncatesAtNextOnset() {
        // A half note whose successor starts 2 sixteenths in: truncated to an eighth (no voices).
        let doc = ScoreQuantizer.quantize(events: [ev(0, 1000, 60), ev(250, 500, 64)],
                                          bpm: 120, instrument: .piano)
        let items = doc.measures[0].items
        XCTAssertEqual(items[0], ScoreItem(onset16ths: 0, kind: .notes([60]), duration: .eighth))
        XCTAssertEqual(items[1], ScoreItem(onset16ths: 2, kind: .notes([64]), duration: .eighth))
    }

    func testDurationTruncatesAtBarline() {
        // A dotted quarter starting on the last eighth of the bar: v1 has no ties, so it
        // truncates to what fits before the barline.
        let doc = ScoreQuantizer.quantize(events: [ev(1750, 2500, 60)], bpm: 120, instrument: .violin)
        XCTAssertEqual(doc.measures.count, 1)
        XCTAssertEqual(doc.measures[0].items.last,
                       ScoreItem(onset16ths: 14, kind: .notes([60]), duration: .eighth))
    }

    // MARK: Clef plans + grand-staff split

    func testClefPlansPerInstrument() {
        XCTAssertEqual(ClefPlan.plan(for: .piano), .grandStaff)
        XCTAssertEqual(ClefPlan.plan(for: .harp), .grandStaff)
        XCTAssertEqual(ClefPlan.plan(for: .bassGuitar), .bass)
        XCTAssertEqual(ClefPlan.plan(for: .violin), .treble)
        XCTAssertEqual(ClefPlan.plan(for: .trumpet), .treble)
        XCTAssertEqual(ClefPlan.plan(for: .clarinet), .treble)
        XCTAssertEqual(ClefPlan.plan(for: .acousticGuitar), .treble)
    }

    func testGrandStaffSplitsAtMiddleCSixtyGoesTreble() {
        // Spec constant: note 60 ⇒ treble, 59 ⇒ bass.
        XCTAssertEqual(ClefPlan.grandStaff.staff(forNote: 60), .treble)
        XCTAssertEqual(ClefPlan.grandStaff.staff(forNote: 59), .bass)
        // Single-staff plans never split, whatever the range.
        XCTAssertEqual(ClefPlan.treble.staff(forNote: 30), .treble)
        XCTAssertEqual(ClefPlan.bass.staff(forNote: 100), .bass)
    }

    // MARK: Degenerate inputs

    func testEmptyEventsYieldEmptyMeasures() {
        let doc = ScoreQuantizer.quantize(events: [], bpm: 96, instrument: .harp)
        XCTAssertTrue(doc.measures.isEmpty)
        XCTAssertEqual(doc.bpm, 96)
        XCTAssertEqual(doc.clefPlan, .grandStaff)
    }

    func testOutOfRangeNotesAreDropped() {
        let doc = ScoreQuantizer.quantize(events: [ev(0, 250, 128), ev(0, 250, -1)],
                                          bpm: 120, instrument: .piano)
        XCTAssertTrue(doc.measures.isEmpty)
    }

    func testZeroBpmGuardsToDefault() {
        // A corrupt document's bpm 0 degrades to the schema's 120 default, never a crash.
        let doc = ScoreQuantizer.quantize(events: [ev(0, 500, 60)], bpm: 0, instrument: .piano)
        XCTAssertEqual(doc.bpm, 120)
        XCTAssertEqual(doc.measures[0].items.first?.duration, .quarter)  // 500 ms @120 = quarter
    }

    // MARK: minMeasures — empty trailing bars (cursor / add-bar)

    private func isRest(_ i: ScoreItem) -> Bool { if case .rest = i.kind { return true }; return false }

    func testMinMeasuresPadsEmptyTrailingBars() {
        let doc = ScoreQuantizer.quantize(events: [ev(0, 250, 60)], bpm: 120, instrument: .piano,
                                          minMeasures: 3)
        XCTAssertEqual(doc.measures.count, 3, "padded out to the requested minimum")
        XCTAssertTrue(doc.measures[0].items.contains { if case .notes = $0.kind { return true }; return false })
        for b in 1..<3 {
            XCTAssertTrue(doc.measures[b].items.allSatisfy(isRest), "bar \(b) is an empty (rest-only) bar")
        }
    }

    func testMinMeasuresBelowContentIsNoOp() {
        // Content already spans 2 bars (a note in bar 1); minMeasures 1 never shrinks it.
        let doc = ScoreQuantizer.quantize(events: [ev(0, 250, 60), ev(2000, 2250, 62)], bpm: 120,
                                          instrument: .piano, minMeasures: 1)
        XCTAssertEqual(doc.measures.count, 2)
    }

    func testMinMeasuresOnEmptyScore() {
        let doc = ScoreQuantizer.quantize(events: [], bpm: 120, instrument: .piano, minMeasures: 2)
        XCTAssertEqual(doc.measures.count, 2, "no notes but 2 empty bars requested")
        XCTAssertTrue(doc.measures.allSatisfy { $0.items.allSatisfy(isRest) })
    }

    func testDefaultMinMeasuresUnaffectsExports() {
        // No minMeasures (the export path) → content-only.
        let doc = ScoreQuantizer.quantize(events: [ev(0, 250, 60)], bpm: 120, instrument: .piano)
        XCTAssertEqual(doc.measures.count, 1)
    }
}

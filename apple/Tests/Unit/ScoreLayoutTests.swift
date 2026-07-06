import XCTest
@testable import PocketDJ

/// ScoreLayout / ScorePDF (Studio/ScorePDF.swift) — layout-invariant smoke tests: reading-order
/// x positions, pitch → staff-position math, clef strips, pagination, and the PDF export's
/// magic bytes. Not pixel tests — the geometry engine's INVARIANTS, so the drawing can evolve
/// without breaking them.
final class ScoreLayoutTests: XCTestCase {

    private func note(_ onset: Int, _ midi: Int, _ d: NoteDuration = .quarter) -> ScoreItem {
        ScoreItem(onset16ths: onset, kind: .notes([midi]), duration: d)
    }

    private func doc(_ measures: [ScoreMeasure], plan: ClefPlan = .treble) -> ScoreDocument {
        ScoreDocument(measures: measures, bpm: 120, clefPlan: plan)
    }

    private func noteHeadXs(_ page: ScorePage) -> [CGFloat] {
        page.glyphs.compactMap { g -> CGFloat? in
            if case .noteHead(let center, _, _, _) = g { return center.x }
            return nil
        }
    }

    // MARK: x positions — reading order

    func testXPositionIsStrictlyMonotonicAcrossOnsets() {
        let xs = (0..<16).map { ScoreLayout.xPosition(onset16ths: $0, measureX: 100, measureWidth: 120) }
        for i in 1..<xs.count {
            XCTAssertLessThan(xs[i - 1], xs[i], "onset \(i) must lay out right of onset \(i - 1)")
        }
        // And inside the measure's bounds.
        XCTAssertGreaterThan(xs.first!, 100)
        XCTAssertLessThan(xs.last!, 220)
    }

    func testNoteHeadsIncreaseAcrossALaidMeasure() {
        let measure = ScoreMeasure(index: 0, items: [note(0, 64), note(4, 67), note(8, 71), note(12, 72)])
        let pages = ScoreLayout.paginate(score: doc([measure]), title: "T", instrument: .violin)
        let xs = noteHeadXs(pages[0])
        XCTAssertEqual(xs.count, 4)
        for i in 1..<xs.count { XCTAssertLessThan(xs[i - 1], xs[i]) }
    }

    // MARK: Pitch → staff position

    func testStaffPositionReferenceNotes() {
        // Treble: bottom line = E4 (64); middle C sits one ledger below (−2); F5 = top line (8).
        XCTAssertEqual(ScoreLayout.staffPosition(midi: 64, clef: .treble).position, 0)
        XCTAssertEqual(ScoreLayout.staffPosition(midi: 60, clef: .treble).position, -2)
        XCTAssertEqual(ScoreLayout.staffPosition(midi: 77, clef: .treble).position, 8)
        // Bass: bottom line = G2 (43); middle C sits one ledger above (10).
        XCTAssertEqual(ScoreLayout.staffPosition(midi: 43, clef: .bass).position, 0)
        XCTAssertEqual(ScoreLayout.staffPosition(midi: 60, clef: .bass).position, 10)
    }

    func testBlackKeysSpellAsSharps() {
        let cSharp = ScoreLayout.staffPosition(midi: 61, clef: .treble)
        XCTAssertEqual(cSharp.position, -2)          // same line as C4…
        XCTAssertTrue(cSharp.sharp)                  // …plus the ♯
        XCTAssertFalse(ScoreLayout.staffPosition(midi: 60, clef: .treble).sharp)
    }

    func testSpelledPositionHonoursOverrides() {
        // No override ⇒ derived (E4 natural, C#4 as sharp-of-C).
        let eNat = ScoreLayout.spelledPosition(midi: 64, clef: .treble, accidental: nil)
        XCTAssertEqual(eNat.position, 0)             // E4 bottom line
        XCTAssertEqual(eNat.accidental, .natural)
        let cSharp = ScoreLayout.spelledPosition(midi: 61, clef: .treble, accidental: nil)
        XCTAssertEqual(cSharp.position, -2)
        XCTAssertEqual(cSharp.accidental, .sharp)

        // .flat on MIDI 63 (D#/Eb) ⇒ the E LINE + ♭ (E♭), not the D♯ line.
        let eFlat = ScoreLayout.spelledPosition(midi: 63, clef: .treble, accidental: .flat)
        XCTAssertEqual(eFlat.position, ScoreLayout.staffPosition(midi: 64, clef: .treble).position)
        XCTAssertEqual(eFlat.accidental, .flat)

        // .sharp on MIDI 61 ⇒ the C line + ♯ (C♯).
        let cS = ScoreLayout.spelledPosition(midi: 61, clef: .treble, accidental: .sharp)
        XCTAssertEqual(cS.position, ScoreLayout.staffPosition(midi: 60, clef: .treble).position)
        XCTAssertEqual(cS.accidental, .sharp)

        // .natural on a white key ⇒ no glyph; on a black key it falls back to the derived sharp.
        XCTAssertEqual(ScoreLayout.spelledPosition(midi: 60, clef: .treble, accidental: .natural).accidental, .natural)
        XCTAssertEqual(ScoreLayout.spelledPosition(midi: 61, clef: .treble, accidental: .natural).accidental, .sharp)
    }

    // MARK: Hit-testing (inverse layout) — locate must round-trip notePoint

    func testLocateRoundTripsNotePointTreble() {
        let doc = ScoreDocument(measures: [ScoreMeasure(index: 0, items: [
            ScoreItem(onset16ths: 4, kind: .notes([64]), duration: .quarter)])],
                                bpm: 120, clefPlan: .treble)
        let pages = ScoreLayout.paginate(score: doc, title: "T", instrument: .violin)
        let np = try! XCTUnwrap(ScoreLayout.notePoint(midi: 64, accidental: nil, onset16ths: 4,
                                                      plan: .treble, pages: pages))
        let loc = try! XCTUnwrap(ScoreLayout.locate(point: np.point, page: pages[np.page]))
        XCTAssertEqual(loc.measureIndex, 0)
        XCTAssertEqual(loc.onset16ths, 4)
        XCTAssertEqual(loc.staff, .treble)
        XCTAssertEqual(loc.position, 0)                          // E4 = treble bottom line
        XCTAssertEqual(ScoreLayout.naturalMidi(position: loc.position, clef: .treble), 64)
    }

    func testLocateRoundTripsGrandStaffBassInLaterMeasure() {
        // A C3 (bass staff) at measure 5, onset 8 — exercises measure indexing + the bass strip.
        var measures = (0..<6).map { ScoreMeasure(index: $0, items: []) }
        measures[5].items = [ScoreItem(onset16ths: 8, kind: .notes([48]), duration: .quarter)]
        let doc = ScoreDocument(measures: measures, bpm: 120, clefPlan: .grandStaff)
        let pages = ScoreLayout.paginate(score: doc, title: "T", instrument: .piano)
        let np = try! XCTUnwrap(ScoreLayout.notePoint(midi: 48, accidental: nil, onset16ths: 5 * 16 + 8,
                                                      plan: .grandStaff, pages: pages))
        let loc = try! XCTUnwrap(ScoreLayout.locate(point: np.point, page: pages[np.page]))
        XCTAssertEqual(loc.measureIndex, 5)
        XCTAssertEqual(loc.onset16ths, 8)
        XCTAssertEqual(loc.staff, .bass)
        XCTAssertEqual(ScoreLayout.naturalMidi(position: loc.position, clef: .bass), 48)
    }

    func testNaturalMidiInvertsStaffPosition() {
        for (midi, clef) in [(64, StaffRole.treble), (60, .treble), (77, .treble), (43, .bass), (48, .bass)] {
            let pos = ScoreLayout.staffPosition(midi: midi, clef: clef).position
            XCTAssertEqual(ScoreLayout.naturalMidi(position: pos, clef: clef), midi,
                           "naturalMidi should invert staffPosition for white key \(midi)")
        }
    }

    func testOnsetFromXInvertsXPosition() {
        for onset in 0...15 {
            let x = ScoreLayout.xPosition(onset16ths: onset, measureX: 100, measureWidth: 240)
            XCTAssertEqual(ScoreLayout.onsetFromX(x, measureX: 100, measureWidth: 240), onset)
        }
    }

    func testQuantizerCarriesEventAccidentalIntoSpellings() {
        // An event spelled flat surfaces as a per-note override on the score item.
        let doc = ScoreQuantizer.quantize(
            events: [StudioNoteEvent(onMs: 0, offMs: 240, note: 63, velocity: 96, accidental: .flat)],
            bpm: 120, instrument: .piano)
        let item = doc.measures.first?.items.first { if case .notes = $0.kind { return true }; return false }
        XCTAssertEqual(item?.spellings[63], .flat)
    }

    // MARK: Staves / clefs

    func testGrandStaffSystemDrawsBothClefs() {
        let measure = ScoreMeasure(index: 0, items: [note(0, 60, .whole)])
        let pages = ScoreLayout.paginate(score: doc([measure], plan: .grandStaff),
                                         title: "T", instrument: .piano)
        let roles = pages[0].glyphs.compactMap { g -> StaffRole? in
            if case .clef(let role, _, _, _) = g { return role }
            return nil
        }
        XCTAssertEqual(roles, [.treble, .bass])      // top-first, one system
    }

    func testGrandStaffChordSplitsHeadsAcrossStrips() {
        // C3 + E4 on a piano: one head per staff strip, at clearly different y bands.
        let measure = ScoreMeasure(index: 0,
                                   items: [ScoreItem(onset16ths: 0, kind: .notes([48, 64]),
                                                     duration: .quarter)])
        let pages = ScoreLayout.paginate(score: doc([measure], plan: .grandStaff),
                                         title: "T", instrument: .piano)
        let ys = pages[0].glyphs.compactMap { g -> CGFloat? in
            if case .noteHead(let center, _, _, _) = g { return center.y }
            return nil
        }
        XCTAssertEqual(ys.count, 2)
        // The bass head must sit below the whole treble strip (strips are ≥ grandStaffGap apart).
        XCTAssertGreaterThan(abs(ys[0] - ys[1]), ScoreLayout.Metrics.a4.grandStaffGap)
    }

    // MARK: Pagination

    func testEmptyScoreIsOneHeaderOnlyPage() {
        let pages = ScoreLayout.paginate(score: doc([]), title: "Empty", instrument: .violin)
        XCTAssertEqual(pages.count, 1)
        let hasText = pages[0].glyphs.contains { if case .text = $0 { return true }; return false }
        XCTAssertTrue(hasText)
    }

    func testManyMeasuresFlowOntoASecondPage() {
        // 40 whole-rest measures = 10 four-measure systems — more than one A4 page's worth.
        let measures = (0..<40).map {
            ScoreMeasure(index: $0, items: [ScoreItem(onset16ths: 0, kind: .rest, duration: .whole)])
        }
        let pages = ScoreLayout.paginate(score: doc(measures), title: "Long", instrument: .violin)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages[0].size, ScoreLayout.Metrics.a4.pageSize)
    }

    // MARK: PDF export

    func testPDFDataHasMagicHeader() {
        let take = [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 100),
                    StudioNoteEvent(onMs: 500, offMs: 1000, note: 52, velocity: 90)]
        let score = ScoreQuantizer.quantize(events: take, bpm: 120, instrument: .piano)
        let data = ScorePDF.makePDF(score: score, title: "Smoke", instrument: .piano)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")
    }

    func testEmptyScoreStillExportsAValidPDF() {
        // The empty state must export an openable (header-only) file, never zero bytes.
        let score = ScoreQuantizer.quantize(events: [], bpm: 120, instrument: .violin)
        let data = ScorePDF.makePDF(score: score, title: "Empty", instrument: .violin)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")
    }
}

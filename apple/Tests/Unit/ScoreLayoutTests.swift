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

    // MARK: Playback cursor geometry (must agree with the note heads it points at)

    /// THE alignment test: the playback cursor at a fractional 16th must land on exactly the x a
    /// note head at that 16th is drawn at — on a REALLY laid page, not just in the arithmetic.
    /// A cursor computed with its own formula is how a cursor ends up pointing at the wrong note
    /// (the StaffChordView bug); both go through `ScoreLayout.xPosition`.
    func testPlayheadXMatchesNoteHeadXOnALaidPage() {
        var measures = (0..<6).map { ScoreMeasure(index: $0, items: []) }
        measures[0].items = [note(4, 64)]
        measures[5].items = [note(8, 67)]
        let pages = ScoreLayout.paginate(score: doc(measures), title: "T", instrument: .violin)
        for (abs16, midi) in [(4, 64), (5 * 16 + 8, 67)] {
            let np = try! XCTUnwrap(ScoreLayout.notePoint(midi: midi, accidental: nil,
                                                          onset16ths: abs16, plan: .treble,
                                                          pages: pages))
            let ph = try! XCTUnwrap(ScoreLayout.playhead(at: Double(abs16), pages: pages))
            XCTAssertEqual(ph.page, np.page, "cursor must resolve to the note's page")
            XCTAssertEqual(ph.x, np.point.x, accuracy: 0.0001,
                           "cursor x must be the head's own x at onset \(abs16)")
            // …and the rule must bracket the head vertically (staves + ledger headroom).
            XCTAssertLessThan(ph.top, np.point.y)
            XCTAssertGreaterThan(ph.bottom, np.point.y)
        }
    }

    func testPlayheadAdvancesMonotonicallyWithinAMeasure() {
        let pages = ScoreLayout.paginate(score: doc([ScoreMeasure(index: 0, items: [note(0, 64)])]),
                                         title: "T", instrument: .violin)
        let xs = stride(from: 0.0, through: 15.0, by: 0.5).compactMap {
            ScoreLayout.playhead(at: $0, pages: pages)?.x
        }
        XCTAssertEqual(xs.count, 31)
        for i in 1..<xs.count { XCTAssertLessThan(xs[i - 1], xs[i]) }
    }

    /// Playback runs past the last note: the cursor parks at the end of the last laid measure
    /// rather than vanishing.
    func testPlayheadParksAtTheScoreEndWhenPastTheLastMeasure() {
        let pages = ScoreLayout.paginate(score: doc([ScoreMeasure(index: 0, items: [note(0, 64)])]),
                                         title: "T", instrument: .violin)
        let end = try! XCTUnwrap(ScoreLayout.playhead(at: 999, pages: pages))
        let last = try! XCTUnwrap(ScoreLayout.playhead(at: 15.9, pages: pages))
        XCTAssertEqual(end.page, last.page)
        XCTAssertGreaterThan(end.x, last.x)
    }

    /// Degenerate inputs degrade, never trap: an empty score has nowhere to put a cursor, and a
    /// NaN clock read must not reach `Int(_:)`.
    func testPlayheadIsNilForEmptyScoreAndNonFiniteInput() {
        let empty = ScoreLayout.paginate(score: doc([]), title: "Empty", instrument: .violin)
        XCTAssertNil(ScoreLayout.playhead(at: 0, pages: empty))
        XCTAssertNil(ScoreLayout.playhead(at: .nan, pages: empty))
        let pages = ScoreLayout.paginate(score: doc([ScoreMeasure(index: 0, items: [note(0, 64)])]),
                                         title: "T", instrument: .violin)
        XCTAssertNil(ScoreLayout.playhead(at: .infinity, pages: pages))
        XCTAssertNotNil(ScoreLayout.playhead(at: -5, pages: pages))    // clamps to the start
    }

    // MARK: Played marks (the highlight geometry)

    /// Every mark must sit exactly where `notePoint` puts that note — the highlight is a wash ON
    /// the head, so a different derivation would smear it off the notation.
    func testPlayedMarksMatchNotePointForEveryNote() {
        // 120 BPM ⇒ one 16th = 125 ms: onsets 0 and 8 (= 1000 ms).
        let events = [StudioNoteEvent(onMs: 0, offMs: 500, note: 48, velocity: 90),
                      StudioNoteEvent(onMs: 0, offMs: 500, note: 64, velocity: 90),
                      StudioNoteEvent(onMs: 1000, offMs: 1500, note: 72, velocity: 90)]
        let score = ScoreQuantizer.quantize(events: events, bpm: 120, instrument: .piano)
        let pages = ScoreLayout.paginate(score: score, title: "T", instrument: .piano)
        let marks = ScoreLayout.playedMarks(events: events, bpm: 120, plan: .grandStaff, pages: pages)
        XCTAssertEqual(marks.count, 3)                       // the grand-staff chord keeps BOTH heads
        XCTAssertEqual(marks.map(\.onset16ths), [0, 0, 8])   // onset-ordered
        // Same-onset marks come back in no defined order, so match by VALUE, not by position.
        for (e, abs16) in zip(events, [0, 0, 8]) {
            let np = try! XCTUnwrap(ScoreLayout.notePoint(midi: e.note, accidental: nil,
                                                          onset16ths: abs16, plan: .grandStaff,
                                                          pages: pages))
            XCTAssertTrue(marks.contains {
                $0.onset16ths == abs16 && $0.page == np.page
                    && abs($0.point.x - np.point.x) < 0.0001 && abs($0.point.y - np.point.y) < 0.0001
            }, "no mark on note \(e.note)'s laid head")
        }
    }

    /// End to end on a REAL laid score: at a moment inside the second note, the cursor sits on
    /// that note's head, the first note reads as played-behind, and nothing else is highlighted.
    /// This is the whole feature's geometry contract in one assertion set.
    func testCursorPlayedAndCurrentAgreeOnALaidScore() {
        // 120 BPM ⇒ 16th = 125 ms. E4 at onset 0, G4 at onset 4 (500 ms), sampled at 600 ms.
        let events = [StudioNoteEvent(onMs: 0, offMs: 250, note: 64, velocity: 90),
                      StudioNoteEvent(onMs: 500, offMs: 750, note: 67, velocity: 90)]
        let score = ScoreQuantizer.quantize(events: events, bpm: 120, instrument: .violin)
        let pages = ScoreLayout.paginate(score: score, title: "T", instrument: .violin)
        let marks = ScoreLayout.playedMarks(events: events, bpm: 120, plan: score.clefPlan,
                                            pages: pages)
        let state = ScorePlayhead.state(atMs: 600,
                                        slots: ScorePlayhead.timeline(events: events, bpm: 120),
                                        bpm: 120)
        XCTAssertTrue(state.isSounding)
        let current = marks.filter { state.isCurrent(onset16ths: $0.onset16ths) }
        let played = marks.filter { state.isPlayed(onset16ths: $0.onset16ths) }
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(played.map(\.onset16ths), [0])
        let head = try! XCTUnwrap(ScoreLayout.notePoint(midi: 67, accidental: nil, onset16ths: 4,
                                                        plan: .treble, pages: pages))
        XCTAssertEqual(current[0].point.x, head.point.x, accuracy: 0.0001)
        // The cursor is 0.8 of a 16th past that head — right of it, still left of the next 16th.
        let ph = try! XCTUnwrap(ScoreLayout.playhead(at: state.cursor16ths, pages: pages))
        XCTAssertGreaterThan(ph.x, head.point.x)
        XCTAssertLessThan(ph.x, ScoreLayout.notePoint(midi: 67, accidental: nil, onset16ths: 5,
                                                      plan: .treble, pages: pages)!.point.x)
    }

    // MARK: Tap-to-seek (the INVERSE of the cursor's own geometry)

    /// The arithmetic contract: `fractional16ths(atX:)` must undo `xPosition(fractional16ths:)`
    /// exactly — including at the measure's boundaries (0 and 16/16), where an off-by-a-pad
    /// inverse would land a tap in the neighbouring bar.
    func testFractional16thsInvertsXPosition() {
        for t in [0.0, 0.25, 1, 3.5, 4, 8, 12.75, 15, 15.9, 16] {
            let x = ScoreLayout.xPosition(fractional16ths: t, measureX: 100, measureWidth: 240)
            XCTAssertEqual(ScoreLayout.fractional16ths(atX: x, measureX: 100, measureWidth: 240),
                           t, accuracy: 1e-9, "x → time must invert time → x at \(t)")
        }
        // Outside the measure it clamps to the measure's own span — picking WHICH measure was
        // tapped is `measure(at:page:)`'s job, not this arithmetic's.
        XCTAssertEqual(ScoreLayout.fractional16ths(atX: -500, measureX: 100, measureWidth: 240), 0)
        XCTAssertEqual(ScoreLayout.fractional16ths(atX: 5_000, measureX: 100, measureWidth: 240), 16)
        // Degenerate geometry / a NaN tap degrade to 0 rather than producing a wild time.
        XCTAssertEqual(ScoreLayout.fractional16ths(atX: 150, measureX: 100, measureWidth: 4), 0)
        XCTAssertEqual(ScoreLayout.fractional16ths(atX: CGFloat.nan, measureX: 100, measureWidth: 240), 0)
    }

    /// THE round trip on a REALLY laid, multi-system, multi-page score: time → the cursor's x
    /// (`ScoreLayout.playhead`) → back to time (`ScoreLayout.time16ths`) must return the same
    /// time. A tapped x therefore lands on exactly the time the cursor sits at for that x — the
    /// two can't drift, because they are one formula solved in both directions.
    func testTime16thsInvertsThePlayheadOnALaidScore() {
        // 40 measures ⇒ 10 systems ⇒ more than one page, so the page/system resolution is real.
        var measures = (0..<40).map { ScoreMeasure(index: $0, items: []) }
        measures[0].items = [note(0, 64)]                       // first note
        measures[5].items = [note(8, 67)]
        measures[39].items = [note(12, 72)]                     // last note
        let pages = ScoreLayout.paginate(score: doc(measures), title: "T", instrument: .violin)
        XCTAssertGreaterThan(pages.count, 1, "the fixture must actually paginate")
        let times: [Double] = [0,                 // the very start
                               4, 4.5,            // mid-measure, between 16ths
                               16,                // a measure boundary
                               63.9,              // the last 16th before a system boundary
                               64,                // …and the system boundary itself
                               5 * 16 + 8,        // the note in measure 5
                               39 * 16 + 12,      // the LAST note
                               39 * 16 + 15.5]    // the last sliver of the score
        for t in times {
            let ph = try! XCTUnwrap(ScoreLayout.playhead(at: t, pages: pages),
                                    "cursor must resolve at \(t)")
            // Sample the point the cursor draws THROUGH (its own vertical extent), which is what
            // a finger/pointer actually lands on.
            let p = CGPoint(x: ph.x, y: (ph.top + ph.bottom) / 2)
            let back = try! XCTUnwrap(ScoreLayout.time16ths(at: p, page: pages[ph.page]),
                                      "tap must resolve on the cursor's own page at \(t)")
            XCTAssertEqual(back, t, accuracy: 1e-6, "tapped x must be the time the cursor shows")
        }
    }

    /// Past the end the cursor parks at the last measure's end — so a tap out there reads as that
    /// same end position, not as some later bar that isn't laid out.
    func testTime16thsPastTheEndResolvesToTheScoreEnd() {
        let pages = ScoreLayout.paginate(score: doc([ScoreMeasure(index: 0, items: [note(0, 64)])]),
                                         title: "T", instrument: .violin)
        let ph = try! XCTUnwrap(ScoreLayout.playhead(at: 999, pages: pages))
        let back = try! XCTUnwrap(ScoreLayout.time16ths(at: CGPoint(x: ph.x,
                                                                    y: (ph.top + ph.bottom) / 2),
                                                        page: pages[ph.page]))
        XCTAssertEqual(back, 16, accuracy: 1e-6, "the one-measure score ends at 16/16")
        // A tap far to the RIGHT of the last measure clamps to the same end, never past it.
        let far = try! XCTUnwrap(ScoreLayout.time16ths(at: CGPoint(x: 100_000,
                                                                   y: (ph.top + ph.bottom) / 2),
                                                       page: pages[ph.page]))
        XCTAssertEqual(far, 16, accuracy: 1e-6)
    }

    /// A tap that misses every staff band still SEEKS — to the nearest system. A single-staff band
    /// is only ~42 pt on an iPhone with dead strips between the systems, and a tap that does nothing
    /// with no feedback reads as broken. (Note ENTRY keeps refusing those points — `locate` does
    /// not use this fallback, because placing a note is destructive and a cursor move is not.)
    func testTapsOffTheStaffSeekTheNearestSystem() {
        var measures = (0..<8).map { ScoreMeasure(index: $0, items: []) }
        measures[0].items = [note(0, 64)]
        let pages = ScoreLayout.paginate(score: doc(measures), title: "T", instrument: .violin)
        let page = pages[0]
        let s0 = page.systems[0], s1 = page.systems[1]
        let x = s0.measures[0].x + s0.measures[0].width / 2
        // The gap BETWEEN two systems: below system 0's ledger headroom, above system 1's.
        let gap0 = s0.strips.last!.top + 4 * s0.spacing + 3 * s0.spacing
        let gap1 = s1.strips.first!.top - 3 * s1.spacing
        let justBelow0 = try! XCTUnwrap(ScoreLayout.time16ths(at: CGPoint(x: x, y: gap0 + 1), page: page))
        let justAbove1 = try! XCTUnwrap(ScoreLayout.time16ths(at: CGPoint(x: x, y: gap1 - 1), page: page))
        XCTAssertLessThan(justBelow0, 4 * 16, "just under system 0 belongs to system 0's measures")
        XCTAssertGreaterThanOrEqual(justAbove1, 4 * 16, "just over system 1 belongs to system 1's")
        // The title/header band and the bottom margin resolve to the first / last system, not nil.
        let head = CGPoint(x: s0.measures[0].x + 1, y: 4)   // above everything, at bar 1's left edge
        XCTAssertEqual(try! XCTUnwrap(ScoreLayout.time16ths(at: head, page: page)),
                       0, accuracy: 1e-6, "a tap in the header seeks the top system's first bar")
        XCTAssertNotNil(ScoreLayout.time16ths(at: CGPoint(x: x, y: 10_000), page: page))
        // But note ENTRY still refuses every one of them — the fallback is seek-only.
        XCTAssertNil(ScoreLayout.locate(point: CGPoint(x: x, y: gap0 + 1), page: page))
        XCTAssertNil(ScoreLayout.locate(point: head, page: page))
        // A non-coordinate is never a seek, and a page with nothing laid on it has nowhere to seek.
        XCTAssertNil(ScoreLayout.time16ths(at: CGPoint(x: 200, y: CGFloat.nan), page: page))
        XCTAssertNil(ScoreLayout.time16ths(at: CGPoint(x: CGFloat.infinity, y: 20), page: page))
        let empty = ScoreLayout.paginate(score: doc([]), title: "T", instrument: .violin)[0]
        XCTAssertTrue(empty.systems.isEmpty)
        XCTAssertNil(ScoreLayout.time16ths(at: CGPoint(x: 200, y: 200), page: empty))
    }

    /// The measure PADS. `xPosition` lays a bar's 16 slots inside its width with `measureHeadPad`
    /// of breathing room at each end, so no x in a pad is any slot's x and a tap there CLAMPS. The
    /// right pad therefore reads as the bar's END — which is the same instant as the next bar's
    /// downbeat, and that is where the cursor draws. Pinning the semantics: the mapping is exact
    /// about TIME, and the cursor may legitimately land a pad (or a line-break) from the finger.
    func testTapInAMeasuresRightPadIsTheNextBarsDownbeat() {
        var measures = (0..<8).map { ScoreMeasure(index: $0, items: []) }
        measures[1].items = [note(0, 64)]
        let pages = ScoreLayout.paginate(score: doc(measures), title: "T", instrument: .violin)
        let page = pages[0]
        let sys = page.systems[0]
        let m0 = sys.measures[0], m1 = sys.measures[1]
        let y = sys.strips[0].top + 2 * sys.spacing
        // A tap in bar 0's right pad — past its last head, before the barline.
        let t = try! XCTUnwrap(ScoreLayout.time16ths(at: CGPoint(x: m0.x + m0.width - 2, y: y),
                                                     page: page))
        XCTAssertEqual(t, 16, accuracy: 1e-9, "the end of bar 0 == the downbeat of bar 1")
        // …and the cursor for that time draws on bar 1's downbeat, on the same page.
        let ph = try! XCTUnwrap(ScoreLayout.playhead(at: t, pages: pages))
        XCTAssertEqual(ph.x, ScoreLayout.xPosition(fractional16ths: 0, measureX: m1.x,
                                                   measureWidth: m1.width), accuracy: 1e-9)
        // The LEFT pad clamps the other way: it is that bar's own downbeat, never the bar before.
        let left = try! XCTUnwrap(ScoreLayout.time16ths(at: CGPoint(x: m1.x + 1, y: y), page: page))
        XCTAssertEqual(left, 16, accuracy: 1e-9)
        // Which makes the whole strip between two heads monotonic in time — no bar ever reads
        // backwards, whichever side of a barline the finger lands.
        let ts = stride(from: m0.x + 1, to: m1.x + m1.width - 1, by: 3)
            .map { ScoreLayout.time16ths(at: CGPoint(x: $0, y: y), page: page) ?? -1 }
        for i in 1..<ts.count { XCTAssertGreaterThanOrEqual(ts[i], ts[i - 1]) }
    }

    /// Score-clock ms ↔ fractional 16ths must invert too — the seek is expressed in the same ms
    /// the cursor is READ from, so a tap can't land the cursor a beat off what it computed.
    func testMsInvertsCursor16ths() {
        for bpm in [90.0, 120, 137.5] {
            for ms in [0, 125, 500, 1_003, 60_000] {
                let t = ScorePlayhead.cursor16ths(ms: ms, bpm: bpm)
                XCTAssertEqual(ScorePlayhead.ms(fractional16ths: t, bpm: bpm), ms,
                               "ms → 16ths → ms must round-trip at \(bpm) BPM")
            }
        }
        // Degenerate inputs degrade, never trap (the StaffChordView Int.min lesson).
        XCTAssertEqual(ScorePlayhead.ms(fractional16ths: .nan, bpm: 120), 0)
        XCTAssertEqual(ScorePlayhead.ms(fractional16ths: -50, bpm: 120), 0)
        XCTAssertEqual(ScorePlayhead.ms(fractional16ths: .infinity, bpm: 120), 0)
        XCTAssertLessThanOrEqual(ScorePlayhead.ms(fractional16ths: 1e300, bpm: 120), 86_400_000)
    }

    /// THE behavioural contract of the seek: the state after tapping a note's head is IDENTICAL to
    /// the state playback would be in having reached that note naturally — same current note, same
    /// played-behind set, same sounding flag. (Tapping is only ever a different way to set the
    /// clock; everything else is derived from it.)
    func testSeekingToANoteHeadYieldsTheSameStateAsPlayingThere() {
        // 120 BPM ⇒ a 16th is 125 ms. Three notes: onsets 0, 4 (500 ms) and 20 (2500 ms).
        let events = [StudioNoteEvent(onMs: 0, offMs: 250, note: 64, velocity: 90),
                      StudioNoteEvent(onMs: 500, offMs: 900, note: 67, velocity: 90),
                      StudioNoteEvent(onMs: 2_500, offMs: 2_900, note: 72, velocity: 90)]
        let score = ScoreQuantizer.quantize(events: events, bpm: 120, instrument: .violin)
        let pages = ScoreLayout.paginate(score: score, title: "T", instrument: .violin)
        let slots = ScorePlayhead.timeline(events: events, bpm: 120)
        let head = try! XCTUnwrap(ScoreLayout.notePoint(midi: 67, accidental: nil, onset16ths: 4,
                                                        plan: .treble, pages: pages))
        // The tap: the second note's head, converted through the inverse the view uses.
        let t = try! XCTUnwrap(ScoreLayout.time16ths(at: head.point, page: pages[head.page]))
        let seekedMs = ScorePlayhead.ms(fractional16ths: t, bpm: 120)
        XCTAssertEqual(seekedMs, 500, "tapping the head at onset 4 seeks to its own 500 ms")
        let seeked = ScorePlayhead.state(atMs: seekedMs, slots: slots, bpm: 120)
        let played = ScorePlayhead.state(atMs: 500, slots: slots, bpm: 120)
        XCTAssertEqual(seeked, played)
        XCTAssertEqual(seeked.currentOnset16ths, 4)
        XCTAssertTrue(seeked.isSounding)
        XCTAssertTrue(seeked.isPlayed(onset16ths: 0), "the earlier note reads as played behind")
        XCTAssertFalse(seeked.isPlayed(onset16ths: 20), "the later note does not")
        // And seeking BACKWARDS un-plays what is now ahead of the cursor.
        let back = ScorePlayhead.state(atMs: ScorePlayhead.ms(fractional16ths: 0, bpm: 120),
                                       slots: slots, bpm: 120)
        XCTAssertEqual(back, ScorePlayhead.state(atMs: 0, slots: slots, bpm: 120))
        XCTAssertFalse(back.isPlayed(onset16ths: 4))
    }

    /// The tap and the note editor must resolve the SAME bar: `locate` (note entry) and
    /// `time16ths` (seek) share one measure resolution, so a tap can never edit measure 5 while
    /// seeking into measure 6.
    func testLocateAndTime16thsAgreeOnTheTappedMeasure() {
        var measures = (0..<12).map { ScoreMeasure(index: $0, items: []) }
        measures[7].items = [note(4, 64)]
        let pages = ScoreLayout.paginate(score: doc(measures), title: "T", instrument: .violin)
        let np = try! XCTUnwrap(ScoreLayout.notePoint(midi: 64, accidental: nil,
                                                      onset16ths: 7 * 16 + 4, plan: .treble,
                                                      pages: pages))
        let loc = try! XCTUnwrap(ScoreLayout.locate(point: np.point, page: pages[np.page]))
        let t = try! XCTUnwrap(ScoreLayout.time16ths(at: np.point, page: pages[np.page]))
        XCTAssertEqual(loc.measureIndex, 7)
        XCTAssertEqual(Int(t) / 16, loc.measureIndex)
        XCTAssertEqual(Int(t.rounded()) % 16, loc.onset16ths)
    }

    func testPlayedMarksAreEmptyWithoutNotesOrPages() {
        let pages = ScoreLayout.paginate(score: doc([ScoreMeasure(index: 0, items: [note(0, 64)])]),
                                         title: "T", instrument: .violin)
        XCTAssertTrue(ScoreLayout.playedMarks(events: [], bpm: 120, plan: .treble, pages: pages).isEmpty)
        XCTAssertTrue(ScoreLayout.playedMarks(events: [StudioNoteEvent(onMs: 0, offMs: 1, note: 64,
                                                                       velocity: 90)],
                                              bpm: 120, plan: .treble, pages: []).isEmpty)
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

import XCTest
@testable import PocketDJ

/// DemuxInstrumental (Studio/Demux/DemuxInstrumental.swift) — the pure chord-comping converter
/// (F8 slice A). Hermetic integer/beat math, plus the round-trip through ScoreQuantizer that the
/// score/replay actually consume. 120 BPM ⇒ one beat = 500 ms, one 16th = 125 ms.
final class DemuxInstrumentalTests: XCTestCase {

    private func chord(_ root: Int, _ minor: Bool, _ start: Int, _ end: Int) -> DemuxChordSegment {
        DemuxChordSegment(rootPC: root, minor: minor, startMs: start, endMs: end, confidence: 0.9)
    }

    // MARK: beatsSpanned

    func testBeatsSpannedConstantGrid() {
        // A 2-beat chord at 120 BPM on a constant grid: round(1000·120/60000) = 2.
        XCTAssertEqual(DemuxInstrumental.beatsSpanned(startMs: 0, endMs: 1000,
                                                      grid: (120, 0, [])), 2)
        // A sub-beat chord still holds for one beat (min 1).
        XCTAssertEqual(DemuxInstrumental.beatsSpanned(startMs: 0, endMs: 120,
                                                      grid: (120, 0, [])), 1)
        // Four beats.
        XCTAssertEqual(DemuxInstrumental.beatsSpanned(startMs: 0, endMs: 2000,
                                                      grid: (120, 0, [])), 4)
    }

    func testBeatsSpannedRealLattice() {
        // Measured (drift-carrying) grid: count the beats that fall inside [start,end).
        let beats = [0, 500, 1000, 1500, 2000, 2500]
        XCTAssertEqual(DemuxInstrumental.beatsSpanned(startMs: 0, endMs: 1000,
                                                      grid: (120, 0, beats)), 2)  // {0,500}
        XCTAssertEqual(DemuxInstrumental.beatsSpanned(startMs: 500, endMs: 2000,
                                                      grid: (120, 0, beats)), 3)  // {500,1000,1500}
        // A chord entirely between two measured beats still gets one beat.
        XCTAssertEqual(DemuxInstrumental.beatsSpanned(startMs: 600, endMs: 700,
                                                      grid: (120, 0, beats)), 1)
    }

    // MARK: events — duration, triad, anchor

    func testTwoBeatChordIsOneThousandMsEightSixteenths() {
        let (events, bpm) = DemuxInstrumental.events(chords: [chord(0, false, 0, 1000)],
                                                     grid: (120, 0, []))
        XCTAssertEqual(bpm, 120)
        XCTAssertEqual(events.count, 3, "a triad = 3 same-onset notes")
        for e in events {
            XCTAssertEqual(e.offMs - e.onMs, 1000, "2 beats @120 = 1000 ms")
        }
        // 1000 ms = 8 sixteenths at 120 BPM (a half note).
        XCTAssertEqual(1000.0 / ScoreQuantizer.sixteenthMs(bpm: 120), 8, accuracy: 0.001)
    }

    func testFullTriadEmittedForMajorAndMinor() {
        // C major → 60/64/67; A minor → 69/72/76 (root, minor 3rd, 5th), base octave 60/C4.
        let major = DemuxInstrumental.events(chords: [chord(0, false, 0, 1000)], grid: (120, 0, [])).events
        XCTAssertEqual(Set(major.map(\.note)), [60, 64, 67])
        let minor = DemuxInstrumental.events(chords: [chord(9, true, 0, 1000)], grid: (120, 0, [])).events
        XCTAssertEqual(Set(minor.map(\.note)), [69, 72, 76])
    }

    func testSameOnsetTriadMergesIntoOneChordScoreItem() {
        // The triad's three same-onset notes must collapse to ONE chord item in the score.
        let events = DemuxInstrumental.events(chords: [chord(0, false, 0, 1000)], grid: (120, 0, [])).events
        let doc = ScoreQuantizer.quantize(events: events, bpm: 120, instrument: .piano)
        XCTAssertEqual(doc.measures.count, 1)
        // Exactly ONE sounding (chord) item — the three same-onset notes collapsed, not three
        // separate items. (The measure's remaining 8 sixteenths are a trailing rest, item #2.)
        let noteItems = doc.measures[0].items.filter {
            if case .notes = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(noteItems.count, 1, "one chord item, not three notes")
        XCTAssertEqual(noteItems.first?.kind, .notes([60, 64, 67]))
        XCTAssertEqual(noteItems.first?.duration, .half)  // 8 sixteenths
    }

    func testReanchorPutsBeatOneAtZero() {
        // A grid whose beat 1 is at 500 ms: the chord starting there must land at onMs 0.
        let events = DemuxInstrumental.events(chords: [chord(0, false, 500, 1500)],
                                              grid: (120, 500, [])).events
        XCTAssertEqual(events.map(\.onMs), [0, 0, 0])
    }

    func testChordStartSnapsToNearestBeat() {
        // A ragged chromagram start (520 ms) snaps to the beat at 500 ms (constant grid, anchor 0).
        let events = DemuxInstrumental.events(chords: [chord(0, false, 520, 1000)],
                                              grid: (120, 0, [])).events
        XCTAssertEqual(events.first?.onMs, 500)
    }

    func testGapBetweenChordsBecomesRestNotAnInventedChord() {
        // Two short chords with a hole between them: the quantizer must fill the hole with a rest.
        let events = DemuxInstrumental.events(
            chords: [chord(0, false, 0, 500), chord(5, false, 1500, 2000)],
            grid: (120, 0, [])).events
        let doc = ScoreQuantizer.quantize(events: events, bpm: 120, instrument: .piano)
        let hasRest = doc.measures.contains { m in
            m.items.contains { if case .rest = $0.kind { return true } else { return false } }
        }
        XCTAssertTrue(hasRest, "the silent region between chords is a rest, never a fabricated chord")
    }

    // MARK: collision + clamp guards (FIX 4)

    func testCollidingOnsetsKeepHigherConfidenceNotUnion() {
        // Two sub-beat chords near the SAME beat both snap to onset 0 (start 0 and start 120 both
        // round to the beat at 0 @120 BPM). The converter must keep ONE triad — the higher-
        // confidence chord — not union both into a 6-note cluster (which ScoreQuantizer would fuse
        // into a single chord item, silently dropping the other chord).
        let strong = chord(0, false, 0, 200)      // C major, confidence 0.9
        var weak = chord(5, false, 120, 300)      // F major, lower confidence
        weak.confidence = 0.4
        let events = DemuxInstrumental.events(chords: [strong, weak], grid: (120, 0, [])).events
        XCTAssertEqual(Set(events.map(\.onMs)), [0], "both chords snapped to the same onset")
        XCTAssertEqual(events.count, 3, "one triad survives, not two unioned into 6 notes")
        XCTAssertEqual(Set(events.map(\.note)), [60, 64, 67], "kept C major — the higher-confidence chord")
    }

    func testCollidingOnsetsTieKeepsEarlierChord() {
        // Equal confidence: the EARLIER chord (seen first in start order) holds the beat.
        let first = chord(0, false, 0, 200)       // C major, conf 0.9
        let second = chord(5, false, 120, 300)    // F major, conf 0.9 (same)
        let events = DemuxInstrumental.events(chords: [first, second], grid: (120, 0, [])).events
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.note)), [60, 64, 67], "the earlier chord wins a confidence tie")
    }

    func testSnapNeverPushesOnsetPastChordEnd() {
        // A short chord ending just before the next beat: snapToBeat would land its start at 500,
        // past the chord's own end (480). The onset must be clamped so it never sounds after the
        // chord existed.
        let events = DemuxInstrumental.events(chords: [chord(0, false, 470, 480)],
                                              grid: (120, 0, [])).events
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.onMs <= 480 },
                      "onset clamped to the chord's own end (never snapped past it)")
    }

    func testGuardsZeroBpmToDefault() {
        let (_, bpm) = DemuxInstrumental.events(chords: [chord(0, false, 0, 1000)], grid: (0, 0, []))
        XCTAssertEqual(bpm, 120)
    }

    func testNoChordsYieldsNoEvents() {
        XCTAssertTrue(DemuxInstrumental.events(chords: [], grid: (120, 0, [])).events.isEmpty)
    }

    // MARK: playhead → score system mapping (the follow view's clock math)

    func testSystemIndexMapsPlayheadToSystem() {
        // 4 measures/system. Measure 5 (abs16 80 ⇒ 10 000 ms @120) sits in system 1.
        XCTAssertEqual(FollowScoreView.systemIndex(playheadMs: 10_000, firstDownbeatMs: 0,
                                                   bpm: 120, systemCount: 5), 1)
        // Beat 1 → system 0.
        XCTAssertEqual(FollowScoreView.systemIndex(playheadMs: 0, firstDownbeatMs: 0,
                                                   bpm: 120, systemCount: 5), 0)
        // Past the end clamps to the last system.
        XCTAssertEqual(FollowScoreView.systemIndex(playheadMs: 10_000_000, firstDownbeatMs: 0,
                                                   bpm: 120, systemCount: 5), 4)
        // Empty score never divides by zero.
        XCTAssertEqual(FollowScoreView.systemIndex(playheadMs: 5_000, firstDownbeatMs: 0,
                                                   bpm: 120, systemCount: 0), 0)
    }

    func testSystemIndexSubtractsFirstDownbeat() {
        // firstDownbeat 2000 ms: a 10 000 ms playhead is score-time 8000 ms = measure 4 = system 1.
        XCTAssertEqual(FollowScoreView.systemIndex(playheadMs: 10_000, firstDownbeatMs: 2_000,
                                                   bpm: 120, systemCount: 5), 1)
    }
}

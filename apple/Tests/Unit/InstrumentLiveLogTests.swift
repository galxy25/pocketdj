import XCTest
import AVFoundation
@testable import PocketDJ

/// The always-on LIVE capture in `InstrumentEventLog` (Studio round 4, "one editable staff").
/// Deterministic via `AVAudioTime.hostTime(forSeconds:)` to synthesize host times a fixed number
/// of ms apart — the same mach timebase the log converts through.
final class InstrumentLiveLogTests: XCTestCase {

    /// A host time `sec` seconds after `base`.
    private func host(after base: UInt64, _ sec: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: AVAudioTime.seconds(forHostTime: base) + sec)
    }

    func testLiveCaptureAccumulatesCompletedNotes() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.liveOn(note: 60, velocity: 96, hostTime: t0)                 // anchor = first note
        log.liveOff(note: 60, hostTime: host(after: t0, 0.5))
        log.liveOn(note: 62, velocity: 80, hostTime: host(after: t0, 0.5))
        log.liveOff(note: 62, hostTime: host(after: t0, 1.0))

        let live = log.snapshotLiveIfDirty()
        XCTAssertEqual(live?.count, 2)
        XCTAssertEqual(live?[0].note, 60)
        XCTAssertEqual(live?[0].onMs, 0)                                 // first note anchors t0
        XCTAssertEqual(live?[0].offMs ?? -1, 500, accuracy: 3)
        XCTAssertEqual(live?[1].onMs ?? -1, 500, accuracy: 3)

        // Coalesced: a second drain with no change publishes nothing.
        XCTAssertNil(log.snapshotLiveIfDirty())
    }

    func testHeldNoteAppearsOnlyAfterRelease() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.liveOn(note: 64, velocity: 96, hostTime: t0)
        XCTAssertEqual(log.snapshotLiveIfDirty()?.count, 0, "a held note isn't a completed event yet")
        log.liveOff(note: 64, hostTime: host(after: t0, 0.25))
        XCTAssertEqual(log.snapshotLiveIfDirty()?.count, 1)
    }

    func testSetLiveReplacesAndClearResets() {
        let log = InstrumentEventLog()
        log.liveOn(note: 60, velocity: 96, hostTime: mach_absolute_time())
        _ = log.snapshotLiveIfDirty()

        log.setLive([StudioNoteEvent(onMs: 0, offMs: 250, note: 67, velocity: 96, accidental: .flat)])
        let edited = log.snapshotLiveIfDirty()
        XCTAssertEqual(edited?.map(\.note), [67])
        XCTAssertEqual(edited?.first?.accidental, .flat)

        log.clearLive()
        XCTAssertEqual(log.snapshotLiveIfDirty()?.count, 0)
    }

    /// The engine wiring: an on-screen key (or MIDI) note fills `liveEvents` even with NO
    /// instrument loaded (capture is before the audible guard), and edits/clear round-trip.
    @MainActor
    func testEngineNoteFillsLiveEventsWithoutInstrument() {
        let engine = InstrumentEngine()
        engine.noteOn(60, velocity: 96)                 // no bank loaded → silent, but captured
        engine.noteOff(60)
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.liveEvents.count, 1)
        XCTAssertEqual(engine.liveEvents.first?.note, 60)

        engine.setLiveEvents([StudioNoteEvent(onMs: 0, offMs: 500, note: 64, velocity: 96, accidental: .flat)])
        XCTAssertEqual(engine.liveEvents.map(\.note), [64])
        XCTAssertEqual(engine.liveEvents.first?.accidental, .flat)

        engine.clearLiveEvents()
        XCTAssertTrue(engine.liveEvents.isEmpty)
    }

    func testTakeArmingIsIndependentOfLiveCapture() {
        // Live capture runs even when NOT armed for a take (the whole point of a free-play staff).
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.liveOn(note: 60, velocity: 96, hostTime: t0)
        log.liveOff(note: 60, hostTime: host(after: t0, 0.5))
        XCTAssertEqual(log.snapshotLiveIfDirty()?.count, 1)             // captured while un-armed
        XCTAssertEqual(log.recordedCount, 0)                            // …but the TAKE log stayed empty
    }

    // MARK: Arp record mode (keys SELECT, sound once, write NOTHING to any score)

    /// Record mode's contract: a key press toggles arp-set membership (insertion-ordered — the
    /// `.order` mode's source) and never reaches the live staff; a re-press removes silently.
    @MainActor
    func testArpRecordModeSelectsAndWritesNothing() {
        let engine = InstrumentEngine()
        engine.arpEnabled = true
        engine.arpRecording = true
        engine.noteOn(67); engine.noteOff(67)
        engine.noteOn(60); engine.noteOff(60)
        engine.noteOn(64); engine.noteOff(64)
        XCTAssertEqual(engine.arpSelectedNotes, [67, 60, 64], "insertion order preserved")
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.liveEvents.isEmpty, "record mode writes NOTHING to the live staff")

        engine.noteOn(60); engine.noteOff(60)                // re-press ⇒ remove (toggle)
        XCTAssertEqual(engine.arpSelectedNotes, [67, 64])
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.liveEvents.isEmpty)

        engine.arpClearSelection()
        XCTAssertTrue(engine.arpSelectedNotes.isEmpty)

        // Arp OFF ⇒ keys are plain keys again (live capture resumes).
        engine.arpEnabled = false
        engine.noteOn(62); engine.noteOff(62)
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.liveEvents.map(\.note), [62])
        engine.teardown()
    }

    /// Toggling Arp off keeps the recorded set (off/on is non-destructive); Clear is the reset.
    @MainActor
    func testArpToggleOffKeepsSelection() {
        let engine = InstrumentEngine()
        engine.arpEnabled = true
        engine.arpRecording = true
        engine.noteOn(60); engine.noteOff(60)
        engine.arpEnabled = false
        XCTAssertEqual(engine.arpSelectedNotes, [60], "the set survives an off/on toggle")
        XCTAssertFalse(engine.arpRecording, "record mode exits with the master switch")
        engine.teardown()
    }

    // MARK: Overdub capture stream (the third stream — anchored at a chosen score position)

    /// The overdub log anchors captured notes at `baseMs + elapsed` — ABSOLUTE on the score
    /// clock, so a staff recorded from position P starts at `onMs ≥ P`.
    func testOverdubLogAnchorsAtPosition() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.overdubArm(anchorHostTime: t0, baseMs: 4_000)
        log.overdubOn(note: 60, velocity: 90, hostTime: host(after: t0, 0.25))
        log.overdubOff(note: 60, hostTime: host(after: t0, 0.75))
        log.overdubOn(note: 64, velocity: 80, hostTime: host(after: t0, 0.75))   // left open
        let events = log.overdubDisarmAndFinish(atHostTime: host(after: t0, 1.0))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].note, 60)
        XCTAssertEqual(Double(events[0].onMs), 4_250, accuracy: 3)
        XCTAssertEqual(Double(events[0].offMs), 4_750, accuracy: 3)
        XCTAssertEqual(events[1].note, 64)
        XCTAssertEqual(Double(events[1].offMs), 5_000, accuracy: 3,
                       "an open note is closed at the disarm instant")
        XCTAssertTrue(log.overdubDisarmAndFinish(atHostTime: host(after: t0, 2.0)).isEmpty,
                      "a second disarm returns nothing (stream already closed)")
    }

    /// Pre-anchor stamps are dropped (the count-in convention), and un-armed calls are no-ops.
    func testOverdubLogDropsPreAnchorAndUnarmedNotes() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.overdubOn(note: 60, velocity: 90, hostTime: t0)               // never armed
        XCTAssertTrue(log.overdubDisarmAndFinish(atHostTime: host(after: t0, 1.0)).isEmpty)

        let anchor = host(after: t0, 10)                                  // anchor in the future
        log.overdubArm(anchorHostTime: anchor, baseMs: 1_000)
        log.overdubOn(note: 60, velocity: 90, hostTime: t0)               // BEFORE the anchor
        log.overdubOn(note: 64, velocity: 90, hostTime: host(after: anchor, 0.5))
        log.overdubOff(note: 64, hostTime: host(after: anchor, 1.0))
        let events = log.overdubDisarmAndFinish(atHostTime: host(after: anchor, 1.5))
        XCTAssertEqual(events.map(\.note), [64], "the pre-anchor press never entered the capture")
        XCTAssertEqual(Double(events[0].onMs), 1_500, accuracy: 3)
    }

    /// The ENGINE surface: arm/stop round-trip, double-arm refused, mid-take refused.
    @MainActor
    func testEngineOverdubArmStopSurface() {
        let engine = InstrumentEngine()
        XCTAssertTrue(engine.startOverdub(fromMs: 2_000))
        XCTAssertTrue(engine.overdubActive)
        XCTAssertEqual(engine.overdubBaseMs, 2_000)
        XCTAssertFalse(engine.startOverdub(fromMs: 3_000), "double-arm refused")
        engine.noteOn(60); engine.noteOff(60)
        let events = engine.stopOverdub()
        XCTAssertFalse(engine.overdubActive)
        XCTAssertEqual(events.map(\.note), [60])
        XCTAssertGreaterThanOrEqual(events[0].onMs, 2_000, "captured ABSOLUTE at base + elapsed")
        XCTAssertTrue(engine.stopOverdub().isEmpty, "a second stop returns nothing")
        // Overdub notes belong to the NEW staff ONLY — they must NOT double-write into the
        // always-on live staff (the record-leak fix: staff 1 would otherwise gain a copy of
        // every overdubbed note at the live log's own anchor).
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.liveEvents.isEmpty,
                      "overdub notes never leak into the live free-play staff")
        engine.teardown()
    }

    /// A note pressed BEFORE the overdub arms still closes into the live staff on release
    /// (liveOff stays unconditional and self-guards), while notes pressed DURING the overdub
    /// stay out of the live stream entirely.
    @MainActor
    func testOverdubStraddleClosesLiveNoteWithoutLeaking() {
        let engine = InstrumentEngine()
        engine.noteOn(48)                                  // live note, held across the arm
        XCTAssertTrue(engine.startOverdub(fromMs: 1_000))
        engine.noteOn(60)                                  // overdub-only note
        engine.noteOff(60)
        engine.noteOff(48)                                 // straddler closes into LIVE
        let captured = engine.stopOverdub()
        XCTAssertEqual(captured.map(\.note), [60], "only the overdub-armed press is captured")
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.liveEvents.map(\.note), [48],
                       "the straddling note completes in the live staff; 60 never appears")
        engine.teardown()
    }
}

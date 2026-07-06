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
}

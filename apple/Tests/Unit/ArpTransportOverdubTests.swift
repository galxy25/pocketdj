import XCTest
import AVFoundation
@testable import PocketDJ

// MARK: - Arp Program/transport split · live-score capture · the CONFINED overdub region
//
// The refinement round on the Studio arpeggiator + overdub feature:
//   • "Record" is now PROGRAM — key taps pick the pattern's notes and write NOTHING to any
//     score, exactly as before, while a DEDICATED transport governs whether the pattern sounds
//     (so you hear it evolve as you program it);
//   • a PLAYING arp is a performance: every sounded step is captured like a hand-played key —
//     into the live score, or into the overdub staff while a pass is armed, never both;
//   • an overdub pass is CONFINED to [anchor → the score's end] — it can never lengthen the
//     score — with an optional LOOPER over that region;
//   • the monitoring metronome flips live without stopping a pass or writing anything.
//
// Audio is unreachable on CI (no sampler, no 32 MB bank), so the transport runs through
// `startArpPlaybackForTesting` — the shipped state machine and the shipped write path with the
// audible preconditions relaxed. Host times are synthesized through
// `AVAudioTime.hostTime(forSeconds:)`, the same mach timebase the log converts through.

@MainActor
final class ArpTransportCaptureTests: XCTestCase {

    /// A pattern of `notes`, programmed the way the panel does it (keys under Program mode).
    private func program(_ engine: InstrumentEngine, _ notes: [Int]) {
        engine.arpEnabled = true
        engine.arpProgramming = true
        for n in notes { engine.noteOn(n); engine.noteOff(n) }
        engine.arpProgramming = false
    }

    /// Quick but not knife-edge knobs: 1/16 steps at 120 BPM = 125 ms/step, so a two-note cycle
    /// is ~250 ms. Deliberately NOT the fastest grid available: the scheduler's first step fires
    /// whenever the Task gets the main actor, and on a 25 ms grid that startup latency swallows
    /// the opening gate — which would make a timing assertion a test of CI load, not of the arp.
    private func fastSettings(latch: Bool) -> ArpSettings {
        ArpSettings(order: .up, length: .sixteenth, octaves: 1, swingPct: 50, latch: latch)
    }

    private func waitUntil(timeout: Double = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    /// PROGRAM mode's invariant, unchanged by the rename: key taps select/deselect the pattern's
    /// notes (insertion-ordered — the `.order` source), each sounding once, and write NOTHING to
    /// any score — even with the transport running.
    func testProgramModeWritesNothing() async {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        program(engine, [67, 60])
        XCTAssertEqual(engine.arpSelectedNotes, [67, 60])
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.liveEvents.isEmpty, "programming writes nothing to the live score")

        // Same while the transport is PLAYING: adding a note mid-pattern is still an edit, not a
        // performance — the only score writes are the arp's own sounded steps.
        engine.arpSettings = fastSettings(latch: true)
        XCTAssertTrue(engine.startArpPlaybackForTesting(bpm: 120))
        engine.arpProgramming = true
        engine.noteOn(64); engine.noteOff(64)
        XCTAssertEqual(engine.arpSelectedNotes, [67, 60, 64], "the tap programmed, it didn't play")
        engine.stopArpPlayback()
        engine.arpProgramming = false
        engine.pumpLiveOnceForTesting()
        XCTAssertFalse(engine.liveEvents.contains { $0.note == 64 && $0.onMs == 0 },
                       "no key-tap event: 64 only ever appears as a scheduled arp step")
    }

    /// A PLAYING arp writes to the LIVE score exactly as hand-played keys do, with the arp's own
    /// onset/gate timing (ascending onsets, a real gate on each step).
    func testArpPlayWritesLiveScore() async {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        program(engine, [60, 64])
        engine.arpSettings = fastSettings(latch: false)          // exactly one cycle
        XCTAssertTrue(engine.startArpPlaybackForTesting(bpm: 120))
        let cycled = await waitUntil { !engine.arpPlaying }
        XCTAssertTrue(cycled, "one cycle then auto-pause")
        engine.pumpLiveOnceForTesting()

        XCTAssertEqual(engine.liveEvents.map(\.note), [60, 64],
                       "every sounded step landed on the live staff, in pattern order")
        XCTAssertEqual(engine.liveEvents[0].onMs, 0, "the first step anchors the live stream")
        XCTAssertGreaterThan(engine.liveEvents[1].onMs, engine.liveEvents[0].onMs,
                             "onsets follow the arp clock, not one instant")
        for e in engine.liveEvents {
            XCTAssertGreaterThan(e.offMs, e.onMs, "each step keeps its gate")
        }
    }

    /// While an overdub pass is armed the arp's notes belong to the OVERDUB staff — never
    /// double-written into the live score (the hand-key rule, applied to the arp).
    func testArpPlayWhileOverdubArmedWritesStaffNotLive() {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        program(engine, [60, 64])
        XCTAssertTrue(engine.startOverdub(fromMs: 2_000))
        engine.arpStepForTesting(note: 60, on: true)
        engine.arpStepForTesting(note: 60, on: false)
        engine.arpStepForTesting(note: 64, on: true)
        engine.arpStepForTesting(note: 64, on: false)
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.liveEvents.isEmpty, "no double-write into the live score")
        XCTAssertEqual(engine.overdubEvents.map(\.note), [60, 64])

        let captured = engine.stopOverdub()
        XCTAssertEqual(captured.map(\.note), [60, 64])
        XCTAssertGreaterThanOrEqual(captured[0].onMs, 2_000, "absolute on the score clock")

        // Pass over ⇒ the arp writes to the live score again.
        engine.arpStepForTesting(note: 67, on: true)
        engine.arpStepForTesting(note: 67, on: false)
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.liveEvents.map(\.note), [67])
    }

    /// ⏸ stops the writes: nothing lands after the transport pauses, and no onset hangs.
    func testPauseStopsWrites() async {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        program(engine, [60, 64])
        engine.arpSettings = fastSettings(latch: true)           // loops until paused
        XCTAssertTrue(engine.startArpPlaybackForTesting(bpm: 120))
        let filled = await waitUntil {
            engine.pumpLiveOnceForTesting()
            return !engine.liveEvents.isEmpty
        }
        XCTAssertTrue(filled, "the running transport fills the live staff")

        engine.stopArpPlayback()
        XCTAssertFalse(engine.arpPlaying)
        engine.pumpLiveOnceForTesting()
        let atPause = engine.liveEvents.count
        try? await Task.sleep(nanoseconds: 600_000_000)          // ≫ two arp cycles
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.liveEvents.count, atPause, "a paused arp writes nothing more")
    }

    /// Latch OFF plays exactly one cycle and pauses ITSELF — the transport button reads that
    /// state, so it flips back to ▶ with no user action.
    func testLatchOffAutoPauseReflectedInState() async {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        program(engine, [60, 64, 67])
        engine.arpSettings = fastSettings(latch: false)
        XCTAssertTrue(engine.startArpPlaybackForTesting(bpm: 120))
        XCTAssertTrue(engine.arpPlaying)
        let autoPaused = await waitUntil { !engine.arpPlaying }
        XCTAssertTrue(autoPaused, "auto-paused after one cycle")
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.liveEvents.map(\.note), [60, 64, 67], "exactly one cycle")
    }
}

// MARK: - The confined overdub region + the looper

final class OverdubRegionTests: XCTestCase {

    private func host(after base: UInt64, _ sec: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: AVAudioTime.seconds(forHostTime: base) + sec)
    }

    /// Loop OFF: the pass accepts nothing at/after the region's end, a held note closes AT the
    /// boundary, and the capture therefore never extends the score.
    func testOverdubConfinedToRegion() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.overdubArm(anchorHostTime: t0, baseMs: 1_000, regionEndMs: 3_000, loop: false)
        XCTAssertFalse(log.overdubRegionExhausted(atHostTime: host(after: t0, 0.5)))

        log.overdubOn(note: 60, velocity: 90, hostTime: host(after: t0, 0.5))     // 1500
        log.overdubOff(note: 60, hostTime: host(after: t0, 1.0))                  // 2000
        log.overdubOn(note: 64, velocity: 90, hostTime: host(after: t0, 1.5))     // 2500, held past the end
        log.overdubOn(note: 67, velocity: 90, hostTime: host(after: t0, 2.5))     // 3500 — OUTSIDE
        log.overdubOff(note: 67, hostTime: host(after: t0, 2.7))
        XCTAssertTrue(log.overdubRegionExhausted(atHostTime: host(after: t0, 2.5)),
                      "past the region ⇒ the pass auto-finalizes")

        let events = log.overdubDisarmAndFinish(atHostTime: host(after: t0, 4.0))
        XCTAssertEqual(events.map(\.note), [60, 64], "the post-boundary strike was discarded")
        XCTAssertEqual(events[1].offMs, 3_000, "the held note closes AT the boundary")
        XCTAssertEqual(events.map(\.offMs).max(), 3_000, "the score's length is unchanged")
    }

    /// A LOOPING pass never exhausts — it wraps forever until the user ends it.
    func testLoopingPassNeverExhausts() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.overdubArm(anchorHostTime: t0, baseMs: 0, regionEndMs: 1_000, loop: true)
        XCTAssertFalse(log.overdubRegionExhausted(atHostTime: host(after: t0, 9.0)))
        _ = log.overdubDisarmAndFinish(atHostTime: host(after: t0, 9.0))
    }

    /// Loop ON: iteration k's strikes land WRAPPED into the region, layering into one capture.
    func testLoopOnWrapsNotePositionsIntoRegion() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.overdubArm(anchorHostTime: t0, baseMs: 1_000, regionEndMs: 3_000, loop: true)  // len 2000
        log.overdubOn(note: 60, velocity: 90, hostTime: host(after: t0, 0.5))    // iter 0 → 1500
        log.overdubOff(note: 60, hostTime: host(after: t0, 0.7))                 // → 1700
        log.overdubOn(note: 64, velocity: 90, hostTime: host(after: t0, 2.5))    // iter 1 → 1500
        log.overdubOff(note: 64, hostTime: host(after: t0, 2.7))                 // → 1700
        log.overdubOn(note: 67, velocity: 90, hostTime: host(after: t0, 4.1))    // iter 2 → 1100
        log.overdubOff(note: 67, hostTime: host(after: t0, 4.3))

        let events = log.overdubDisarmAndFinish(atHostTime: host(after: t0, 4.5))
        XCTAssertEqual(events.count, 3, "every iteration LAYERS into the same staff")
        for e in events {
            XCTAssertGreaterThanOrEqual(e.onMs, 1_000)
            XCTAssertLessThan(e.onMs, 3_000, "positions wrap INTO the region")
            XCTAssertLessThanOrEqual(e.offMs, 3_000, "the loop never extends the score")
        }
        let byNote = Dictionary(uniqueKeysWithValues: events.map { ($0.note, $0) })
        XCTAssertEqual(Double(byNote[60]!.onMs), 1_500, accuracy: 5)
        XCTAssertEqual(Double(byNote[64]!.onMs), 1_500, accuracy: 5, "iteration 1 lands on iteration 0")
        XCTAssertEqual(Double(byNote[67]!.onMs), 1_100, accuracy: 5)
    }

    /// A note held ACROSS the wrap closes at the boundary — no onset ever hangs into the next
    /// iteration (which would paint a note stretching the whole region).
    func testLoopWrapClosesHeldNotes() {
        let log = InstrumentEventLog()
        let t0 = mach_absolute_time()
        log.overdubArm(anchorHostTime: t0, baseMs: 0, regionEndMs: 2_000, loop: true)
        log.overdubOn(note: 72, velocity: 90, hostTime: host(after: t0, 1.9))    // iter 0 → 1900
        log.overdubOff(note: 72, hostTime: host(after: t0, 2.3))                 // iter 1 ⇒ close at 2000
        let events = log.overdubDisarmAndFinish(atHostTime: host(after: t0, 2.4))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(Double(events[0].onMs), 1_900, accuracy: 5)
        XCTAssertEqual(events[0].offMs, 2_000, "closed AT the wrap, not carried across it")
    }

    /// The region the engine arms is exactly [anchor → the score's end], and `scoreEndMs` is what
    /// both score screens derive it from.
    @MainActor
    func testLoopRegionEqualsAnchorToScoreEnd() {
        let staff1 = [StudioNoteEvent(onMs: 0, offMs: 500, note: 60, velocity: 96),
                      StudioNoteEvent(onMs: 500, offMs: 4_800, note: 62, velocity: 96)]
        let staff2 = [StudioNoteEvent(onMs: 1_000, offMs: 3_200, note: 67, velocity: 96)]
        let end = InstrumentEngine.scoreEndMs(staffs: [staff1, staff2])
        XCTAssertEqual(end, 4_800, "the last note-off across every staff")
        XCTAssertEqual(InstrumentEngine.scoreEndMs(staffs: [[], []]), 0, "an empty score has no end")

        let engine = InstrumentEngine()
        defer { engine.teardown() }
        XCTAssertTrue(engine.startOverdub(fromMs: 1_200, scoreEndMs: end, loop: true))
        XCTAssertEqual(engine.overdubBaseMs, 1_200)
        XCTAssertEqual(engine.overdubRegionEndMs, end)
        XCTAssertTrue(engine.overdubLoop)
        _ = engine.stopOverdub()

        // A cursor parked AT/past the end has no region to confine to — the legacy unbounded
        // pass (this is the only way to overdub onto an empty instrumental at all).
        XCTAssertTrue(engine.startOverdub(fromMs: 9_000, scoreEndMs: end, loop: true))
        XCTAssertEqual(engine.overdubRegionEndMs, .max)
        XCTAssertFalse(engine.overdubLoop, "no region ⇒ no wrap point")
        _ = engine.stopOverdub()
    }

    /// The ENGINE's auto-finalize signal: a pass whose region is already spent accepts nothing,
    /// publishes `overdubReachedEnd` on the pump, and hands back a capture no longer than the
    /// score it was recorded over.
    @MainActor
    func testRegionExhaustionPublishesAutoFinalize() {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        // Anchor 5 s in the PAST with a 1 s region ⇒ the pass is already past its end.
        let past = AVAudioTime.hostTime(forSeconds:
            AVAudioTime.seconds(forHostTime: mach_absolute_time()) - 5)
        XCTAssertTrue(engine.startOverdub(fromMs: 0, anchorHostTime: past, scoreEndMs: 1_000))
        XCTAssertFalse(engine.overdubReachedEnd)
        engine.noteOn(60); engine.noteOff(60)                    // struck past the boundary
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.overdubReachedEnd, "the view finalizes on this")
        let events = engine.stopOverdub()
        XCTAssertTrue(events.isEmpty, "post-boundary strikes are discarded, never written")
        XCTAssertFalse(engine.overdubReachedEnd, "the flag resets with the pass")
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.liveEvents.isEmpty, "and they never leaked into the live score")
    }

    /// The in-progress staff is PUBLISHED during the pass (req: the staff fills as you play) and
    /// handed off — not duplicated — when the pass is finalized.
    @MainActor
    func testOverdubStaffEventsVisibleDuringPassAndHandedOffAtEnd() {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        XCTAssertTrue(engine.startOverdub(fromMs: 0))
        engine.noteOn(60); engine.noteOff(60)
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.overdubEvents.map(\.note), [60],
                       "published BEFORE End overdub, while the pass is still armed")
        XCTAssertTrue(engine.overdubActive)

        engine.noteOn(64)
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.overdubEvents.count, 1, "a held note appears on release (live-staff rule)")
        engine.noteOff(64)
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.overdubEvents.map(\.note), [60, 64])

        let filed = engine.stopOverdub()
        XCTAssertEqual(filed.map(\.note), [60, 64], "End overdub returns the same notes ONCE")
        XCTAssertTrue(engine.overdubEvents.isEmpty,
                      "the in-progress staff vanishes as the finished one is filed — no duplicate")
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.overdubEvents.isEmpty)
        XCTAssertTrue(engine.liveEvents.isEmpty)
    }

    /// The looping backing's cursor folds back into the region instead of marching off the end.
    func testCursorWrapsIntoLoopRegion() {
        XCTAssertEqual(InstrumentEngine.wrapIntoLoop(ms: 2_500, region: (1_000, 3_000)), 2_500)
        XCTAssertEqual(InstrumentEngine.wrapIntoLoop(ms: 3_000, region: (1_000, 3_000)), 1_000)
        XCTAssertEqual(InstrumentEngine.wrapIntoLoop(ms: 4_500, region: (1_000, 3_000)), 2_500)
        XCTAssertEqual(InstrumentEngine.wrapIntoLoop(ms: 4_500, region: nil), 4_500)
        XCTAssertEqual(InstrumentEngine.wrapIntoLoop(ms: 500, region: (1_000, 1_000)), 500,
                       "a degenerate region is identity, never a divide-by-zero")
    }
}

// MARK: - The monitoring metronome (live toggle, monitoring ONLY)

final class MetronomeLiveToggleTests: XCTestCase {

    /// Flipping the click mid-pass keeps the take/pass rolling and writes NOTHING anywhere — the
    /// click node joins downstream of the take tap, so it is monitoring only.
    @MainActor
    func testMetronomeToggleMidTakeDoesNotWriteOrStop() {
        let engine = InstrumentEngine()
        defer { engine.teardown() }
        XCTAssertFalse(engine.clickEnabled, "OFF by default")

        XCTAssertTrue(engine.startOverdub(fromMs: 0))
        engine.noteOn(60); engine.noteOff(60)

        engine.setClickEnabled(true, bpm: 120)
        XCTAssertTrue(engine.clickEnabled)
        XCTAssertTrue(engine.overdubActive, "the pass keeps rolling through the flip")

        engine.noteOn(64); engine.noteOff(64)
        engine.setClickEnabled(false)
        XCTAssertFalse(engine.clickEnabled)
        XCTAssertTrue(engine.overdubActive, "and through the flip back")

        engine.noteOn(67); engine.noteOff(67)
        engine.pumpLiveOnceForTesting()
        XCTAssertEqual(engine.overdubEvents.map(\.note), [60, 64, 67],
                       "exactly the played notes — the click wrote nothing")
        let filed = engine.stopOverdub()
        XCTAssertEqual(filed.map(\.note), [60, 64, 67])
        engine.pumpLiveOnceForTesting()
        XCTAssertTrue(engine.liveEvents.isEmpty, "nor anything on the live score")
    }

    /// The live flip lands on the NEXT BEAT of the current grid (0 = the accented beat 1), and
    /// wild input degrades instead of trapping.
    func testNextBeatOnGridPhase() {
        let grid = 100.0, beat = 0.5
        let a = InstrumentEngine.nextBeatOnGrid(nowSec: 101.1, gridSec: grid, beatSec: beat, lead: 0)
        XCTAssertEqual(a.atSec, 101.5, accuracy: 0.0001)
        XCTAssertEqual(a.beatInBar, 3, "beat 4 of the bar")

        let onGrid = InstrumentEngine.nextBeatOnGrid(nowSec: 100.0, gridSec: grid, beatSec: beat, lead: 0)
        XCTAssertEqual(onGrid.atSec, 100.0, accuracy: 0.0001)
        XCTAssertEqual(onGrid.beatInBar, 0)

        let before = InstrumentEngine.nextBeatOnGrid(nowSec: 99.1, gridSec: grid, beatSec: beat, lead: 0)
        XCTAssertEqual(before.atSec, 99.5, accuracy: 0.0001)
        XCTAssertEqual(before.beatInBar, 3, "negative beat indices wrap positively")

        let wild = InstrumentEngine.nextBeatOnGrid(nowSec: 10, gridSec: 0, beatSec: 0, lead: 0.05)
        XCTAssertEqual(wild.atSec, 10.05, accuracy: 0.0001)
        XCTAssertEqual(wild.beatInBar, 0)
        XCTAssertEqual(InstrumentEngine.nextBeatOnGrid(nowSec: .nan, gridSec: 0, beatSec: 0.5).beatInBar, 0)
    }

    /// The mid-bar start tail is exactly the bar's remainder, so the loop behind it still lands
    /// on the bar line (the accent never drifts).
    func testClickTailBufferIsTheBarRemainder() throws {
        let fmt = InstrumentEngine.canonicalFormat
        let bar = try XCTUnwrap(InstrumentEngine.makeClickBarBuffer(bpm: 120, format: fmt))
        let beatFrames = Int(bar.frameLength) / 4
        XCTAssertNil(InstrumentEngine.clickTailBuffer(bar, fromBeat: 0), "beat 1 needs no tail")
        let tail = try XCTUnwrap(InstrumentEngine.clickTailBuffer(bar, fromBeat: 1))
        XCTAssertEqual(Int(tail.frameLength), Int(bar.frameLength) - beatFrames)
        // The tail STARTS on a tick (it is the bar copied from beat 2 on), so it isn't silence.
        let peak = (0..<min(1_000, Int(tail.frameLength))).reduce(Float(0)) {
            max($0, abs(tail.floatChannelData![0][$1]))
        }
        XCTAssertGreaterThan(peak, 0.01, "the tail begins at a beat tick")
        XCTAssertEqual(Int(try XCTUnwrap(InstrumentEngine.clickTailBuffer(bar, fromBeat: 3)).frameLength),
                       beatFrames)
    }
}

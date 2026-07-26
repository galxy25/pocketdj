import XCTest
import AVFoundation
@testable import PocketDJ

/// StudioEngine's pure, nonisolated math + the shared StudioAudio helpers (spec §4) — everything
/// here runs WITHOUT an audio engine, so it's hermetic on any CI host. The live-graph behavior
/// (route-change recovery, zombie re-prime) is engine-hardware-dependent and exercised through
/// the same *ForTesting seam pattern as MixEngine on-device; the math the schedule is built from
/// is pinned here.
final class StudioEngineMathTests: XCTestCase {

    // MARK: stepFrames — 60/bpm/4 seconds of frames (one bar of 16ths in 4/4)

    func testStepFramesExactAt100BPM() {
        // 44100 × 60/100/4 = 6615 exactly — no rounding involved.
        XCTAssertEqual(StudioEngine.stepFrames(bpm: 100, sampleRate: 44_100), 6615)
    }

    func testStepFramesRoundsAt120BPM() {
        // 44100 × 60/120/4 = 5512.5 → rounds half-away-from-zero to 5513. The exact value
        // matters: the bounce's bar length and the live schedule both multiply it by 16.
        XCTAssertEqual(StudioEngine.stepFrames(bpm: 120, sampleRate: 44_100), 5513)
    }

    func testStepFramesGuardsDegenerateInputs() {
        // 0/negative bpm falls back to the schema's 120 default (mirrors StudioPattern.barMs);
        // 0 sample rate falls back to canonical — a degraded document can't divide by zero.
        XCTAssertEqual(StudioEngine.stepFrames(bpm: 0, sampleRate: 44_100), 5513)
        XCTAssertEqual(StudioEngine.stepFrames(bpm: -3, sampleRate: 44_100), 5513)
        XCTAssertEqual(StudioEngine.stepFrames(bpm: 100, sampleRate: 0), 6615)
    }

    // MARK: stepTime — anchor + index × stepFrames on the player timeline

    func testStepTimeIndexZeroIsTheAnchor() {
        let anchor = AVAudioTime(sampleTime: 1000, atRate: 44_100)
        let t = StudioEngine.stepTime(anchor: anchor, index: 0, bpm: 100, sampleRate: 44_100)
        XCTAssertEqual(t.sampleTime, 1000)
        XCTAssertEqual(t.sampleRate, 44_100, accuracy: 0.001)
    }

    func testStepTimeAdvancesByWholeSteps() {
        let anchor = AVAudioTime(sampleTime: 1000, atRate: 44_100)
        let t4 = StudioEngine.stepTime(anchor: anchor, index: 4, bpm: 100, sampleRate: 44_100)
        XCTAssertEqual(t4.sampleTime, 1000 + 4 * 6615)
        // Pass 2, column 3 = index 35: integer-frame arithmetic keeps later passes bit-exact
        // (no accumulating float error across a long-running pattern).
        let t35 = StudioEngine.stepTime(anchor: anchor, index: 35, bpm: 100, sampleRate: 44_100)
        XCTAssertEqual(t35.sampleTime, 1000 + 35 * 6615)
    }

    // MARK: trimmedOrPadded — the loop-audition frames-exact seam (spec §2)

    private func makeBuffer(frames: AVAudioFrameCount, value: Float = 0.5) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: StudioAudio.canonicalFormat, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<2 {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(frames) { p[i] = value }
        }
        return buf
    }

    func testTrimmedOrPaddedTrimsToExactFrames() {
        let out = StudioAudio.trimmedOrPadded(makeBuffer(frames: 1000), to: 600)
        XCTAssertEqual(out?.frameLength, 600)
        XCTAssertEqual(out?.floatChannelData?[0][599], 0.5)   // content preserved to the last frame
    }

    func testTrimmedOrPaddedPadsWithTrueSilence() {
        let out = StudioAudio.trimmedOrPadded(makeBuffer(frames: 1000), to: 1500)
        XCTAssertEqual(out?.frameLength, 1500)
        XCTAssertEqual(out?.floatChannelData?[0][999], 0.5)
        // The pad must be EXPLICIT zeros — fresh buffer memory is not guaranteed zeroed, and a
        // garbage tail would click on every loop pass.
        XCTAssertEqual(out?.floatChannelData?[0][1000], 0)
        XCTAssertEqual(out?.floatChannelData?[1][1499], 0)
    }

    func testTrimmedOrPaddedExactLengthIsPassthrough() {
        let src = makeBuffer(frames: 1000)
        XCTAssertTrue(StudioAudio.trimmedOrPadded(src, to: 1000) === src)   // zero-copy fast path
    }

    func testTrimmedOrPaddedRejectsNonPositive() {
        XCTAssertNil(StudioAudio.trimmedOrPadded(makeBuffer(frames: 10), to: 0))
        XCTAssertNil(StudioAudio.trimmedOrPadded(makeBuffer(frames: 10), to: -5))
    }

    // MARK: isCanonical + gainMultiplier

    func testIsCanonicalMatchesOnlyTheCanonicalShape() {
        XCTAssertTrue(StudioAudio.isCanonical(StudioAudio.canonicalFormat))
        XCTAssertFalse(StudioAudio.isCanonical(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!))
        XCTAssertFalse(StudioAudio.isCanonical(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!))
    }

    func testGainMultiplierClampsToTheEditDomain() {
        XCTAssertEqual(StudioAudio.gainMultiplier(db: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(StudioAudio.gainMultiplier(db: -6), 0.5012, accuracy: 0.001)
        // Out-of-domain values clamp to the StudioSampleEdit gain range (−60…+12 dB) so a
        // hand-edited document can't drive a row mixer to an absurd multiplier.
        XCTAssertEqual(StudioAudio.gainMultiplier(db: 100), StudioAudio.gainMultiplier(db: 12))
        XCTAssertEqual(StudioAudio.gainMultiplier(db: -200), StudioAudio.gainMultiplier(db: -60))
    }

    // MARK: StudioPatternClock — the TimelineView-sampled step highlight

    @MainActor
    func testPatternClockStoppedOrPrerollIsNil() {
        let clock = StudioPatternClock()
        XCTAssertNil(clock.currentStep)                       // not running
        clock.running = true
        clock.bpm = 120
        clock.startedAtHost = CACurrentMediaTime() + 10       // still inside the start latency
        XCTAssertNil(clock.currentStep)
    }

    @MainActor
    func testPatternClockStepsAndWraps() {
        let clock = StudioPatternClock()
        clock.running = true
        clock.bpm = 120                                        // step = 0.125 s, bar = 2 s
        // Mid-step offsets so the assertion has ~60 ms of slack against test-runner scheduling.
        clock.startedAtHost = CACurrentMediaTime() - 0.31      // 0.31 / 0.125 = step 2
        XCTAssertEqual(clock.currentStep, 2)
        clock.startedAtHost = CACurrentMediaTime() - (2.0 + 0.31)   // one full bar later → wraps
        XCTAssertEqual(clock.currentStep, 2)
        clock.startedAtHost = CACurrentMediaTime() - 1.94      // 15.5 steps in → step 15
        XCTAssertEqual(clock.currentStep, 15)
    }

    // MARK: SEQ5 — loopWindow (the ∞ looper's repeating span)

    func testLoopWindowBasic() {
        // 2 bars = 32 steps, anchored at the top of a 64-step (4-bar) pattern.
        let w = StudioEngine.loopWindow(startStep: 0, loopBars: 2, stepCount: 64)
        XCTAssertEqual(w.start, 0)
        XCTAssertEqual(w.len, 32)
    }

    func testLoopWindowSlidesBackToFitAtTheTail() {
        // Anchored near the end, the full 2-bar window would overrun — it slides back so it stays
        // a full 32 steps (rather than shrinking) and still ends at the pattern's last step.
        let w = StudioEngine.loopWindow(startStep: 60, loopBars: 2, stepCount: 64)
        XCTAssertEqual(w.start, 32)
        XCTAssertEqual(w.len, 32)
    }

    func testLoopWindowCollapsesToWholePatternWhenShorterThanWindow() {
        // A 1-bar (16-step) pattern can't hold a 2-bar loop — the window collapses to the whole thing.
        let w = StudioEngine.loopWindow(startStep: 8, loopBars: 2, stepCount: 16)
        XCTAssertEqual(w.start, 0)
        XCTAssertEqual(w.len, 16)
    }

    func testLoopWindowGuardsDegenerateBarsAndCount() {
        // loopBars < 1 is treated as 1 bar; a zero step count as a 1-step pattern.
        XCTAssertEqual(StudioEngine.loopWindow(startStep: 0, loopBars: 0, stepCount: 64).len, 16)
        let z = StudioEngine.loopWindow(startStep: 5, loopBars: 4, stepCount: 0)
        XCTAssertEqual(z.start, 0)
        XCTAssertEqual(z.len, 1)
    }

    // MARK: SEQ5 — mappedStep (slot → pattern step; the playhead offset + loop mapping)

    func testMappedStepLoopOffWrapsWholePatternFromStart() {
        // Loop off, cursor at 0: slot k → k mod stepCount (the classic whole-pattern cycle).
        XCTAssertEqual(StudioEngine.mappedStep(slot: 0, startStep: 0, loopEnabled: false, loopBars: 2, stepCount: 16), 0)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 16, startStep: 0, loopEnabled: false, loopBars: 2, stepCount: 16), 0)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 20, startStep: 0, loopEnabled: false, loopBars: 2, stepCount: 16), 4)
    }

    func testMappedStepLoopOffHonorsCursorOffset() {
        // Cursor at step 5 in a 16-step pattern: playback begins at 5 and wraps back to 0 at the top.
        XCTAssertEqual(StudioEngine.mappedStep(slot: 0, startStep: 5, loopEnabled: false, loopBars: 2, stepCount: 16), 5)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 11, startStep: 5, loopEnabled: false, loopBars: 2, stepCount: 16), 0)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 12, startStep: 5, loopEnabled: false, loopBars: 2, stepCount: 16), 1)
    }

    func testMappedStepLoopOnCyclesWindow() {
        // Loop on, 2-bar window at the top of a 64-step pattern: slot cycles 0…31 then repeats.
        XCTAssertEqual(StudioEngine.mappedStep(slot: 31, startStep: 0, loopEnabled: true, loopBars: 2, stepCount: 64), 31)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 32, startStep: 0, loopEnabled: true, loopBars: 2, stepCount: 64), 0)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 33, startStep: 0, loopEnabled: true, loopBars: 2, stepCount: 64), 1)
    }

    func testMappedStepLoopOnWindowSlidesAtTail() {
        // Cursor near the end slides the window back to [32,64); it never leaves the pattern.
        XCTAssertEqual(StudioEngine.mappedStep(slot: 0, startStep: 60, loopEnabled: true, loopBars: 2, stepCount: 64), 32)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 31, startStep: 60, loopEnabled: true, loopBars: 2, stepCount: 64), 63)
        XCTAssertEqual(StudioEngine.mappedStep(slot: 32, startStep: 60, loopEnabled: true, loopBars: 2, stepCount: 64), 32)
    }

    // MARK: SEQ5 — the clock reflects the cursor offset + loop window

    @MainActor
    func testPatternClockHonorsCursorOffset() {
        let clock = StudioPatternClock()
        clock.running = true
        clock.bpm = 120                                        // step = 0.125 s
        clock.stepCount = 16
        clock.startStep = 5
        clock.startedAtHost = CACurrentMediaTime() - 0.31      // slot 2 → step 5 + 2 = 7
        XCTAssertEqual(clock.currentStep, 7)
    }

    @MainActor
    func testPatternClockHonorsLoopWindow() {
        let clock = StudioPatternClock()
        clock.running = true
        clock.bpm = 120                                        // step = 0.125 s
        clock.stepCount = 64
        clock.loopEnabled = true
        clock.loopBars = 1                                     // 16-step window at the top
        clock.startedAtHost = CACurrentMediaTime() - 2.53      // slot 20 → 20 mod 16 = 4
        XCTAssertEqual(clock.currentStep, 4)
    }
}

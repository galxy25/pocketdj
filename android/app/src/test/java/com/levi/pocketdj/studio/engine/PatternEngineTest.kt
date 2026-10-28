package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.AudioSink
import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.core.RenderClock
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PatternEngineTest {
    private val stepF = PatternMath.stepFrames(120.0).toInt()     // 5513

    /** Ramp buffer: sample i (both channels) = base + i * 1e-4 so a position in the buffer is identifiable. */
    private fun ramp(frames: Int, base: Float = 1f) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { base + (it / 2) * 1e-4f })
    private fun const(frames: Int, v: Float) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { v })

    private fun row(target: String, vararg cols: Int, loops: Set<Int> = emptySet(), spans: Map<Int, Int> = emptyMap(), n: Int = 16, gainDb: Double = 0.0) =
        StudioPatternRow.of(
            target, steps = List(n) { it in cols }, loopSteps = List(n) { it in loops },
            stepSpans = List(n) { spans[it] ?: 0 }, gainDb = gainDb,
        )

    private fun pattern(vararg rows: StudioPatternRow, n: Int = 16) = StudioPattern.of("ptn_t", "t", bpm = 120.0, stepCount = n, rows = rows.toList())

    private fun PatternScheduler.render(frames: Int): FloatArray {
        val out = FloatArray(frames * 2)
        var done = 0
        val blk = FloatArray(512 * 2)
        while (done < frames) {
            val n = minOf(512, frames - done)
            java.util.Arrays.fill(blk, 0f)
            assertEquals(n, pull(blk, n))
            System.arraycopy(blk, 0, out, done * 2, n * 2)
            done += n
        }
        return out
    }

    // ---- scheduling / choke ----

    @Test fun hitLandsOnTheExactStepFrame() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 2)), mapOf(0 to const(100, 0.5f)))
        assertTrue(s.restartFromTop())
        val out = s.render(3 * stepF)
        assertEquals(0.5f, out[0], 0f)
        assertEquals(0f, out[(stepF - 1) * 2], 0f)             // silent between hits
        assertEquals(0f, out[(2 * stepF - 1) * 2], 0f)
        assertEquals(0.5f, out[2 * stepF * 2], 0f)             // col 2 = slot 2 = frame 2*stepF
        assertEquals(0.5f, out[(2 * stepF + 99) * 2], 0f)
        assertEquals(0f, out[(2 * stepF + 100) * 2], 0f)
    }

    @Test fun retriggerOnTheSameRowChokesTheRingingHit() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 1)), mapOf(0 to ramp(20_000)))     // far longer than a step: still ringing at the retrigger
        s.restartFromTop()
        s.render(stepF + 100)
        // second trigger reset the row's frame cursor: it has played exactly 100 frames of the NEW hit
        assertEquals(100, s.rowFrameCursor(0))
        val s2 = PatternScheduler()
        s2.load(pattern(row("a", 0, 1)), mapOf(0 to ramp(20_000)))
        s2.restartFromTop()
        val out = s2.render(stepF + 10)
        // the sample at the retrigger frame is buffer[0] ALONE (1.0), not buffer[0] + the ringing old hit (~1.55)
        assertEquals(1f, out[stepF * 2], 1e-6f)
        assertEquals(1f + 9e-4f, out[(stepF + 9) * 2], 1e-5f)
    }

    @Test fun differentRowsDoNotChokeEachOtherAndSum() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0), row("b", 0)), mapOf(0 to const(50, 0.25f), 1 to const(50, 0.5f)))
        s.restartFromTop()
        assertEquals(0.75f, s.render(10)[0], 1e-6f)
    }

    @Test fun missingTargetRowIsSkippedNotAThrow() {
        val s = PatternScheduler()
        val sounding = s.load(pattern(row("a", 0), row("gone", 0)), mapOf(0 to const(50, 0.25f)))     // row 1 has no buffer
        assertEquals(listOf(0), sounding)
        s.restartFromTop()
        assertEquals(0.25f, s.render(10)[0], 1e-6f)
        assertNull(s.rowFrameCursor(1))
    }

    @Test fun zeroFrameAndNonCanonicalBuffersAreSkipped() {
        val s = PatternScheduler()
        val sounding = s.load(
            pattern(row("a", 0), row("b", 0), row("c", 0)),
            mapOf(0 to PcmBuffer(44_100, 2, FloatArray(0)), 1 to PcmBuffer(48_000, 2, FloatArray(200)), 2 to const(10, 1f)),
        )
        assertEquals(listOf(2), sounding)
    }

    @Test fun rowsBeyondTheCapAreDropped() {
        val rows = (0 until 10).map { row("t$it", it) }
        val s = PatternScheduler()
        val sounding = s.load(pattern(*rows.toTypedArray()), (0 until 10).associateWith { const(10, 0.1f) })
        assertEquals((0 until PatternMath.MAX_PATTERN_ROWS).toList(), sounding)
    }

    // ---- horizon ----

    @Test fun horizonArmsFourBarsAheadAndRearmsAsTheCursorAdvances() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 4, 8, 12), n = 64), mapOf(0 to const(10, 1f)))
        s.restartFromTop()
        assertEquals(PatternMath.HORIZON_SLOTS + 1, s.armedSlotCount)            // slots 0..64 armed, NOT the whole song
        s.render(10 * stepF)                                                     // cursor at slot 9 (+block)
        val armed = s.armedSlotCount
        assertTrue("re-armed as the cursor moved: $armed", armed >= 10 + PatternMath.HORIZON_SLOTS)
        assertTrue(armed <= 11 + PatternMath.HORIZON_SLOTS + 1)
    }

    @Test fun stepTimesAreMonotonicAndIntegerExactAcrossRearm() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 1, 2, 3)), mapOf(0 to const(10, 1f)))
        s.restartFromTop()
        s.render(40 * stepF)
        val frames = s.pendingHitFrames(0)
        assertTrue(frames.isNotEmpty())
        frames.zipWithNext().forEach { (a, b) -> assertTrue("$a < $b", b > a) }
        // each pending hit is exactly slot * stepFrames
        frames.forEach { assertEquals(0L, it % stepF) }
    }

    // ---- start step + loop window ----

    @Test fun startStepOffsetsTheFirstHit() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 5)), mapOf(0 to const(10, 1f)), startStep = 5)
        s.restartFromTop()
        assertEquals(1f, s.render(4)[0], 0f)             // slot 0 maps to step 5 -> sounds at frame 0
        assertEquals(listOf(16L * stepF), s.pendingHitFrames(0).take(1))    // next pass of step 5 is 16 slots later
    }

    @Test fun infinityLoopCyclesTheWindowOnly() {
        val s = PatternScheduler()
        // 4-bar pattern, hit only at step 20, 1-bar loop anchored at 16 -> window [16,32): slot 4, 20, 36...
        s.load(pattern(row("a", 20, n = 64), n = 64), mapOf(0 to const(10, 1f)), startStep = 16, loopEnabled = true, loopBars = 1)
        s.restartFromTop()
        val hits = s.pendingHitFrames(0)
        assertEquals(listOf(4L, 20L, 36L, 52L).map { it * stepF }, hits.take(4))
        // a hit outside the window never sounds
        val s2 = PatternScheduler()
        s2.load(pattern(row("a", 3, n = 64), n = 64), mapOf(0 to const(10, 1f)), startStep = 16, loopEnabled = true, loopBars = 1)
        s2.restartFromTop()
        assertTrue(s2.pendingHitFrames(0).isEmpty())
    }

    @Test fun setStartStepWhileRunningReanchorsFromTheTop() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 8)), mapOf(0 to const(10, 1f)))
        s.restartFromTop(); s.render(3 * stepF)
        s.setStartStep(8)
        assertEquals(0L, s.renderedFrames)
        assertEquals(1f, s.render(4)[0], 0f)             // now step 8 sounds immediately
    }

    @Test fun setLoopWhileRunningReanchors() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 20, n = 64), n = 64), mapOf(0 to const(10, 1f)), startStep = 16)
        s.restartFromTop()
        s.setLoop(true, 1)
        assertEquals(4L * stepF, s.pendingHitFrames(0).first())
    }

    // ---- loop + span ----

    @Test fun loopStepRepeatsUntilTheRowsNextTrigger() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 1, loops = setOf(0))), mapOf(0 to ramp(1000)))
        s.restartFromTop()
        val out = s.render(stepF + 10)
        // wraps at 1000 frames with no gap: frame 2500 = buffer[500]
        assertEquals(1f + 500e-4f, out[2500 * 2], 1e-5f)
        // the NEXT trigger (a one-shot at col 1) takes over exactly at its frame
        assertEquals(1f, out[stepF * 2], 1e-6f)
    }

    @Test fun spanStepUsesTheStretchedBufferAndFallsBackToNatural() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 2, spans = mapOf(0 to 4, 2 to 8))), mapOf(0 to const(10, 0.1f)), spanBuffers = mapOf(0 to mapOf(4 to const(10, 0.9f))))
        s.restartFromTop()
        val out = s.render(3 * stepF)
        assertEquals(0.9f, out[0], 1e-6f)                      // span 4 -> stretched buffer
        assertEquals(0.1f, out[2 * stepF * 2], 1e-6f)          // span 8 not prepared -> natural
    }

    // ---- live ----

    @Test fun liveRowGainScalesWithoutTouchingTheSchedule() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0, 1)), mapOf(0 to const(50, 1f)))
        s.restartFromTop()
        assertEquals(1f, s.render(10)[0], 1e-6f)
        s.setRowGain(0, -6.0)
        val out = s.render(stepF + 10)                          // starts at frame 10
        assertEquals(0.5012f, out[0], 1e-3f)                    // the still-ringing first hit is scaled live
        assertEquals(0.5012f, out[(stepF - 10) * 2], 1e-3f)     // and so is the next trigger, same schedule
    }

    @Test fun liveStepEditsLandAtTheNextHorizonNotInAlreadyArmedSlots() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0)), mapOf(0 to const(10, 1f)))
        s.restartFromTop(); s.render(stepF / 2)
        val before = s.pendingHitFrames(0)
        s.updateLiveStep(0, 3, true)
        assertEquals(before, s.pendingHitFrames(0))                     // iOS parity: armed hits keep their schedule
        s.render(6 * 16 * stepF)                                        // horizon passes: slot 3 of a later pass is armed from the mirror
        assertTrue(s.pendingHitFrames(0).any { (it / stepF) % 16 == 3L })
    }

    @Test fun engineParksOnTransientLossAndResumesFromTheTopOnlyWhenParked() {
        val sink = FakeSink()
        var released = 0
        val e = PatternEngine({ sink }, focus = { true }, focusRelease = { released++ })
        e.loadPattern(pattern(row("a", 0)), mapOf(0 to const(100, 0.5f)))
        assertFalse(e.resumeFromInterruption())                         // not parked: no-op
        assertTrue(e.startPattern())
        e.parkForInterruption()
        assertFalse(e.isPlaying.value); assertTrue(e.parkedForInterruption); assertEquals(0, released)   // focus kept
        assertTrue(e.resumeFromInterruption())
        assertTrue(e.isPlaying.value); assertFalse(e.parkedForInterruption)
    }

    @Test fun explicitStopClearsThePark() {
        val sink = FakeSink()
        var released = 0
        val e = PatternEngine({ sink }, focus = { true }, focusRelease = { released++ })
        e.loadPattern(pattern(row("a", 0)), mapOf(0 to const(100, 0.5f)))
        e.startPattern(); e.parkForInterruption()
        e.stopPattern()
        assertEquals(1, released); assertFalse(e.parkedForInterruption)
        assertFalse(e.resumeFromInterruption()); assertFalse(e.isPlaying.value)
    }

    @Test fun horizonRearmEmitsADiag() {
        val sink = FakeSink()
        val lines = ArrayList<String>()
        val e = PatternEngine({ sink }, diag = { lines += it })
        e.loadPattern(pattern(row("a", 0)), mapOf(0 to const(10, 1f)))
        e.startPattern()
        sink.renderer!!.render(FloatArray(stepF * 2), stepF)
        assertTrue(lines.any { it.startsWith("armed slots ") })
    }

    @Test fun liveStepOffAlsoClearsTheLoopAndSpanMirror() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 3, loops = setOf(3), spans = mapOf(3 to 2))), mapOf(0 to const(10, 0.1f)), spanBuffers = mapOf(0 to mapOf(2 to const(10, 0.9f))))
        s.restartFromTop()
        s.updateLiveStep(0, 3, false); s.updateLiveStep(0, 3, true)
        s.stop(); s.restartFromTop()
        val out = s.render(4 * stepF)
        assertEquals(0.1f, out[3 * stepF * 2], 1e-6f)           // back on as a plain natural one-shot
        assertEquals(0f, out[(3 * stepF + 50) * 2], 0f)         // not looping
    }

    @Test fun liveLoopToggleMirrorsIntoTheRunningPattern() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0)), mapOf(0 to const(100, 1f)))
        s.restartFromTop(); s.render(10)
        s.updateLiveStepLoop(0, 0, true)
        s.stop(); s.restartFromTop()
        assertEquals(1f, s.render(300)[250 * 2], 0f)
    }

    @Test fun liveEditOutOfBoundsIsANoOp() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0)), mapOf(0 to const(10, 1f)))
        s.restartFromTop()
        s.updateLiveStep(7, 0, true); s.updateLiveStep(0, 99, true); s.updateLiveStepLoop(0, 99, true)
        assertEquals(listOf(0L, 16L * stepF), s.pendingHitFrames(0).take(2))        // untouched by the out-of-range edits
    }

    @Test fun stopSilencesAndRewindsAndRestartReplaysFromTheTop() {
        val s = PatternScheduler()
        s.load(pattern(row("a", 0)), mapOf(0 to const(100, 1f)))
        s.restartFromTop(); s.render(stepF)
        s.stop()
        assertFalse(s.running)
        assertEquals(0, s.pull(FloatArray(8), 4))
        s.restartFromTop()
        assertEquals(1f, s.render(4)[0], 0f)
    }

    @Test fun silentPatternRefusesToStart() {
        val s = PatternScheduler()
        s.load(pattern(row("a")), mapOf(0 to const(10, 1f)))
        assertFalse(s.hasContent)
        assertFalse(s.restartFromTop())
        assertFalse(s.running)
    }

    // ---- PatternEngine (lifecycle over a fake sink) ----

    private class FakeSink(private val opens: Boolean = true) : AudioSink {
        override val sampleRate = 44_100
        override val clock = RenderClock(44_100)
        override val underruns = 0L
        override var isRendering = false
        override var onRoutingChanged: ((Boolean) -> Unit)? = null
        var renderer: BlockRenderer? = null
        var starts = 0
        override fun start(renderer: BlockRenderer) { this.renderer = renderer; starts++; isRendering = opens }
        override fun stop() { isRendering = false }
        override fun release() {}
        override fun latencyFrames() = 0
    }

    @Test fun engineRefusesZeroSoundingStepsWithoutOpeningTheSink() {
        val sink = FakeSink()
        val e = PatternEngine({ sink })
        e.loadPattern(pattern(row("a")), mapOf(0 to const(10, 1f)))
        assertFalse(e.startPattern())
        assertEquals("no-content", e.lastRefusal)
        assertEquals(0, sink.starts)
        assertFalse(e.isPlaying.value)
    }

    @Test fun engineStartPlaysThroughTheGraphAndStopParksTheClock() {
        val sink = FakeSink()
        var released = 0
        val e = PatternEngine({ sink }, focus = { true }, focusRelease = { released++ })
        e.loadPattern(pattern(row("a", 0, 4)), mapOf(0 to const(100, 0.5f)))
        assertTrue(e.startPattern())
        assertTrue(e.isPlaying.value); assertTrue(e.clock.running)
        val out = FloatArray(6 * stepF * 2)
        sink.renderer!!.render(out, 6 * stepF)
        assertEquals(0.5f, out[0], 1e-6f)
        assertEquals(0.5f, out[4 * stepF * 2], 1e-6f)
        assertEquals(6, e.clock.currentStep)                    // 6*stepF frames rendered -> the edge of slot 6
        e.stopPattern()
        assertFalse(e.isPlaying.value); assertFalse(sink.isRendering); assertEquals(1, released)
        assertNull(e.clock.currentStep)
    }

    @Test fun engineRefusesWhileTheMicCaptures() {
        val sink = FakeSink()
        val e = PatternEngine({ sink })
        e.loadPattern(pattern(row("a", 0)), mapOf(0 to const(10, 1f)))
        AudioFocusPolicy.beginMicCapture()
        try {
            assertFalse(e.startPattern()); assertEquals("mic-capture-active", e.lastRefusal)
        } finally { AudioFocusPolicy.endMicCapture() }
        assertTrue(e.startPattern())
    }

    @Test fun engineRefusesWithoutFocusAndWhenTheSinkFailsToOpen() {
        val e1 = PatternEngine({ FakeSink() }, focus = { false })
        e1.loadPattern(pattern(row("a", 0)), mapOf(0 to const(10, 1f)))
        assertFalse(e1.startPattern()); assertEquals("no-focus", e1.lastRefusal)
        var released = 0
        val e2 = PatternEngine({ FakeSink(opens = false) }, focusRelease = { released++ })
        e2.loadPattern(pattern(row("a", 0)), mapOf(0 to const(10, 1f)))
        assertFalse(e2.startPattern()); assertEquals("output-unavailable", e2.lastRefusal)
        assertEquals(1, released); assertFalse(e2.clock.running)
    }

    @Test fun engineSoloLoadsOnlyThatRowAndLoadWhilePlayingStopsFirst() {
        val sink = FakeSink()
        val e = PatternEngine({ sink })
        val p = pattern(row("a", 0), row("b", 0))
        e.loadPattern(p, mapOf(1 to const(10, 0.5f)), soloedRow = 1)
        assertEquals(1, e.soloedRow.value)
        assertTrue(e.startPattern())
        val out = FloatArray(8); sink.renderer!!.render(out, 4)
        assertEquals(0.5f, out[0], 1e-6f)
        e.loadPattern(p, mapOf(0 to const(10, 0.25f)))
        assertFalse(e.isPlaying.value); assertNull(e.soloedRow.value)
    }

    @Test fun engineLoopAndStartStepMirrorIntoTheClock() {
        val e = PatternEngine({ FakeSink() })
        e.loadPattern(pattern(row("a", 0), n = 64), mapOf(0 to const(10, 1f)))
        e.setPatternLoop(true, 2); e.setPatternStartStep(9)
        assertTrue(e.clock.loopEnabled); assertEquals(2, e.clock.loopBars); assertEquals(9, e.clock.startStep)
        e.setPatternStartStep(500)
        assertEquals(63, e.clock.startStep)
    }

    @Test fun engineLogsStartParkAndStopReasons() = captureAudioDiag { lines ->
        val e = PatternEngine({ FakeSink() }, focus = { true }, focusRelease = {})
        e.loadPattern(pattern(row("a", 0)), mapOf(0 to const(100, 0.5f)))
        assertTrue(e.startPattern())
        assertTrue(lines.contains("audio.play owner=studio.pattern reason=user-play"))
        e.parkForInterruption()
        assertTrue(lines.contains("audio.stop owner=studio.pattern reason=focus-transient"))
        assertTrue(e.resumeFromInterruption())
        e.stopPattern("focus-loss")
        assertTrue(lines.contains("audio.stop owner=studio.pattern reason=focus-loss"))
    }
}

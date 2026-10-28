package com.levi.pocketdj.studio.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PatternClockTest {
    private var frames = 0L
    private val clock = PatternClock(renderedFrames = { frames }, latencyFrames = { latency })
    private var latency = 0L
    private val step120 = PatternMath.stepFrames(120.0)   // 5513

    private fun start(bpm: Double = 120.0, stepCount: Int = 16) { clock.bpm = bpm; clock.stepCount = stepCount; clock.running = true }

    @Test fun stoppedIsNull() { frames = 99999; assertNull(clock.currentStep) }

    @Test fun insideOutputLatencyPreRollIsNull() {
        start(); latency = 4096; frames = 1000
        assertNull(clock.currentStep)
        frames = 4096 + 10
        assertEquals(0, clock.currentStep)
    }

    @Test fun stepsAndWraps() {
        start()
        frames = step120 * 2 + 100; assertEquals(2, clock.currentStep)
        frames = step120 * 16 + step120 * 2 + 100; assertEquals(2, clock.currentStep)   // one full bar later
        frames = step120 * 15 + step120 / 2; assertEquals(15, clock.currentStep)
    }

    @Test fun stepBoundaryIsExactlyTheSchedulerFrame() {
        start()
        frames = step120 - 1; assertEquals(0, clock.currentStep)
        frames = step120; assertEquals(1, clock.currentStep)
    }

    @Test fun honorsCursorOffset() {
        start(); clock.startStep = 5
        frames = step120 * 2 + 10; assertEquals(7, clock.currentStep)
    }

    @Test fun honorsLoopWindow() {
        start(stepCount = 64); clock.loopEnabled = true; clock.loopBars = 1
        frames = step120 * 20 + 5; assertEquals(4, clock.currentStep)
    }

    @Test fun loopWindowAnchoredAtTailSlidesBack() {
        start(stepCount = 64); clock.loopEnabled = true; clock.loopBars = 2; clock.startStep = 60
        frames = 5; assertEquals(32, clock.currentStep)
    }

    @Test fun parkOnStopIsStickyExceptWhileLooping() {
        start(); clock.startStep = 0; frames = step120 * 6 + 3
        assertEquals(6, clock.cursorToParkOnStop())
        clock.loopEnabled = true
        assertNull(clock.cursorToParkOnStop())     // startStep is the loop-window anchor: never move it
    }

    @Test fun parkOnStopIsNullOnceStopped() {
        start(); frames = step120 * 3; clock.running = false
        assertNull(clock.cursorToParkOnStop())
    }
}

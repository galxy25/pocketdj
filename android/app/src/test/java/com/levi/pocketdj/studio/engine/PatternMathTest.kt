package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS StudioEngineMathTests step/loop cases plus the pure grid/list helpers the UI shares. */
class PatternMathTest {
    // ---- stepFrames ----
    @Test fun stepFramesExactAt100Bpm() = assertEquals(6615L, PatternMath.stepFrames(100.0, 44_100.0))

    @Test fun stepFramesRoundsHalfUpAt120Bpm() {
        // 44100 * 60 / 120 / 4 = 5512.5 -> half away from zero = 5513 (iOS pins the same value).
        assertEquals(5513L, PatternMath.stepFrames(120.0, 44_100.0))
    }

    @Test fun stepFramesGuardsDegenerateInputs() {
        assertEquals(5513L, PatternMath.stepFrames(0.0, 44_100.0))
        assertEquals(5513L, PatternMath.stepFrames(-3.0, 44_100.0))
        assertEquals(6615L, PatternMath.stepFrames(100.0, 0.0))
    }

    // ---- stepTime ----
    @Test fun stepTimeIndexZeroIsTheAnchor() = assertEquals(1000L, PatternMath.stepTime(1000, 0, 100.0))

    @Test fun stepTimeAdvancesByWholeStepsAndStaysMonotonicAcrossPasses() {
        assertEquals(1000L + 4 * 6615, PatternMath.stepTime(1000, 4, 100.0))
        assertEquals(1000L + 35 * 6615, PatternMath.stepTime(1000, 35, 100.0))
        var prev = -1L
        for (slot in 0..500) { val t = PatternMath.stepTime(0, slot, 123.0); assertTrue(t > prev); prev = t }
    }

    @Test fun stepTimeIsBitExactInTheLongRun() {
        // Integer arithmetic: slot N is the same frame however it is reached (no accumulating error).
        val f = PatternMath.stepFrames(133.0)
        assertEquals(f * 100_000L, PatternMath.stepTime(0, 100_000, 133.0))
    }

    // ---- loopWindow ----
    @Test fun loopWindowBasic() = assertEquals(PatternMath.LoopWindow(0, 32), PatternMath.loopWindow(0, 2, 64))

    @Test fun loopWindowSlidesBackToFitAtTheTail() =
        assertEquals(PatternMath.LoopWindow(32, 32), PatternMath.loopWindow(60, 2, 64))

    @Test fun loopWindowCollapsesToWholePatternWhenShorterThanWindow() =
        assertEquals(PatternMath.LoopWindow(0, 16), PatternMath.loopWindow(8, 2, 16))

    @Test fun loopWindowGuardsDegenerateBarsAndCount() {
        assertEquals(16, PatternMath.loopWindow(0, 0, 64).len)
        assertEquals(PatternMath.LoopWindow(0, 1), PatternMath.loopWindow(5, 4, 0))
    }

    // ---- mappedStep ----
    @Test fun mappedStepLoopOffWrapsWholePatternFromStart() {
        assertEquals(0, PatternMath.mappedStep(0, 0, false, 2, 16))
        assertEquals(0, PatternMath.mappedStep(16, 0, false, 2, 16))
        assertEquals(4, PatternMath.mappedStep(20, 0, false, 2, 16))
    }

    @Test fun mappedStepLoopOffHonorsCursorOffset() {
        assertEquals(5, PatternMath.mappedStep(0, 5, false, 2, 16))
        assertEquals(0, PatternMath.mappedStep(11, 5, false, 2, 16))
        assertEquals(1, PatternMath.mappedStep(12, 5, false, 2, 16))
    }

    @Test fun mappedStepLoopOnCyclesTheWindow() {
        assertEquals(31, PatternMath.mappedStep(31, 0, true, 2, 64))
        assertEquals(0, PatternMath.mappedStep(32, 0, true, 2, 64))
        assertEquals(1, PatternMath.mappedStep(33, 0, true, 2, 64))
    }

    @Test fun mappedStepLoopOnWindowSlidesAtTail() {
        assertEquals(32, PatternMath.mappedStep(0, 60, true, 2, 64))
        assertEquals(63, PatternMath.mappedStep(31, 60, true, 2, 64))
        assertEquals(32, PatternMath.mappedStep(32, 60, true, 2, 64))
    }

    @Test fun mappedStepNeverLeavesThePatternForAnyInput() {
        for (sc in listOf(1, 7, 16, 33, 64)) for (start in listOf(-4, 0, 5, 70)) for (loop in listOf(false, true)) for (slot in -3..200) {
            val s = PatternMath.mappedStep(slot, start, loop, 3, sc)
            assertTrue("sc=$sc start=$start loop=$loop slot=$slot -> $s", s in 0 until sc)
        }
    }

    // ---- row/step helpers ----
    @Test fun spanCoverageWashesTheFootprintOfAStretchedStep() {
        val steps = List(16) { it == 2 || it == 10 }
        val spans = List(16) { if (it == 2) 4 else 0 }
        val cov = PatternMath.spanCoverage(steps, spans)
        assertArrayEquals(booleanArrayOf(false, false, false, true, true, true, false, false, false, false, false, false, false, false, false, false), cov)
        // span 1 covers nothing; a span running past the end is clipped
        assertFalse(PatternMath.spanCoverage(listOf(true, false), listOf(1, 0)).any { it })
        assertEquals(listOf(false, true, true), PatternMath.spanCoverage(listOf(true, false, false), listOf(9, 0, 0)).toList())
    }

    @Test fun spanAndLoopOnlyCountOnSteps() {
        val row = StudioPatternRow.of("smp_a", steps = List(16) { it == 1 }, loopSteps = List(16) { true }, stepSpans = List(16) { 3 })
        assertEquals(3, PatternMath.spanAt(row, 1)); assertEquals(0, PatternMath.spanAt(row, 2))
        assertTrue(PatternMath.loopsAt(row, 1)); assertFalse(PatternMath.loopsAt(row, 2))
        assertEquals(0, PatternMath.spanAt(row, 99))
    }

    @Test fun stretchKeysDedupeAcrossRowsAndSkipSilentRows() {
        val p = StudioPattern.of("ptn_x", "x", rows = listOf(
            StudioPatternRow.of("smp_a", steps = List(16) { it == 0 || it == 4 }, stepSpans = List(16) { if (it == 0) 4 else if (it == 4) 2 else 0 }),
            StudioPatternRow.of("smp_a", steps = List(16) { it == 8 }, stepSpans = List(16) { if (it == 8) 4 else 0 }),
            StudioPatternRow.of("smp_b", steps = List(16) { false }, stepSpans = List(16) { 4 }),
        ))
        assertEquals(setOf(StudioStretchKey("smp_a", 4), StudioStretchKey("smp_a", 2)), PatternMath.stretchKeys(p))
        assertEquals(setOf(StudioStretchKey("smp_a", 4)), PatternMath.stretchKeys(p, onlyRows = setOf(1)))
    }

    // ---- grid layout ----
    @Test fun compactWrapsEightPerLineAndZoomMultiplies() {
        assertEquals(8, PatternMath.stepsPerLine(true, 1)); assertEquals(16, PatternMath.stepsPerLine(false, 1))
        assertEquals(32, PatternMath.stepsPerLine(true, 4)); assertEquals(8, PatternMath.stepsPerLine(true, 0))
        assertEquals(2, PatternMath.lineCount(16, 8)); assertEquals(1, PatternMath.lineCount(0, 8)); assertEquals(3, PatternMath.lineCount(17, 8))
    }

    @Test fun beatGroupsSplitInFoursWithAShortTail() {
        assertEquals(listOf(0..3, 4..7), PatternMath.beatGroups(0, 8))
        assertEquals(listOf(8..11, 12..13), PatternMath.beatGroups(8, 14))
    }

    @Test fun lengthStepperMathCapsAtTheSchemaMax() {
        assertEquals(1, PatternMath.barsOf(1)); assertEquals(1, PatternMath.barsOf(16)); assertEquals(2, PatternMath.barsOf(17))
        assertEquals(StudioPattern.MAX_STEP_COUNT, PatternMath.stepCountForBars(PatternMath.MAX_BARS + 5))
        assertEquals("2 bars · 32 steps", PatternMath.lengthLabel(32)); assertEquals("1 bar · 16 steps", PatternMath.lengthLabel(16))
    }

    @Test fun duplicateDoesNotInheritTheBounce() {
        val p = StudioPattern.of("ptn_1", "Beat", fileName = "pattern-ptn_1.m4a", bounceDirty = false, wasUserFolder = true)
        val c = PatternMath.duplicate(p, "ptn_2", 5.0)
        assertEquals("ptn_2", c.id); assertEquals("Beat copy", c.name); assertNull(c.fileName); assertTrue(c.bounceDirty); assertFalse(c.wasUserFolder)
        assertEquals("Pattern copy", PatternMath.duplicate(p.copy(name = ""), "ptn_3", 0.0).name)
    }

    @Test fun listSubtitleAndGainLabel() {
        val p = StudioPattern.of("ptn_1", "B", bpm = 127.6, rows = listOf(StudioPatternRow.of("smp_a")), fileName = "f", bounceDirty = false)
        assertEquals("128 BPM · 1 row · bounced", PatternMath.listSubtitle(p))
        assertEquals("120 BPM · 0 rows", PatternMath.listSubtitle(StudioPattern.of("ptn_2", "B")))
        assertEquals("0 dB", PatternMath.gainLabel(0.0)); assertEquals("+1.5 dB", PatternMath.gainLabel(1.5)); assertEquals("-6.0 dB", PatternMath.gainLabel(-6.0))
    }
}

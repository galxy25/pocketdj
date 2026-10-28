package com.levi.pocketdj.mix.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BeatMathTest {
    private val drifting = listOf(0, 500, 1010, 1500, 2020, 2500)
    private fun grid(bpm: Double, first: Int, beats: List<Int>) = BeatGrid(bpm, first, beats)

    // lastBeat / isDownbeat

    @Test fun lastBeatBeforeFirstBeatIsNull() {
        assertNull(BeatMath.lastBeat(listOf(100, 600, 1100), null, 99.0))
    }

    @Test fun lastBeatEmptyGridIsNull() {
        assertNull(BeatMath.lastBeat(emptyList(), listOf(0), 500.0))
    }

    @Test fun lastBeatPicksLargestAtOrBefore() {
        val b = listOf(100, 600, 1100)
        assertEquals(600, BeatMath.lastBeat(b, null, 600.0)!!.beatMs)
        assertEquals(600, BeatMath.lastBeat(b, null, 1099.0)!!.beatMs)
        assertEquals(1100, BeatMath.lastBeat(b, null, 99_999.0)!!.beatMs)
    }

    @Test fun lastBeatFlagsDownbeat() {
        val b = listOf(100, 600, 1100)
        assertTrue(BeatMath.lastBeat(b, listOf(100), 150.0)!!.isDownbeat)
        assertFalse(BeatMath.lastBeat(b, listOf(100), 700.0)!!.isDownbeat)
    }

    @Test fun downbeatTolerance30msInclusive() {
        val downs = listOf(1000, 2000, 3000)
        assertTrue(BeatMath.isDownbeat(2000, downs))
        assertTrue(BeatMath.isDownbeat(2030, downs))
        assertTrue(BeatMath.isDownbeat(1970, downs))
        assertFalse(BeatMath.isDownbeat(2031, downs))
        assertFalse(BeatMath.isDownbeat(1969, downs))
        assertFalse(BeatMath.isDownbeat(0, null))
        assertFalse(BeatMath.isDownbeat(0, emptyList()))
    }

    // sliceBoundaries

    @Test fun sliceRealGridUsesSummedDriftIntervals() {
        val r = BeatMath.sliceBoundaries(0, 4.0, grid(120.0, 0, drifting))!!
        assertEquals(SliceBounds(0, 2020, 2020), r)
    }

    @Test fun sliceAnchorSnapsForwardToNextBeat() {
        val r = BeatMath.sliceBoundaries(501, 1.0, grid(120.0, 0, drifting))!!
        assertEquals(SliceBounds(1010, 1500, 490), r)
    }

    @Test fun sliceAnchorOnBeatStays() {
        val r = BeatMath.sliceBoundaries(500, 2.0, grid(120.0, 0, drifting))!!
        assertEquals(500, r.startMs)
        assertEquals(1500, r.endMs)
    }

    @Test fun sliceHalfBeatEndsAtMidpoint() {
        val r = BeatMath.sliceBoundaries(500, 0.5, grid(120.0, 0, drifting))!!
        assertEquals(SliceBounds(500, 755, 255), r)
    }

    @Test fun sliceExtendsPastGridEndAtConstantBpm() {
        val r = BeatMath.sliceBoundaries(0, 4.0, grid(120.0, 0, listOf(0, 500)))!!
        assertEquals(SliceBounds(0, 2000, 2000), r)
    }

    @Test fun sliceAnchorBeyondLastBeatStartsOnExtendedLattice() {
        val r = BeatMath.sliceBoundaries(1600, 1.0, grid(120.0, 0, listOf(0, 500)))!!
        assertEquals(2000, r.startMs)
        assertEquals(2500, r.endMs)
    }

    @Test fun sliceNoBpmUsesGridMeanInterval() {
        val r = BeatMath.sliceBoundaries(0, 4.0, grid(0.0, 0, listOf(0, 500, 1000)))!!
        assertEquals(2000, r.endMs)
    }

    @Test fun sliceSingleBeatNoBpmCannotWalk() {
        assertNull(BeatMath.sliceBoundaries(0, 1.0, grid(0.0, 0, listOf(0))))
    }

    @Test fun sliceSynthesisedLatticeLengthIsBeatsTimesBeatPeriod() {
        val r = BeatMath.sliceBoundaries(0, 4.0, grid(120.0, 250, emptyList()))!!
        assertEquals(SliceBounds(250, 2250, 2000), r)
    }

    @Test fun sliceSynthesisSnapsAnchorForward() {
        val r = BeatMath.sliceBoundaries(300, 1.0, grid(120.0, 250, emptyList()))!!
        assertEquals(750, r.startMs)
        assertEquals(500, r.lengthMs)
    }

    @Test fun sliceSynthesisHalfBeat() {
        val r = BeatMath.sliceBoundaries(250, 0.5, grid(120.0, 250, emptyList()))!!
        assertEquals(250, r.startMs)
        assertEquals(250, r.lengthMs)
    }

    @Test fun sliceNoGridOrBadBeatsIsNull() {
        assertNull(BeatMath.sliceBoundaries(0, 4.0, grid(0.0, 0, emptyList())))
        assertNull(BeatMath.sliceBoundaries(0, 0.0, grid(120.0, 0, drifting)))
        assertNull(BeatMath.sliceBoundaries(0, -1.0, grid(120.0, 0, drifting)))
    }

    // sliceStarts

    @Test fun sliceStartsEvenChopWithoutGrid() {
        assertEquals(listOf(0, 1000, 2000, 3000), BeatMath.sliceStarts(4, null, 4000))
    }

    @Test fun sliceStartsCapsAtEightAndClampsCount() {
        assertEquals(8, BeatMath.sliceStarts(99, null, 8000).size)
        assertEquals(listOf(0), BeatMath.sliceStarts(0, null, 8000))
        assertEquals(listOf(0), BeatMath.sliceStarts(4, null, 0))
    }

    @Test fun sliceStartsSnapToBeatsAndFirstIsZero() {
        val g = grid(120.0, 0, emptyList())
        assertEquals(listOf(0, 1000, 2000), BeatMath.sliceStarts(3, g, 3000))
        val off = BeatMath.sliceStarts(3, g, 2900)   // targets 0, 966, 1933 -> beats 1000, 2000
        assertEquals(listOf(0, 1000, 2000), off)
        assertEquals(0, BeatMath.sliceStarts(2, null, 5000).first())
    }

    @Test fun sliceStartsDedupesCoincidentSnaps() {
        // 4 pads over 1 s at 60 BPM (beat every 1000): targets 0,250,500,750 -> beats 0 and 1000?
        // lattice in [0,1000) is only [0], so everything snaps to 0 -> one pad.
        assertEquals(listOf(0), BeatMath.sliceStarts(4, grid(60.0, 0, emptyList()), 1000))
    }

    // cyclePhase

    private val beats500 = (0 until 32).map { it * 500 }
    private fun ph(at: Double, beats: List<Int>? = beats500, downs: List<Int>? = null, bpm: Double = 120.0,
                   first: Int = 0, cycle: Double = 4.0, offset: Double = 0.0) =
        BeatMath.cyclePhase(at, beats, downs, bpm, first, cycle, offset)

    @Test fun cyclePhaseRampsAcrossABarAndWraps() {
        val downs = (0 until 16_000 step 2_000).toList()
        assertEquals(0.0, ph(0.0, downs = downs)!!, 1e-9)
        assertEquals(0.25, ph(500.0, downs = downs)!!, 1e-9)
        assertEquals(0.5, ph(1000.0, downs = downs)!!, 1e-9)
        assertEquals(0.9995, ph(1999.0, downs = downs)!!, 1e-3)
        assertEquals(0.0, ph(2000.0, downs = downs)!!, 1e-9)
    }

    @Test fun cyclePhaseAnchorsOnMeasuredDownbeat() {
        val beats = (0 until 16).map { 1000 + it * 500 }
        val downs = listOf(2000, 4000, 6000)
        assertEquals(0.0, ph(2000.0, beats, downs)!!, 1e-9)
        assertEquals(0.25, ph(2500.0, beats, downs)!!, 1e-9)
    }

    @Test fun cyclePhaseTripletsWrapTwiceInTwoBeats() {
        var wraps = 0
        var last = 0.0
        var t = 0.0
        while (t < 1000.0) {
            val v = ph(t, cycle = ModRate.QUARTER_TRIPLET.beats)!!
            if (v < last - 0.5) wraps++
            last = v
            t += 5.0
        }
        assertEquals(2, wraps)
    }

    @Test fun cyclePhaseNegativeBeatPositionsFoldIntoUnitRange() {
        // Synthesised lattice anchored at 10_000: 500 ms before the anchor is -1 beat -> 0.75 of a bar.
        assertEquals(0.75, ph(9_500.0, beats = null, first = 10_000)!!, 1e-9)
        assertEquals(0.0, ph(10_000.0, beats = null, first = 10_000)!!, 1e-9)
        assertEquals(0.25, ph(10_500.0, beats = null, first = 10_000)!!, 1e-9)
        // Before the first MEASURED beat too.
        val early = (0 until 16).map { 1000 + it * 500 }
        val v = ph(750.0, early)!!
        assertTrue(v >= 0.0 && v < 1.0)
        assertEquals(0.875, v, 1e-9)    // -0.5 beat / 4 = -0.125 -> 0.875
    }

    @Test fun cyclePhaseExtendsPastGridAtOwnSpacing() {
        val grid = (0 until 8).map { it * 500 }
        val inside = ph(3_400.0, grid)!!
        val outside = ph(3_600.0, grid)!!
        assertEquals((inside + 0.1) % 1.0, outside, 0.01)
        // No bpm: uses the mean interval of the grid itself.
        val noBpm = BeatMath.cyclePhase(5_000.0, grid, null, 0.0, 0, 4.0)!!
        assertEquals(0.5, noBpm, 1e-9)   // 10 beats / 4 = 2.5 cycles
    }

    @Test fun cyclePhaseNullWhenNothingToLockTo() {
        assertNull(BeatMath.cyclePhase(1000.0, null, null, 0.0, 0, 4.0))
        assertNull(BeatMath.cyclePhase(1000.0, emptyList(), null, 0.0, 0, 4.0))
        assertNull(BeatMath.cyclePhase(1000.0, listOf(0, 500), null, 120.0, 0, 0.0))
    }

    @Test fun cyclePhaseOffsetShiftsExactly() {
        val base = ph(1000.0)!!
        val shifted = ph(1000.0, offset = 0.5)!!
        assertEquals((base + 0.5) % 1.0, shifted, 1e-9)
        assertNotNull(ph(1000.0, offset = -0.25))
    }

    @Test fun cyclePhaseAlwaysInUnitRange() {
        var t = -3000.0
        while (t < 30_000.0) {
            val v = ph(t)!!
            assertTrue("t=$t v=$v", v >= 0.0 && v < 1.0)
            t += 137.0
        }
    }
}

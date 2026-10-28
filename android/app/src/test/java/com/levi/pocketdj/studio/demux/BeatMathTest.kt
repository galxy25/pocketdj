package com.levi.pocketdj.studio.demux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BeatMathTest {
    private val real = listOf(100, 600, 1100, 1650, 2200) // drifting last interval (550)
    private val downs = listOf(102, 2190)                  // rounded independently (<= 30 ms off)

    @Test fun lastBeatBinarySearch() {
        assertNull(BeatMath.lastBeat(real, downs, 50.0))
        assertNull(BeatMath.lastBeat(emptyList(), downs, 5000.0))
        assertEquals(100, BeatMath.lastBeat(real, downs, 100.0)!!.beatMs)
        assertEquals(1100, BeatMath.lastBeat(real, downs, 1649.9)!!.beatMs)
        assertEquals(2200, BeatMath.lastBeat(real, downs, 99999.0)!!.beatMs)
    }

    @Test fun downbeatToleranceIsThirtyMs() {
        assertTrue(BeatMath.lastBeat(real, downs, 100.0)!!.isDownbeat)      // 102 vs 100
        assertTrue(BeatMath.lastBeat(real, downs, 2200.0)!!.isDownbeat)     // 2190 vs 2200
        assertFalse(BeatMath.lastBeat(real, downs, 600.0)!!.isDownbeat)
        assertTrue(BeatMath.isDownbeat(130, listOf(100)))
        assertFalse(BeatMath.isDownbeat(131, listOf(100)))
        assertFalse(BeatMath.isDownbeat(100, null))
        assertFalse(BeatMath.isDownbeat(100, emptyList()))
    }

    @Test fun sliceBoundariesRealGridSumsRealIntervals() {
        val g = BeatGrid(120.0, 100, real)
        val s = BeatMath.sliceBoundaries(550, 2.0, g)!!      // nearest beat >= 550 is 600
        assertEquals(600, s.startMs); assertEquals(1650, s.endMs); assertEquals(1050, s.lengthMs)
        assertEquals(s.endMs - s.startMs, s.lengthMs)
    }

    @Test fun halfBeatEndsAtMidpoint() {
        val s = BeatMath.sliceBoundaries(100, 0.5, BeatGrid(120.0, 100, real))!!
        assertEquals(100, s.startMs); assertEquals(350, s.endMs)
    }

    @Test fun walkPastLastBeatExtendsOnConstantSpacing() {
        val g = BeatGrid(120.0, 100, real)                   // 500 ms extension
        val s = BeatMath.sliceBoundaries(1650, 4.0, g)!!     // 1650,2200,(2700,3200,3700)
        assertEquals(1650, s.startMs); assertEquals(3700, s.endMs)
        // anchor beyond the grid snaps to the first extended beat >= anchor
        val t = BeatMath.sliceBoundaries(2300, 1.0, g)!!
        assertEquals(2700, t.startMs); assertEquals(3200, t.endMs)
    }

    @Test fun constantFallbackAnchorsOnFirstDownbeat() {
        val g = BeatGrid(120.0, 250)                          // no measured beats
        val s = BeatMath.sliceBoundaries(0, 4.0, g)!!
        assertEquals(250, s.startMs); assertEquals(2000, s.lengthMs); assertEquals(2250, s.endMs)
        val u = BeatMath.sliceBoundaries(300, 1.0, g)!!       // next lattice beat >= 300 is 750
        assertEquals(750, u.startMs); assertEquals(500, u.lengthMs)
    }

    @Test fun noUsableGridIsNull() {
        assertNull(BeatMath.sliceBoundaries(0, 4.0, BeatGrid(0.0, 0)))
        assertNull(BeatMath.sliceBoundaries(0, 0.0, BeatGrid(120.0, 0)))
        assertNull(BeatMath.sliceBoundaries(0, 4.0, BeatGrid(0.0, 0, listOf(100)) ))   // one beat, no spacing: walk fails
        assertNotNull(BeatMath.sliceBoundaries(0, 1.0, BeatGrid(0.0, 0, listOf(100, 600))))
    }

    @Test fun sliceStartsEvenWhenGridless() {
        assertEquals(listOf(0, 250, 500, 750), BeatMath.sliceStarts(4, null, 1000))
        assertEquals(listOf(0), BeatMath.sliceStarts(4, null, 0))
        assertEquals(8, BeatMath.sliceStarts(99, null, 8000).size)  // cap 8
        assertEquals(listOf(0), BeatMath.sliceStarts(0, null, 1000)) // min 1
    }

    @Test fun sliceStartsSnapToBeatsAndDedupe() {
        val g = BeatGrid(120.0, 0, listOf(0, 480, 1020, 1480))        // measured
        assertEquals(listOf(0, 480, 1020, 1480), BeatMath.sliceStarts(4, g, 2000).let {
            // targets 0,500,1000,1500 -> nearest beats 0,480,1020,1480
            it
        })
        // everything snaps to the single beat at 0 -> coincident snaps give fewer pads
        assertEquals(listOf(0), BeatMath.sliceStarts(4, BeatGrid(120.0, 0, listOf(0)), 2000))
        // constant lattice: 120 BPM from 0 over 2 s, pads land on the 500 ms lattice
        assertEquals(listOf(0, 500, 1000, 1500), BeatMath.sliceStarts(4, BeatGrid(120.0, 0), 2000))
    }

    @Test fun beatLatticeRewindsToEarliestInRangeBeat() {
        assertEquals(listOf(100, 600, 1100), BeatMath.beatLattice(BeatGrid(120.0, 1100), 1200))
        assertNull(BeatMath.beatLattice(BeatGrid(0.0, 0), 1000))
    }

    @Test fun shiftedGridOnlyKeepsBeatsInsideRegionAndRelativeToItsStart() {
        val g = BeatGrid(120.0, 100, listOf(100, 600, 1100, 1600, 2100))
        val s = BeatMath.shifted(g, 1000, 800)                   // region [1000,1800)
        assertEquals(listOf(100, 600), s.beatsMs)
        assertTrue(s.beatsMs.all { it in 0 until 800 })
    }

    @Test fun shiftPhaseWrapsOntoNextLatticeBeat() {
        assertEquals(400, BeatMath.shiftPhase(1000, 600, 120.0))
        assertEquals(400, BeatMath.shiftPhase(100, 200, 120.0))  // 100-200=-100 -> +500 = 400
    }

    @Test fun inheritedGridFiltersAndRebasesBeats() {
        val g = BeatMath.inheritedGrid(
            beatsMs = listOf(0, 500, 1000, 1500, 2000), downbeatsMs = listOf(0, 2000), sidecarBpm = 120.0,
            regionStartMs = 900, regionEndMs = 1600, fallbackBpm = null, scalarBpm = null,
        )!!
        assertEquals(listOf(100, 600), g.beatsMs)
        assertEquals(100, g.firstDownbeatMs)      // no kept downbeat -> first kept beat
        assertEquals(120.0, g.bpm, 0.0)
    }

    @Test fun inheritedGridKeepsFirstKeptDownbeatAndMedianBpm() {
        val g = BeatMath.inheritedGrid(
            listOf(0, 500, 1000, 1500, 2000, 2600), listOf(0, 1000), null, 400, 2700, null, null,
        )!!
        assertEquals(listOf(100, 600, 1100, 1600, 2200), g.beatsMs)
        assertEquals(600, g.firstDownbeatMs)      // downbeat at 1000 -> 600
        assertEquals(120.0, g.bpm, 1e-9)          // median interval 500
    }

    @Test fun inheritedGridFallsBackToConstantTempoThenNull() {
        // beats exist but none inside the region -> scalar tempo grid
        val c = BeatMath.inheritedGrid(listOf(0, 500), emptyList(), 120.0, 5000, 6000, null, 128.0)!!
        assertTrue(c.beatsMs.isEmpty()); assertEquals(128.0, c.bpm, 0.0); assertEquals(0, c.firstDownbeatMs)
        assertNull(BeatMath.inheritedGrid(emptyList(), emptyList(), null, 0, 1000, null, null))
        assertNull(BeatMath.inheritedGrid(emptyList(), emptyList(), null, 0, 1000, null, 0.0))
    }

    @Test fun medianBpmIgnoresRaggedInterval() {
        assertEquals(120.0, BeatMath.medianBpm(listOf(0, 500, 1000, 1500, 3000))!!, 1e-9)
        assertNull(BeatMath.medianBpm(listOf(10)))
    }
}

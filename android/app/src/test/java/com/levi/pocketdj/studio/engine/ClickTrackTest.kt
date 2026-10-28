package com.levi.pocketdj.studio.engine

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class ClickTrackTest {
    @Test fun barIsFourBeatsAtTheGivenTempo() {
        assertEquals(2.0, ClickTrack.barSeconds(120.0), 1e-9)
        assertEquals(240.0 / 120.0, ClickTrack.barSeconds(Double.NaN), 1e-9)
        assertEquals(240.0 / 120.0, ClickTrack.barSeconds(-5.0), 1e-9)
        assertEquals(44_100 * 2, ClickTrack.makeBar(120.0, 44_100).size)
        assertEquals(4 * ClickTrack.beatFrames(90.0, 48_000), ClickTrack.makeBar(90.0, 48_000).size)
    }

    @Test fun tempoIsClampedToTheTakeRange() {
        assertEquals(40.0, ClickTrack.clampBpm(10.0), 0.0)
        assertEquals(300.0, ClickTrack.clampBpm(999.0), 0.0)
        assertEquals(120.0, ClickTrack.clampBpm(Double.POSITIVE_INFINITY), 0.0)
        assertEquals(ClickTrack.makeBar(300.0, 44_100).size, ClickTrack.makeBar(900.0, 44_100).size)
    }

    @Test fun ticksAreShortDecayingAndSilentBetween() {
        val sr = 44_100
        val bar = ClickTrack.makeBar(120.0, sr)
        val beat = bar.size / 4
        val tick = (0.03 * sr).toInt()
        for (b in 0 until 4) {
            val s = b * beat
            assertEquals(0f, bar[s], 1e-6f)                              // sine starts at 0
            val head = (s until s + tick / 4).maxOf { abs(bar[it]) }
            val tail = (s + tick - tick / 4 until s + tick).maxOf { abs(bar[it]) }
            assertTrue("tick decays", head > tail * 3)
            assertTrue("peak <= 0.5", head <= 0.5f + 1e-6f)
            for (i in s + tick until s + beat) assertEquals(0f, bar[i], 0f)
        }
    }

    @Test fun beatOneHasTheHigherPitch() {
        val sr = 44_100
        val bar = ClickTrack.makeBar(60.0, sr)
        val beat = bar.size / 4
        fun crossings(from: Int) = (from + 1 until from + (0.03 * sr).toInt()).count { bar[it - 1] < 0 && bar[it] >= 0 || bar[it - 1] > 0 && bar[it] <= 0 }
        assertTrue(crossings(0) > crossings(beat) * 1.4)
        assertEquals(crossings(beat).toDouble(), crossings(2 * beat).toDouble(), 1.0)
    }

    @Test fun tailFromBeatReturnsTheBarRemainder() {
        val bar = ClickTrack.makeBar(120.0, 8_000)
        assertNull(ClickTrack.tailFromBeat(bar, 0))
        val t = ClickTrack.tailFromBeat(bar, 2)!!
        assertEquals(bar.size / 2, t.size)
        assertArrayEquals(bar.copyOfRange(bar.size / 2, bar.size), t, 0f)
        assertEquals(bar.size / 4, ClickTrack.tailFromBeat(bar, 99)!!.size)   // clamped to beat 3
    }

    @Test fun nextBarAnchorStaysPhaseLockedToBeat1IncludingBeforeIt() {
        // beat 1 at t=10, bar = 2 s; now=13.1 (+0.05 lead) -> next boundary 14
        assertEquals(14.0, ClickTrack.nextBarAnchor(13.1, 10.0, 2.0), 1e-9)
        // during the count-in (before beat 1): boundaries are negative bar indices
        assertEquals(8.0, ClickTrack.nextBarAnchor(7.2, 10.0, 2.0), 1e-9)
        assertEquals(5.05, ClickTrack.nextBarAnchor(5.0, 10.0, 0.0), 1e-9)
    }

    @Test fun nextBeatOnGridWrapsNegativeBeatIndicesPositively() {
        val a = ClickTrack.nextBeatOnGrid(nowSec = 10.30, gridSec = 10.0, beatSec = 0.5)
        assertEquals(10.5, a.atSec, 1e-9); assertEquals(1, a.beatInBar)
        val b = ClickTrack.nextBeatOnGrid(nowSec = 9.30, gridSec = 10.0, beatSec = 0.5)     // before the grid anchor
        assertEquals(9.5, b.atSec, 1e-9); assertEquals(3, b.beatInBar)                       // beat index -1 => beat 4 of the bar
        val c = ClickTrack.nextBeatOnGrid(nowSec = 11.95, gridSec = 10.0, beatSec = 0.5)
        assertEquals(12.0, c.atSec, 1e-9); assertEquals(0, c.beatInBar)                      // the bar line
    }

    @Test fun nextBeatOnGridDegradesOnWildInputWithoutThrowing() {
        assertEquals(0, ClickTrack.nextBeatOnGrid(1.0, 0.0, 0.0).beatInBar)
        assertEquals(1.05, ClickTrack.nextBeatOnGrid(1.0, Double.NaN, 0.5).atSec, 1e-9)
        assertEquals(0, ClickTrack.nextBeatOnGrid(1e18, 0.0, 1e-6).beatInBar)
    }

    @Test fun voiceIsSilentBeforeItsStartFrameAndLoopsTheBarAfter() {
        val sr = 8_000
        val v = ClickTrack.Voice()
        val out = FloatArray(2 * 64)
        v.mixInto(out, 64, 0)                                    // off => untouched
        assertTrue(out.all { it == 0f })
        v.start(120.0, sr, startFrame = 100)
        assertTrue(v.isOn)
        val bar = ClickTrack.makeBar(120.0, sr)
        val block = FloatArray(2 * 200)
        v.mixInto(block, 200, 0)
        for (i in 0 until 100) { assertEquals(0f, block[2 * i], 0f) }       // before start: silent
        for (i in 100 until 200) { assertEquals(bar[i - 100], block[2 * i], 1e-7f); assertEquals(block[2 * i], block[2 * i + 1], 0f) }
        // one bar later the loop wraps to its beginning
        val wrap = FloatArray(2 * 8)
        v.mixInto(wrap, 8, 100L + bar.size)
        for (i in 0 until 8) assertEquals(bar[i], wrap[2 * i], 1e-7f)
        v.stop(); assertFalse(v.isOn)
    }

    @Test fun voiceAddsToWhatIsAlreadyInTheBlock() {
        val v = ClickTrack.Voice(gain = 1f)
        v.start(120.0, 8_000, 0)
        val out = FloatArray(2 * 40) { 0.25f }
        v.mixInto(out, 40, 0)
        val bar = ClickTrack.makeBar(120.0, 8_000)
        for (i in 0 until 40) assertEquals(0.25f + bar[i], out[2 * i], 1e-7f)
    }
}

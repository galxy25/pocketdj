package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceGroupHoldTest {
    private fun settle(vs: List<Voice>) {
        val s = FloatArray(2)
        repeat(6) { for (v in vs) { v.pump(); v.read(s, 0, Long.MIN_VALUE / 2); while (v.pump()) { } } }
    }
    private fun frames(o: FloatArray, n: Int) = (0 until n).map { SyntheticPcmSource.frameOf(o[2 * it]) }

    @Test fun oneStemUnderrunningHoldsTheWholeGroupSoStemsNeverDrift() {
        val lagging = SyntheticPcmSource.counter(total = 10_000, available = 40).also { it.forceIncomplete = true }
        val a = Voice(SyntheticPcmSource.counter(10_000))
        val b = Voice(lagging)
        a.schedule(0); b.schedule(0, to = 10_000, final = false)
        settle(listOf(a, b))
        val g = VoiceGroup(listOf(a, b))
        g.startAt(0)
        val outs = listOf(FloatArray(200), FloatArray(200))
        assertFalse(g.read(outs, 100, 0))      // b has only 40 frames: hold everything
        assertTrue(g.holding)
        assertTrue(outs.all { o -> o.all { it == 0f } })
        assertEquals(0L, a.playerFrame); assertEquals(0L, b.playerFrame)
        lagging.available = 5000
        settle(listOf(a, b))
        assertTrue(g.read(outs, 100, 100))
        assertEquals((0L until 100L).toList(), frames(outs[0], 100))
        assertEquals((0L until 100L).toList(), frames(outs[1], 100))
    }

    @Test fun startTogetherRefusesWhileAnyVoiceIsNotReady() {
        val a = Voice(SyntheticPcmSource.counter(10_000)); val b = Voice(SyntheticPcmSource.counter(10_000))
        a.schedule(0); settle(listOf(a))
        b.schedule(0) // never settled
        val g = VoiceGroup(listOf(a, b))
        assertEquals(-1L, g.startTogether(RenderClock(44_100)))
        assertTrue(listOf(a, b).none { it.isPlaying })
        settle(listOf(a, b))
        assertTrue(g.startTogether(RenderClock(44_100)) >= 0)
        assertTrue(listOf(a, b).all { it.isPlaying })
    }
}

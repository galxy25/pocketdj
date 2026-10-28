package com.levi.pocketdj.playback.health

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CascadeBreakerTest {
    @Test
    fun thirdConsecutiveQuickAdvance_trips_andDoesNotAdvance() {
        val b = AutoAdvanceCascadeBreaker()
        assertFalse(b.shouldHalt(0.0))
        assertFalse(b.shouldHalt(4.9))
        assertTrue("the Nth quick advance is the one that halts", b.shouldHalt(1.0))
    }

    @Test
    fun trip_rearmsTheCounter() {
        val b = AutoAdvanceCascadeBreaker()
        repeat(2) { b.shouldHalt(0.0) }
        assertTrue(b.shouldHalt(0.0))
        assertEquals(0, b.quickAdvances)
        assertFalse(b.shouldHalt(0.0))
    }

    @Test
    fun aTrackThatPlayedFiveSeconds_resetsTheRun() {
        val b = AutoAdvanceCascadeBreaker()
        b.shouldHalt(0.0)
        b.shouldHalt(0.0)
        assertFalse("5.0 s is audible enough", b.shouldHalt(5.0))
        assertEquals(0, b.quickAdvances)
        assertFalse(b.shouldHalt(0.0))
        assertFalse(b.shouldHalt(0.0))
        assertTrue(b.shouldHalt(0.0))
    }

    @Test
    fun userTransport_resets() {
        val b = AutoAdvanceCascadeBreaker()
        b.shouldHalt(0.0)
        b.shouldHalt(0.0)
        b.reset()
        assertFalse(b.shouldHalt(0.0))
        assertEquals(1, b.quickAdvances)
    }

    @Test
    fun noticesMatchIosCopy() {
        assertEquals("Playback paused — the last few tracks didn’t play", AutoAdvanceCascadeBreaker.GENERIC_NOTICE)
        assertEquals("Playback paused — Apple Music was interrupted", AutoAdvanceCascadeBreaker.APPLE_MUSIC_NOTICE)
    }
}

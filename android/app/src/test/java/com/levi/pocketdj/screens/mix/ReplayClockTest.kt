package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.store.MixSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayClockTest {
    private val t = listOf(0, 500, 500, 500, 2000, 5000)

    @Test fun emptyIsNull() = assertNull(ReplayClock.currentIndex(emptyList(), 100.0))

    @Test fun beforeFirstIsNull() = assertNull(ReplayClock.currentIndex(listOf(100, 200), 50.0))

    @Test fun exactHitReturnsFirstOfCluster() {
        assertEquals(0, ReplayClock.currentIndex(t, 0.0))
        assertEquals(1, ReplayClock.currentIndex(t, 500.0))
    }

    @Test fun betweenReturnsLastStrictlyBefore() {
        assertEquals(3, ReplayClock.currentIndex(t, 501.0))
        assertEquals(3, ReplayClock.currentIndex(t, 1999.0))
        assertEquals(4, ReplayClock.currentIndex(t, 2000.0))
        assertEquals(5, ReplayClock.currentIndex(t, 99999.0))
    }

    @Test fun advanceScalesBySpeedAndClamps() {
        assertEquals(1100.0, ReplayClock.advance(1000.0, 100.0, 1.0, 5000), 1e-9)
        assertEquals(1400.0, ReplayClock.advance(1000.0, 100.0, 4.0, 5000), 1e-9)
        assertEquals(1050.0, ReplayClock.advance(1000.0, 100.0, 0.5, 5000), 1e-9)
        assertEquals(5000.0, ReplayClock.advance(4990.0, 100.0, 4.0, 5000), 1e-9)
        assertTrue(ReplayClock.isFinished(5000.0, 5000))
        assertFalse(ReplayClock.isFinished(4999.0, 5000))
    }

    @Test fun playAtEndRestarts() {
        assertEquals(0.0, ReplayClock.startPosition(5000.0, 5000), 0.0)
        assertEquals(1234.0, ReplayClock.startPosition(1234.0, 5000), 0.0)
    }

    @Test fun autoScrollOnlyWhilePlayingAndNotScrubbing() {
        assertTrue(ReplayClock.shouldAutoScroll(playing = true, scrubbing = false))
        assertFalse(ReplayClock.shouldAutoScroll(playing = true, scrubbing = true))
        assertFalse(ReplayClock.shouldAutoScroll(playing = false, scrubbing = false))
    }

    @Test fun speedsAndLabels() {
        assertEquals(listOf(0.5, 1.0, 2.0, 4.0), ReplayClock.SPEEDS)
        assertEquals(listOf("0.5×", "1×", "2×", "4×"), ReplayClock.SPEEDS.map(ReplayClock::speedLabel))
    }

    @Test fun rowSummaryAndOrdering() {
        assertEquals("1:05 · 1 track · 2 actions", SessionRowText.summary(65_000, 1, 2, 0))
        assertEquals("0:00 · 0 tracks · 1 action · 2 rec", SessionRowText.summary(0, 0, 1, 2))
        val s = listOf(MixSession("a", "A", 1.0), MixSession("b", "B", 5.0), MixSession("c", "C", 3.0))
        assertEquals(listOf("b", "c", "a"), SessionRowText.newestFirst(s).map { it.id })
    }
}

package com.levi.pocketdj.playback.health

import com.levi.pocketdj.playback.health.PlaybackRipWindow.Row
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RipWindowTest {
    private fun rows(n: Int) = (0 until n).map { Row("s$it") }

    @Test
    fun window_isThePlayingRowPlusTheNextTen() {
        val ids = PlaybackRipWindow.windowIds(rows(30), 5)
        assertEquals((5..15).map { "s$it" }.toSet(), ids)
        assertEquals(11, ids.size)
    }

    @Test
    fun window_clampsAtTheTailAndRejectsBadIndex() {
        assertEquals(setOf("s28", "s29"), PlaybackRipWindow.windowIds(rows(30), 28))
        assertTrue(PlaybackRipWindow.windowIds(rows(3), 3).isEmpty())
        assertTrue(PlaybackRipWindow.windowIds(rows(3), -1).isEmpty())
    }

    @Test
    fun window_contributesBothBaseAndResolveIds() {
        val ids = PlaybackRipWindow.windowIds(listOf(Row("sng_a", "sng_a_clean"), Row("sng_b")), 0)
        assertEquals(setOf("sng_a", "sng_a_clean", "sng_b"), ids)
    }

    @Test
    fun allows_onlyInsideTheWindow() {
        val r = rows(30)
        assertTrue(PlaybackRipWindow.allows("s10", r, 0))
        assertFalse(PlaybackRipWindow.allows("s11", r, 0))
        assertTrue(PlaybackRipWindow.allows("s11", r, 1))
    }

    @Test
    fun evict_returnsSortedIdsOutsideWindow_andForgetsThem() {
        val w = PlaybackRipWindow()
        listOf("s3", "s1", "s20", "s2").forEach(w::record)
        val out = w.evict(setOf("s1", "s2", "s3"))
        assertEquals(listOf("s20"), out)
        assertEquals(setOf("s3", "s1", "s2"), w.requested)
        assertTrue("a second evict has nothing left to cancel", w.evict(setOf("s1", "s2", "s3")).isEmpty())
    }

    @Test
    fun keep_exemptsAHeardRow() {
        val w = PlaybackRipWindow()
        w.record("s1")
        w.record("s2")
        w.keep(setOf("s1", "s1_clean"))
        assertEquals(listOf("s2"), w.evict(emptySet()))
    }

    @Test
    fun endSession_cancelsEverythingExceptThePlayingRow_andClears() {
        val w = PlaybackRipWindow()
        listOf("s0", "s4", "s5").forEach(w::record)
        assertEquals(listOf("s4", "s5"), w.endSession(setOf("s0")))
        assertTrue(w.requested.isEmpty())
    }

    @Test
    fun constants_matchIos() {
        assertEquals(10, PlaybackRipWindow.AHEAD)
        assertEquals(30.0, PlaybackRipWindow.HEARD_SECONDS, 0.0)
    }
}

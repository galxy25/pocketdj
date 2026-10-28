package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PreloadReviewTest {
    private suspend fun kotlinx.coroutines.test.TestScope.armed(vararg ids: String): SequencerHarness {
        val h = SequencerHarness(this, backgroundScope, ids.toSet())
        h.seq.preloadEnabled = true
        h.seq.play(rows(*ids))
        h.settle()
        h.seq.onFirstAudio("a")
        h.settle()
        return h
    }

    @Test
    fun preloadedTransition_advancesToPreloadedRow_withoutReload() = runTest {
        val h = armed("a", "b", "c")
        assertEquals("b", h.port.preloadedId)
        assertTrue(h.seq.handlePreloadedTransition("b"))
        h.settle()
        assertEquals(1, h.index)
        assertEquals(listOf("a"), h.port.loadedIds)
    }

    @Test
    fun lostRow_advancesPastEndedRow_neverReplaysIt() = runTest {
        val h = armed("a", "b", "c")
        // B leaves the queue but the engine already rolled onto it (slot still recorded).
        val bUid = h.seq.state.value.queue[1].uid
        h.seq.removeUpcoming(setOf(bUid))
        assertTrue(h.seq.handlePreloadedTransition("b"))
        h.settle()
        assertEquals(listOf("a", "c"), h.port.loadedIds)
        assertFalse(h.port.loadedIds.count { it == "a" } > 1)
    }

    @Test
    fun skipLoadPending_ignoresStrayAutoTransition() = runTest {
        val h = armed("a", "b", "c")
        h.seq.skipNext()            // cursor moved, load job launched but not yet run
        assertFalse(h.seq.handlePreloadedTransition("b"))
    }

    @Test
    fun notRendering_keepsDeadAirOpen() = runTest {
        val h = armed("a", "b", "c")
        assertTrue(h.seq.handlePreloadedTransition("b", rendering = false))
        h.settle()
        assertEquals(1, h.index)
        // first audio still owed: onFirstAudio for b closes it later
        h.seq.onFirstAudio("b")
        h.settle()
    }
}

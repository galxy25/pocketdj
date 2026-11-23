package com.levi.pocketdj.playback.health

import com.levi.pocketdj.playback.sequencer.QueueItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The abandoned-uid filter of [ResolveStallHop.choose] (iOS 532ac59f stall episode). */
class ResolveStallHopEpisodeTest {
    private val q = listOf("a", "b", "c", "d").map { QueueItem(id = it) }
    private fun uid(id: String) = q.first { it.id == id }.uid

    @Test
    fun abandonedRowIsNeverChosen_nextEligibleWins() {
        val c = ResolveStallHop.choose(q, 1, { false }, { true }, abandoned = setOf(uid("c")))
        assertEquals(3, c!!.queueIndex) // c abandoned -> d
    }

    @Test
    fun onDeviceStillPreferredOverInstant_amongNonAbandoned() {
        val c = ResolveStallHop.choose(q, 0, { it.id == "d" }, { it.id == "b" }, abandoned = setOf(uid("c")))
        assertEquals(ResolveStallHop.Kind.ON_DEVICE, c!!.kind)
        assertEquals(3, c.queueIndex)
    }

    @Test
    fun abandonedOnDeviceRowFallsThroughToInstant() {
        val c = ResolveStallHop.choose(q, 0, { it.id == "d" }, { it.id == "b" }, abandoned = setOf(uid("d")))
        assertEquals(ResolveStallHop.Kind.INSTANT, c!!.kind)
        assertEquals(1, c.queueIndex)
    }

    @Test
    fun everyCandidateAbandoned_returnsNull() {
        assertNull(ResolveStallHop.choose(q, 0, { true }, { true }, abandoned = setOf(uid("b"), uid("c"), uid("d"))))
    }

    @Test
    fun emptyAbandonedBehavesAsBefore() {
        assertEquals(1, ResolveStallHop.choose(q, 0, { false }, { true })!!.queueIndex)
    }
}

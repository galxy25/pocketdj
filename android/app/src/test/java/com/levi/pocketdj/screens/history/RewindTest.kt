package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.playback.sequencer.QueueItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RewindTest {

    private fun ev(id: String, song: String, ctx: String?, source: PlaySource = PlaySource.ALBUM, name: String? = null) =
        PlayEvent(id = id, songId = song, playedAt = id.hashCode().toDouble(), source = source, contextId = ctx, contextName = name)

    private val log = listOf(
        ev("e1", "a", "ctxX"),
        ev("e2", "b", "ctxY", name = "Set Y"),
        ev("e3", "c", "ctxY"),
        ev("e4", "d", "ctxY"),
        ev("e5", "e", "ctxZ"),
        ev("e6", "f", "ctxY"), // same context as e2..e4 but NOT contiguous -> a different run
    )

    @Test
    fun slice_startsAtEvent_andStopsAtFirstDifferentContext() {
        assertEquals(listOf("e2", "e3", "e4"), Rewind.slice("e2", log).map { it.id })
        assertEquals(listOf("e3", "e4"), Rewind.slice("e3", log).map { it.id })
    }

    @Test
    fun slice_lastEvent_isJustItself_andMissingEventIsEmpty() {
        assertEquals(listOf("e6"), Rewind.slice("e6", log).map { it.id })
        assertTrue(Rewind.slice("nope", log).isEmpty())
        assertTrue(Rewind.slice("e1", emptyList()).isEmpty())
    }

    @Test
    fun slice_nullContextRunsGroupTogether() {
        val events = listOf(ev("n1", "a", null), ev("n2", "b", null), ev("n3", "c", "k"))
        assertEquals(listOf("n1", "n2"), Rewind.slice("n1", events).map { it.id })
    }

    private fun q(vararg ids: String) = ids.map { QueueItem(id = it, uid = "uid-$it") }

    @Test
    fun sameRunUid_isLastPlayedOccurrenceBeforeCursor() {
        val uids = q("a", "b", "a", "c", "d").mapIndexed { i, it -> it.copy(uid = "u$i") } // cursor 3 -> played = a b a
        assertEquals("u2", Rewind.sameRunUid(uids, 3, true, "a"))
        assertEquals("u1", Rewind.sameRunUid(uids, 3, true, "b"))
    }

    @Test
    fun sameRunUid_ignoresUpcomingAndCurrentAndIdleQueues() {
        val uids = q("a", "b", "c").mapIndexed { i, it -> it.copy(uid = "u$i") }
        assertNull("c is current/upcoming, not played", Rewind.sameRunUid(uids, 2, true, "c"))
        assertNull("not running", Rewind.sameRunUid(uids, 2, false, "a"))
        assertNull("nothing played yet", Rewind.sameRunUid(uids, 0, true, "a"))
    }

    @Test
    fun plan_prefersCursorMoveWhenSongIsInLiveQueue() {
        val live = q("b", "c", "z").mapIndexed { i, it -> it.copy(uid = "u$i") }
        val plan = Rewind.plan("e2", log, live, index = 2, isRunning = true)
        assertEquals(Rewind.Plan.CursorMove("u0"), plan)
    }

    @Test
    fun plan_pastRun_replaysSliceUnderEventSourceToken() {
        val plan = Rewind.plan("e2", log, emptyList(), index = 0, isRunning = false)
        assertEquals(Rewind.Plan.Replay(listOf("b", "c", "d"), "Set Y", "album"), plan)
    }

    @Test
    fun plan_namelessContextFallsBackToHistory_andMissingEventIsNothing() {
        val plan = Rewind.plan("e1", log, emptyList(), 0, false) as Rewind.Plan.Replay
        assertEquals("History", plan.name)
        assertEquals(Rewind.Plan.Nothing, Rewind.plan("gone", log, emptyList(), 0, false))
    }
}

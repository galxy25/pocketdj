package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every live edit touches only queue[index+1...]; rows are addressed by uid, never position. */
@OptIn(ExperimentalCoroutinesApi::class)
class LiveEditsTest {
    private val all = setOf("a", "b", "c", "d", "e", "f", "x", "y")

    private fun TestScope.running(vararg ids: String, at: Int = 0): SequencerHarness {
        val h = SequencerHarness(this, backgroundScope, all)
        h.seq.play(rows(*ids))
        h.settle()
        repeat(at) { h.seq.skipNext(); h.settle() }
        return h
    }

    private fun SequencerHarness.uid(id: String) = seq.state.value.queue.first { it.id == id }.uid

    /** The head + current must be byte-identical after an edit. */
    private fun SequencerHarness.headThroughCurrent() =
        seq.state.value.queue.take(index + 1).map { it.uid }

    @Test
    fun moveUpcoming_reordersTailOnly_headAndCurrentUntouched() = runTest {
        val h = running("a", "b", "c", "d", "e", at = 1) // current b, tail c d e
        val head = h.headThroughCurrent()
        h.seq.moveUpcoming(listOf(0), 3) // c to the end
        assertEquals(listOf("a", "b", "d", "e", "c"), h.ids)
        assertEquals(head, h.headThroughCurrent())
        assertEquals(1, h.index)
    }

    @Test
    fun moveUpcoming_staleToOffsetClampedToLiveTail_andStaleSourcesDropped() = runTest {
        val h = running("a", "b", "c", "d")
        h.seq.moveUpcoming(listOf(0), 500) // drag ended against a render-time snapshot
        assertEquals(listOf("a", "c", "d", "b"), h.ids)
        h.seq.moveUpcoming(listOf(42), 0) // nothing valid to move
        assertEquals(listOf("a", "c", "d", "b"), h.ids)
        h.seq.moveUpcoming(listOf(2, 99), -7) // negative clamps to the tail head
        assertEquals(listOf("a", "b", "c", "d"), h.ids)
    }

    @Test
    fun moveUpcoming_multiSelect_keepsRelativeOrder_swiftUiSemantics() = runTest {
        val h = running("a", "b", "c", "d", "e") // tail b c d e
        h.seq.moveUpcoming(listOf(0, 1), 4) // b,c before the element originally at offset 4 (end)
        assertEquals(listOf("a", "d", "e", "b", "c"), h.ids)
    }

    @Test
    fun removeUpcoming_byUid_ignoresUnknownAndPlayedAndCurrent() = runTest {
        val h = running("a", "b", "c", "d", at = 1) // played a, current b
        val played = h.uid("a")
        val current = h.uid("b")
        val c = h.uid("c")
        h.seq.removeUpcoming(setOf(played, current, "nope", c))
        assertEquals(listOf("a", "b", "d"), h.ids)
        assertEquals(1, h.index)
    }

    @Test
    fun removeUpcoming_isUidAddressed_soARacingAdvanceCannotDeleteTheWrongRow() = runTest {
        val h = running("a", "b", "c", "d")
        val offset0 = h.seq.upcomingUid(0)!! // the panel rendered "b" at offset 0
        h.seq.skipNext(); h.settle() // playback advanced under the tap: b is now current
        h.seq.removeUpcoming(setOf(offset0)) // stale tap on b
        assertEquals(listOf("a", "b", "c", "d"), h.ids) // b is current -> protected; c was NOT deleted
        // The positional bridge re-reads identity at the live position.
        assertEquals(h.uid("c"), h.seq.upcomingUid(0))
    }

    @Test
    fun upcomingUid_outOfTailOrIdle_isNull() = runTest {
        val h = running("a", "b")
        assertNull(h.seq.upcomingUid(5))
        assertNull(h.seq.upcomingUid(-1))
        h.seq.stop()
        assertNull(h.seq.upcomingUid(0))
    }

    @Test
    fun insertNextInQueue_landsRightAfterCurrent() = runTest {
        val h = running("a", "b", "c", at = 1)
        h.seq.insertNextInQueue(rows("x", "y"))
        assertEquals(listOf("a", "b", "x", "y", "c"), h.ids)
        assertEquals(1, h.index)
    }

    @Test
    fun appendToQueue_noOpWhenIdle_appendsWhenRunning() = runTest {
        val h = SequencerHarness(this, backgroundScope, all)
        h.seq.appendToQueue(rows("x"))
        assertTrue(h.ids.isEmpty())
        h.seq.play(rows("a"))
        h.settle()
        h.seq.appendToQueue(rows("x"))
        assertEquals(listOf("a", "x"), h.ids)
    }

    @Test
    fun insertInQueue_beforeUpcomingUid_elseFallsBackToAppend() = runTest {
        val h = running("a", "b", "c", "d", at = 1)
        h.seq.insertInQueue(rows("x"), beforeUid = h.uid("d"))
        assertEquals(listOf("a", "b", "c", "x", "d"), h.ids)
        h.seq.insertInQueue(rows("y"), beforeUid = h.uid("a")) // played anchor
        assertEquals(listOf("a", "b", "c", "x", "d", "y"), h.ids)
        h.seq.insertInQueue(rows("e"), beforeUid = "ghost")
        assertEquals("e", h.ids.last())
    }

    @Test
    fun insertRandomInQueue_usesInjectedSlot_neverBeforeTheTail() = runTest {
        val h = running("a", "b", "c", at = 1)
        var range: IntRange? = null
        h.seq.insertRandomInQueue(rows("x")) { r -> range = r; r.last }
        assertEquals(2..3, range) // right after current .. very end
        assertEquals(listOf("a", "b", "c", "x"), h.ids)
        h.seq.insertRandomInQueue(rows("y")) { r -> r.first }
        assertEquals(listOf("a", "b", "y", "c", "x"), h.ids)
        h.seq.insertRandomInQueue(rows("e")) { -50 } // a hostile slot is clamped into the tail
        assertEquals("e", h.ids[2])
        assertEquals("b", h.ids[1])
    }

    @Test
    fun moveUpcomingNext_andToEnd_byIdentity() = runTest {
        val h = running("a", "b", "c", "d")
        h.seq.moveUpcomingNext(h.uid("d"))
        assertEquals(listOf("a", "d", "b", "c"), h.ids)
        h.seq.moveUpcomingToEnd(h.uid("d"))
        assertEquals(listOf("a", "b", "c", "d"), h.ids)
        h.seq.moveUpcomingNext(h.uid("a")) // current: ignored
        h.seq.moveUpcomingToEnd("ghost")
        assertEquals(listOf("a", "b", "c", "d"), h.ids)
    }

    @Test
    fun jumpToUpcoming_landsOnExactlyTheTappedInstance_notTheFirstDuplicateSong() = runTest {
        val h = running("a", "x", "b", "x", "c")
        val second = h.seq.state.value.queue[3].uid
        h.seq.jumpToUpcoming(second)
        h.settle()
        assertEquals(3, h.index)
        assertEquals("x", h.port.loadedIds.last())
        // Rows jumped over land in the played region, in place.
        assertEquals(listOf("a", "x", "b"), h.seq.state.value.played.map { it.id })
    }

    @Test
    fun jumpToUpcoming_unknownOrPlayedUid_isSafeNoOp() = runTest {
        val h = running("a", "b", "c", at = 1)
        val loads = h.port.loads.size
        h.seq.jumpToUpcoming("ghost")
        h.seq.jumpToUpcoming(h.uid("a"))
        h.settle()
        assertEquals(1, h.index)
        assertEquals(loads, h.port.loads.size)
    }

    @Test
    fun playNow_splicesAFreshCopyAfterCurrent_andStepsOntoIt() = runTest {
        val h = running("a", "b", "c", at = 1)
        val fresh = QueueItem("x")
        h.seq.playNow(fresh)
        h.settle()
        assertEquals(listOf("a", "b", "x", "c"), h.ids)
        assertEquals(2, h.index)
        assertEquals("x", h.port.loadedIds.last())
        // The interrupted row stays in the played region; the tail that was coming up is untouched.
        assertEquals(listOf("a", "b"), h.seq.state.value.played.map { it.id })
        assertEquals(listOf("c"), h.seq.state.value.upcoming.map { it.id })
    }

    @Test
    fun playNow_withADuplicateUid_getsAFreshIdentity() = runTest {
        val h = running("a", "b", "c", at = 1)
        val playedRow = h.seq.state.value.queue[0]
        h.seq.playNow(playedRow) // caller forgot freshInstance()
        val uids = h.seq.state.value.queue.map { it.uid }
        assertEquals(uids.size, uids.toSet().size)
        assertEquals("a", h.seq.currentSongId)
    }

    @Test
    fun playNow_whenIdle_isNoOp() = runTest {
        val h = SequencerHarness(this, backgroundScope, all)
        h.seq.playNow(QueueItem("x"))
        h.settle()
        assertFalse(h.seq.isRunning)
        assertTrue(h.port.loads.isEmpty())
    }

    @Test
    fun jumpToPlayed_rewinds_rowsBetweenReturnToTheTail() = runTest {
        val h = running("a", "b", "c", "d", at = 3)
        h.seq.jumpToPlayed(h.uid("b"))
        h.settle()
        assertEquals(1, h.index)
        assertEquals("b", h.port.loadedIds.last())
        assertEquals(listOf("c", "d"), h.seq.state.value.upcoming.map { it.id })
        h.seq.jumpToPlayed(h.uid("d")) // upcoming now: ignored
        assertEquals(1, h.index)
    }

    @Test
    fun everyEdit_keepsHeadAndCurrentIdentical() = runTest {
        val h = running("a", "b", "c", "d", "e", at = 2)
        val head = h.headThroughCurrent()
        h.seq.insertNextInQueue(rows("x"))
        h.seq.appendToQueue(rows("y"))
        h.seq.moveUpcoming(listOf(0), 3)
        h.seq.removeUpcoming(setOf(h.uid("e")))
        h.seq.moveUpcomingToEnd(h.uid("d"))
        h.seq.setShuffle(true)
        h.seq.setShuffle(false)
        assertEquals(head, h.headThroughCurrent())
    }
}

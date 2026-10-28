package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.playback.sequencer.SequencerHarness
import com.levi.pocketdj.playback.sequencer.rows
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** Gesture -> sequencer, end to end against the REAL sequencer: the queue may advance under a finger. */
@OptIn(ExperimentalCoroutinesApi::class)
class UpNextUidEditsTest {
    private val all = setOf("a", "b", "c", "d", "e", "f", "g", "h", "i", "j")

    private fun TestScope.running(vararg ids: String): SequencerHarness {
        val h = SequencerHarness(this, backgroundScope, all)
        h.seq.play(rows(*ids))
        h.settle()
        return h
    }

    private fun SequencerHarness.liveUids() = seq.state.value.upcoming.map { it.uid }

    @Test fun reorderRow3AboveRow1_whileCurrentEnds_keepsOrderRelativeToNewCurrent() = runTest {
        val h = running("a", "b", "c", "d", "e")
        val up = h.seq.state.value.upcoming // b c d e
        val dragged = up[2].uid // "d" (row 3)
        // Finger goes down on d; meanwhile the current track ends and the cursor advances to b.
        h.seq.skipNext(); h.settle()
        val move = QueueReorder.resolveMove(h.liveUids(), dragged, -2)!! // 2 rows up
        h.seq.moveUpcoming(listOf(move.fromOffset), move.toOffset)
        assertEquals(listOf("a", "b", "d", "c", "e"), h.ids)
        assertEquals(1, h.index)
    }

    @Test fun removeByUid_removesExactlyTheTappedRow_whenQueueAdvancedUnderneath() = runTest {
        val h = running("a", "b", "c", "d")
        val tapped = h.seq.state.value.upcoming[1].uid // "c"
        h.seq.skipNext(); h.settle() // b now current; positions shifted
        h.seq.removeUpcoming(setOf(tapped))
        assertEquals(listOf("a", "b", "d"), h.ids)
    }

    @Test fun tapOnRowThatAlreadyBecameCurrent_isSafeNoOp() = runTest {
        val h = running("a", "b", "c")
        val b = h.seq.state.value.upcoming[0].uid
        h.seq.skipNext(); h.settle() // b is now current, no longer upcoming
        val before = h.ids
        h.seq.jumpToUpcoming(b)
        h.seq.moveUpcomingNext(b)
        h.seq.moveUpcomingToEnd(b)
        assertEquals(before, h.ids)
        assertEquals(1, h.index)
    }

    @Test fun staleDragOfRemovedRowResolvesToNothing() = runTest {
        val h = running("a", "b", "c", "d")
        val c = h.seq.state.value.upcoming[1].uid
        h.seq.removeUpcoming(setOf(c))
        assertEquals(null, QueueReorder.resolveMove(h.liveUids(), c, 1))
    }

    @Test fun playedRowsOfferRewindAndFreshPlayNow() = runTest {
        val h = running("a", "b", "c")
        h.seq.skipNext(); h.settle()
        h.seq.skipNext(); h.settle()
        val played = h.seq.state.value.played
        assertEquals(listOf("a", "b"), played.map { it.id })
        h.seq.playNow(played[0].freshInstance()); h.settle()
        // Fresh copy spliced after current c; original played row untouched, uids stay unique.
        val q = h.seq.state.value.queue
        assertEquals(q.size, q.map { it.uid }.toSet().size)
        assertEquals("a", h.seq.state.value.current!!.id)
        h.seq.jumpToPlayed(played[1].uid); h.settle()
        assertEquals("b", h.seq.state.value.current!!.id)
    }
}

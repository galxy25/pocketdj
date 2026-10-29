package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Q94: a clean-only run never plays an explicit row with no clean cut - and never shifts an index. */
@OptIn(ExperimentalCoroutinesApi::class)
class CleanOnlySkipTest {
    private fun skip(id: String) = QueueItem(id = id, title = id, cleanOnlySkip = true)

    @Test
    fun skippedRow_keepsItsSlot_isNeverLoaded_andPlayAdvancesPastIt() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "x", "c"))
        h.seq.play(listOf(QueueItem("a", "a"), skip("x"), QueueItem("c", "c")), preStamped = true); h.settle()
        assertEquals(listOf("a", "x", "c"), h.ids) // no removal
        h.seq.handleEnded("a"); h.settle()
        assertEquals(2, h.index) // hopped over x, c is current
        assertEquals(listOf("a", "c"), h.port.loads.map { it.item.id })
        assertTrue(h.logs.any { it.contains("reason=CLEAN_ONLY_EXPLICIT") })
        assertFalse(h.logs.any { it.contains("track start song=x") })
        assertEquals(listOf("a", "x", "c"), h.ids)
    }

    @Test
    fun skipPrevious_stepsBackPastSkippedRows() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "x", "b"))
        h.seq.play(listOf(QueueItem("a", "a"), skip("x"), QueueItem("b", "b")), preStamped = true, startIndex = 2); h.settle()
        assertEquals(2, h.index)
        h.seq.skipPrevious(); h.settle()
        assertEquals(0, h.index) // a, not a bounce back onto b
        assertEquals("a", h.port.loads.last().item.id)
        // nothing playable before: restart the current row
        h.seq.skipNext(); h.settle()
        assertEquals(2, h.index)
        val h2 = SequencerHarness(this, backgroundScope, setOf("x", "b"))
        h2.seq.play(listOf(skip("x"), QueueItem("b", "b")), preStamped = true); h2.settle()
        h2.seq.skipPrevious(); h2.settle()
        assertEquals(1, h2.index)
    }

    @Test
    fun rowsAddedToARunningCleanOnlyRun_areStamped() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "x", "y"))
        h.seq.editionDecider = EditionDecider { item, cleanOnly ->
            if (cleanOnly && item.id.startsWith("x")) item.copy(cleanOnlySkip = true) else item
        }
        h.seq.cleanOnlyProvider = { it == "pls" }
        h.seq.play(rows("a"), sourceSetlistId = "pls"); h.settle()
        h.seq.insertNextInQueue(rows("x1")); h.seq.appendToQueue(rows("x2", "y"))
        assertEquals(listOf(false, true, true, false), h.seq.state.value.queue.map { it.cleanOnlySkip })
    }

    @Test
    fun skippedFirstRow_isHoppedOnPlay() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("x", "b"))
        h.seq.play(listOf(skip("x"), QueueItem("b", "b")), preStamped = true); h.settle()
        assertEquals(1, h.index)
        assertEquals(listOf("b"), h.port.loads.map { it.item.id })
    }

    @Test
    fun skippedRow_isNeverAPreloadTarget_theNextPlayableRowIs() {
        val q = listOf(QueueItem("a"), skip("x"), QueueItem("c"))
        val p = NextRowPreloader()
        assertEquals(2, p.target(q, 0, RepeatMode.OFF, false, 1, true)!!.index)
        assertNull(p.target(listOf(QueueItem("a"), skip("x")), 0, RepeatMode.OFF, false, 1, true))
        assertEquals(0, p.target(listOf(QueueItem("a"), skip("x")).let { listOf(it[0], it[1], QueueItem("z")) }, 2, RepeatMode.ALL, false, 1, true)!!.index)
        assertEquals(1, p.target(listOf(QueueItem("a"), QueueItem("c")), 0, RepeatMode.OFF, false, 1, true)!!.index)
    }

    @Test
    fun allSkippedLap_terminatesWithoutSpinning() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("x", "y"))
        h.seq.play(listOf(skip("x"), skip("y")), preStamped = true); h.settle()
        assertTrue(h.port.loads.isEmpty())
        assertFalse(h.seq.isRunning) // ran off the end, cleanly
        // repeat ALL must not wrap forever either
        val h2 = SequencerHarness(this, backgroundScope, setOf("x", "y"))
        h2.seq.setRepeatMode(RepeatMode.ALL)
        h2.seq.play(listOf(skip("x"), skip("y")), preStamped = true); h2.settle()
        assertTrue(h2.port.loads.isEmpty())
        assertFalse(h2.seq.isRunning)
    }

    @Test
    fun playStampsTheSkipFlagThroughTheDecider_forCleanOnlyRunsOnly() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "x"))
        h.seq.editionDecider = EditionDecider { item, cleanOnly ->
            if (cleanOnly && item.id == "x") item.copy(cleanOnlySkip = true) else item
        }
        h.seq.cleanOnlyProvider = { it == "pls" }
        h.seq.play(rows("a", "x"), sourceSetlistId = "pls"); h.settle()
        assertEquals(listOf(false, true), h.seq.state.value.queue.map { it.cleanOnlySkip })
        val h2 = SequencerHarness(this, backgroundScope, setOf("a", "x"))
        h2.seq.editionDecider = h.seq.editionDecider
        h2.seq.cleanOnlyProvider = { false }
        h2.seq.play(rows("a", "x"), sourceSetlistId = "pls"); h2.settle()
        assertEquals(listOf(false, false), h2.seq.state.value.queue.map { it.cleanOnlySkip })
    }
}

package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class JukeboxPlacementTest {
    private class Fake(override var isRunning: Boolean) : JukeboxQueue {
        val calls = mutableListOf<String>()
        var slotRange: IntRange? = null
        var startedContext: PlayContext? = null
        override fun snapshot() = SequencerState()
        override fun insertNext(item: QueueItem) { calls += "next:${item.id}" }
        override fun append(item: QueueItem) { calls += "end:${item.id}" }
        override fun insertRandom(item: QueueItem, slot: (IntRange) -> Int) {
            calls += "random:${item.id}"
            // index=2, count=6 -> tail slots 3..6
            slotRange = JukeboxPlacement.randomSlots(2, 6)
            calls += "slot:${slot(slotRange!!)}"
        }
        override fun startRun(item: QueueItem, context: PlayContext) {
            calls += "start:${item.id}"; startedContext = context
        }
    }

    private val item = QueueItem(id = "s1")

    @Test fun nextGoesThroughSequencerInsertNext() {
        val q = Fake(true)
        JukeboxPlacement.place(q, item, JukeboxDecisionAction.NEXT)
        assertEquals(listOf("next:s1"), q.calls)
    }

    @Test fun endAppends() {
        val q = Fake(true)
        JukeboxPlacement.place(q, item, JukeboxDecisionAction.END)
        assertEquals(listOf("end:s1"), q.calls)
    }

    @Test fun randomDrawsFromTailRangeViaInjectedSlotFn() {
        val q = Fake(true)
        JukeboxPlacement.place(q, item, JukeboxDecisionAction.RANDOM) { it.last }
        assertEquals(listOf("random:s1", "slot:6"), q.calls)
        assertEquals(3..6, q.slotRange)
    }

    @Test fun randomSlotsAreIndexPlusOneThroughCount() {
        assertEquals(1..5, JukeboxPlacement.randomSlots(0, 5))
        assertEquals(5..5, JukeboxPlacement.randomSlots(4, 5)) // last row playing: only the end
        assertEquals(5..5, JukeboxPlacement.randomSlots(9, 5)) // stale cursor clamps
    }

    @Test fun idleStartsOneItemRunTaggedJukebox() {
        for (action in listOf(JukeboxDecisionAction.NEXT, JukeboxDecisionAction.END, JukeboxDecisionAction.RANDOM)) {
            val q = Fake(false)
            JukeboxPlacement.place(q, item, action)
            assertEquals(listOf("start:s1"), q.calls)
            assertEquals("jukebox", q.startedContext!!.source)
        }
    }

    @Test fun deniedNeverTouchesTheQueue() {
        val q = Fake(true)
        JukeboxPlacement.place(q, item, JukeboxDecisionAction.DENIED)
        assertTrue(q.calls.isEmpty())
    }
}

package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SequencerHarness
import com.levi.pocketdj.playback.sequencer.rows
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** The production [SequencerJukeboxQueue] against the REAL sequencer. */
@OptIn(ExperimentalCoroutinesApi::class)
class SequencerJukeboxQueueTest {
    private val all = setOf("a", "b", "c", "d", "x", "y")
    private val req = QueueItem(id = "x")

    @Test fun randomDrawsFromAfterCurrentThroughEnd_andLandsAtDrawnSlot() = runTest {
        val h = SequencerHarness(this, backgroundScope, all)
        h.seq.play(rows("a", "b", "c", "d"))
        h.settle()
        h.seq.skipNext(); h.settle() // b current (index 1)
        val q = SequencerJukeboxQueue(h.seq)
        var range: IntRange? = null
        JukeboxPlacement.place(q, req, JukeboxDecisionAction.RANDOM, slot = { range = it; 3 })
        assertEquals(2..4, range)
        assertEquals(listOf("a", "b", "c", "x", "d"), h.ids)
    }

    @Test fun nextAndEndLandRightPlaces() = runTest {
        val h = SequencerHarness(this, backgroundScope, all)
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        val q = SequencerJukeboxQueue(h.seq)
        JukeboxPlacement.place(q, req, JukeboxDecisionAction.NEXT)
        JukeboxPlacement.place(q, QueueItem(id = "y"), JukeboxDecisionAction.END)
        assertEquals(listOf("a", "x", "b", "c", "y"), h.ids)
    }

    @Test fun foreignPlaybackIdleSequencer_isAdoptedAndRequestQueuesAfterIt() = runTest {
        val h = SequencerHarness(this, backgroundScope, all)
        val q = SequencerJukeboxQueue(h.seq)
        assertEquals(false, q.isRunning)
        // An album is sounding outside the sequencer.
        JukeboxPlacement.place(
            q, req, JukeboxDecisionAction.NEXT,
            foreign = ForeignPlayback(QueueItem(id = "a"), 9_000),
        )
        h.settle()
        assertEquals(listOf("a", "x"), h.ids)
        assertEquals(0, h.index)
        assertEquals("a", h.seq.state.value.current!!.id)
    }

    @Test fun trulyIdleStartsOneItemRun() = runTest {
        val h = SequencerHarness(this, backgroundScope, all)
        JukeboxPlacement.place(SequencerJukeboxQueue(h.seq), req, JukeboxDecisionAction.END)
        h.settle()
        assertEquals(listOf("x"), h.ids)
    }
}

package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RepeatShuffleTest {
    private val ids = (1..10).map { "s$it" }

    private fun kotlinx.coroutines.test.TestScope.running(): SequencerHarness {
        val h = SequencerHarness(this, backgroundScope, ids.toSet())
        h.seq.play(rows(*ids.toTypedArray()))
        h.settle()
        return h
    }

    @Test
    fun repeatMode_cycleOrder_andTokensRoundTrip() {
        assertEquals(RepeatMode.ALL, RepeatMode.OFF.next)
        assertEquals(RepeatMode.ONE, RepeatMode.ALL.next)
        assertEquals(RepeatMode.OFF, RepeatMode.ONE.next)
        RepeatMode.entries.forEach { assertEquals(it, RepeatMode.fromToken(it.token)) }
        assertEquals(RepeatMode.OFF, RepeatMode.fromToken("garbage"))
        assertEquals(RepeatMode.OFF, RepeatMode.fromToken(null))
        assertEquals(listOf("off", "all", "one"), RepeatMode.entries.map { it.token }) // persisted tokens
    }

    @Test
    fun setRepeatMode_persistsOnChangeOnly_andWorksWhileIdle() = runTest {
        val h = SequencerHarness(this, backgroundScope, ids.toSet())
        val saved = mutableListOf<RepeatMode>()
        h.seq.onRepeatModeChanged = { saved += it }
        h.seq.setRepeatMode(RepeatMode.OFF) // unchanged
        h.seq.cycleRepeatMode()
        h.seq.setRepeatMode(RepeatMode.ALL) // unchanged
        h.seq.cycleRepeatMode()
        assertEquals(listOf(RepeatMode.ALL, RepeatMode.ONE), saved)
        assertEquals(RepeatMode.ONE, h.seq.state.value.repeatMode)
    }

    @Test
    fun shuffleOn_permutesTailOnly_sameMembers() = runTest {
        val h = running()
        h.seq.skipNext(); h.settle() // current s2
        val head = h.ids.take(2)
        h.seq.setShuffle(true)
        assertEquals(head, h.ids.take(2))
        assertEquals(ids.toSet(), h.ids.toSet())
        assertEquals(ids.size, h.ids.size)
        assertNotEquals(ids.drop(2), h.ids.drop(2))
        assertTrue(h.seq.state.value.shuffleEnabled)
    }

    @Test
    fun shuffleOff_restoresPreShuffleRelativeOrder_laterAddedRowsAtEnd() = runTest {
        val h = running()
        h.seq.setShuffle(true)
        h.seq.appendToQueue(rows("x")) // added AFTER the shuffle
        h.seq.insertNextInQueue(rows("y"))
        h.seq.setShuffle(false)
        // Pre-shuffle order of the originals, then the later-added rows (unknown to canonicalOrder)
        // at the end in their current queue order (stable sort: y was inserted ahead of x).
        val tail = h.ids.drop(1)
        assertEquals(ids.drop(1) + listOf("y", "x"), tail)
        assertFalse(h.seq.state.value.shuffleEnabled)
    }

    @Test
    fun shuffle_remembersCanonicalOrderOnce_acrossToggles() = runTest {
        val h = running()
        h.seq.setShuffle(true)
        h.seq.setShuffle(false)
        h.seq.setShuffle(true)
        h.seq.setShuffle(false)
        assertEquals(ids, h.ids)
    }

    @Test
    fun shuffleWhileIdle_isRecordedButPermutesNothing() = runTest {
        val h = SequencerHarness(this, backgroundScope, ids.toSet())
        h.seq.setShuffle(true)
        assertTrue(h.seq.state.value.shuffleEnabled)
        assertTrue(h.ids.isEmpty())
    }

    @Test
    fun shuffle_isPerRun_repeatIsSticky() = runTest {
        val h = running()
        h.seq.setShuffle(true)
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("s1", "s2"))
        h.settle()
        assertFalse(h.seq.state.value.shuffleEnabled)
        assertEquals(RepeatMode.ONE, h.seq.state.value.repeatMode)
    }

    @Test
    fun shuffleOn_lastTrackPlaying_isHarmless() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a"))
        h.seq.play(rows("a"))
        h.settle()
        h.seq.setShuffle(true)
        h.seq.setShuffle(false)
        assertEquals(listOf("a"), h.ids)
    }

    @Test
    fun skipNext_withRepeatOne_stillAdvances_onlyNaturalEndReplays() = runTest {
        val h = running()
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.skipNext(); h.settle()
        assertEquals(1, h.index)
    }
}

package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** P2-MM-10: the rule-A hook in the sequencer (start, natural-advance preload, per-play lifetime). */
@OptIn(ExperimentalCoroutinesApi::class)
class EditionSubstitutionSequencerTest {
    private fun kotlinx.coroutines.test.TestScope.harness(): SequencerHarness {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "b", "b-base"))
        h.seq.preloadEnabled = true
        return h
    }

    @Test
    fun preloadedRow_isSubstituted_beforeItAdvances() = runTest {
        val h = harness()
        h.seq.editionSubstituter = { item, _ -> if (item.id == "b") "b-base" else null }
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.onFirstAudio("a"); h.settle()
        assertEquals("b", h.port.preloadedId)
        assertEquals("b-base", h.seq.state.value.queue[1].resolveId)
    }

    @Test
    fun freshReentry_restoresAndReevaluates() = runTest {
        val h = harness()
        var muted = true
        h.seq.editionSubstituter = { item, _ -> if (muted && item.id == "b") "b-base" else null }
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.onFirstAudio("a"); h.settle()
        assertEquals("b-base", h.seq.state.value.queue[1].resolveId)
        muted = false
        h.seq.jumpToUpcoming(h.seq.state.value.queue[1].uid); h.settle()
        assertEquals("b", h.seq.state.value.queue[1].resolveId)
    }
}

package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.session.SetlistSequencerControl
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class EffectiveRepeatTest {
    private fun TestScope.harness() = SequencerHarness(this, backgroundScope, setOf("a", "b", "c"))

    @Test
    fun forcedOff_reportsOffEverywhere_whileStickyModeIsKept() = runTest {
        val h = harness()
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b", "c"), "pwr_run1"); h.settle()
        val st = h.seq.state.value
        assertTrue(st.repeatForcedOff)
        assertEquals(RepeatMode.OFF, st.effectiveRepeatMode)
        assertEquals(RepeatMode.OFF, h.seq.effectiveRepeatMode)
        assertEquals("the sticky mode is untouched", RepeatMode.ALL, st.repeatMode)
        // the media-session / widget / Auto funnel reads the effective mode
        assertEquals(RepeatMode.OFF, SetlistSequencerControl(h.seq).repeatMode)
    }

    @Test
    fun setRepeatMode_isInertWhileForcedOff_andNeverWritesTheStickyMode() = runTest {
        val h = harness()
        val persisted = mutableListOf<RepeatMode>()
        h.seq.onRepeatModeChanged = { persisted += it }
        h.seq.play(rows("a", "b", "c"), "pwr_run1"); h.settle()
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.cycleRepeatMode()
        SetlistSequencerControl(h.seq).repeatMode = RepeatMode.ALL
        assertEquals(RepeatMode.OFF, h.seq.state.value.repeatMode)
        assertEquals(RepeatMode.OFF, h.seq.effectiveRepeatMode)
        assertTrue("nothing persisted", persisted.isEmpty())
    }

    @Test
    fun stickyModeIsRestoredAfterTheRun() = runTest {
        val h = harness()
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b"), "pwr_run1"); h.settle()
        assertEquals(RepeatMode.OFF, h.seq.effectiveRepeatMode)
        h.seq.stop(); h.settle()
        assertFalse(h.seq.state.value.repeatForcedOff)
        h.seq.play(rows("a", "b"), "set_1"); h.settle()
        assertEquals(RepeatMode.ALL, h.seq.effectiveRepeatMode)
        assertEquals(RepeatMode.ALL, h.seq.state.value.effectiveRepeatMode)
        // and it is changeable again
        h.seq.setRepeatMode(RepeatMode.ONE)
        assertEquals(RepeatMode.ONE, h.seq.effectiveRepeatMode)
    }

    @Test
    fun playbackObeysTheEffectiveMode_aLapEndsTheRun_andRepeatOneDoesNotReplay() = runTest {
        val h = harness()
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b"), "pwr_run1"); h.settle()
        h.seq.handleEnded("a"); h.settle()
        h.seq.handleEnded("b"); h.settle()
        assertFalse("repeat ALL must not wrap a pocket run", h.seq.isRunning)
        assertEquals(listOf("a", "b"), h.port.loadedIds)

        val h1 = harness()
        h1.seq.setRepeatMode(RepeatMode.ONE)
        h1.seq.play(rows("a", "b"), "pwr_run1"); h1.settle()
        h1.seq.handleEnded("a"); h1.settle()
        assertEquals("repeat ONE does not replay a run row", listOf("a", "b"), h1.port.loadedIds)

        val h2 = harness() // control: an ordinary set DOES wrap
        h2.seq.setRepeatMode(RepeatMode.ALL)
        h2.seq.play(rows("a", "b"), "set_1"); h2.settle()
        h2.seq.handleEnded("a"); h2.settle()
        h2.seq.handleEnded("b"); h2.settle()
        assertTrue(h2.seq.isRunning)
        assertEquals(0, h2.index)
    }

    @Test
    fun skipPreviousAtTheTopDoesNotWrapWhileForcedOff() = runTest {
        val h = harness()
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b", "c"), "pwr_run1"); h.settle()
        h.seq.skipPrevious(); h.settle()
        assertEquals(0, h.index)
    }

    @Test
    fun restoreKeepsPwrSourceIds_onlyThePuzzleGhostIsStripped() = runTest {
        val h = harness()
        h.seq.restoreHeld(
            rows("a", "b"), 0, "pwr_run9", PlayContext("setlist", contextId = "pwr_run9"), null,
            RepeatMode.ALL, false, null,
        )
        assertEquals("pwr_ ids survive a restore", "pwr_run9", h.seq.state.value.sourceSetlistId)
        assertTrue(h.seq.state.value.repeatForcedOff)
        assertEquals(RepeatMode.ALL, h.seq.state.value.repeatMode)
        h.seq.stop()

        val g = harness()
        g.seq.restoreHeld(
            rows("a", "b"), 0, "puzzle_x", PlayContext("setlist", contextId = "puzzle_x"), null,
            RepeatMode.OFF, false, null,
        )
        assertNull("the puzzle_ ghost rule is the only one", g.seq.state.value.sourceSetlistId)
    }

    @Test
    fun customForcedOffPredicate_isHonoured() = runTest {
        val h = harness()
        h.seq.repeatForcedOff = { it == "special" }
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("a", "b"), "special"); h.settle()
        assertEquals(RepeatMode.OFF, h.seq.effectiveRepeatMode)
        h.seq.stop(); h.settle()
        h.seq.play(rows("a", "b"), "pwr_x"); h.settle()
        assertEquals("the default pwr_ rule is replaced by the binding", RepeatMode.ONE, h.seq.effectiveRepeatMode)
    }
}

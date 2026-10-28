package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ReviewFixesTest {
    private fun kotlinx.coroutines.test.TestScope.harness(vararg playable: String) =
        SequencerHarness(this, backgroundScope, playable.toSet())

    // ---- MAJOR 1: a replay is NOT a new load (a new load = a second History row) -----------------

    @Test
    fun repeatOne_replaysInPlace_neverReloads() = runTest {
        val h = harness("a", "b")
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("a", "b"))
        h.settle()
        repeat(3) { h.seq.handleEnded("a"); h.settle() }
        assertEquals(listOf("a"), h.port.loadedIds)
        assertEquals(listOf("a", "a", "a"), h.port.replays)
        assertEquals(0, h.index)
    }

    @Test
    fun repeatCount_passesReplayInPlace_thenAdvanceLoadsNextOnce() = runTest {
        val h = harness("a", "b")
        h.seq.play(listOf(QueueItem("a", repeatCount = 3), QueueItem("b")))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "a"), h.port.replays)
        assertEquals(listOf("a"), h.port.loadedIds)
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertEquals(1, h.index)
    }

    @Test
    fun consecutiveDuplicateRow_replaysInPlace() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "a", "b"))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(1, h.index)
        assertEquals(listOf("a"), h.port.loadedIds)
        assertEquals(listOf("a"), h.port.replays)
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
    }

    @Test
    fun replayThatCannotRestart_fallsBackToALoad() = runTest {
        val h = harness("a")
        h.port.replayWorks = false
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("a"))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "a"), h.port.loadedIds)
    }

    // ---- MAJOR 2: a foreign play retires the pending start --------------------------------------

    @Test
    fun foreignPlay_retiresPendingStart_soItNeverLoadsOverThePick() = runTest {
        val h = harness("a", "b")
        h.port.gates["b"] = CompletableDeferred()
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleEnded("a"); h.settle() // b is presigning
        h.seq.retirePendingStart() // the user tapped something else in Browse
        h.port.gates["b"]!!.complete(Unit)
        h.settle()
        assertEquals(listOf("a"), h.port.sounded)
        assertEquals(1, h.index) // run kept, cursor untouched
    }

    @Test
    fun adoptingTheCurrentRow_retiresItsPendingLoad() = runTest {
        val h = harness("a", "b")
        h.port.gates["a"] = CompletableDeferred()
        h.seq.play(rows("a", "b"))
        h.settle()
        assertTrue(h.seq.adoptCursor("a"))
        h.port.gates["a"]!!.complete(Unit)
        h.settle()
        assertTrue(h.port.sounded.isEmpty())
    }

    // ---- MINOR 3: a dead set tells the user (cloud mode) -------------------------------------------

    @Test
    fun cloudRun_thatStartsNothing_raisesNotice() = runTest {
        val h = harness("none")
        h.seq.play(rows("a", "b"), "set_7")
        h.settle()
        val s = h.seq.state.value
        assertFalse(s.isRunning)
        assertNotNull(s.playbackNotice)
        assertEquals("set_7", s.deviceUnplayableSourceId)
        assertFalse(s.deviceQueueUnplayable) // device-only banner flag
    }

    // ---- MINOR 4: failures count toward the lap guard ---------------------------------------------

    @Test
    fun repeatAll_everyLoadFailing_stopsAfterOneLap() = runTest {
        val h = harness("a", "b", "c")
        h.port.failing += setOf("a", "b", "c")
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        assertFalse(h.seq.isRunning)
        assertEquals(3, h.port.loads.size)
        assertNotNull(h.seq.state.value.playbackNotice)
    }

    @Test
    fun repeatAll_midSongFailuresEveryRow_stopsAfterOneLap() = runTest {
        val h = harness("a", "b")
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleFailed("a"); h.settle()
        h.seq.handleFailed("b"); h.settle()
        assertFalse(h.seq.isRunning)
    }

    @Test
    fun repeatAll_aRowThatPlaysThrough_resetsTheLap() = runTest {
        val h = harness("a", "b")
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleFailed("a"); h.settle()
        h.seq.handleEnded("b"); h.settle() // wraps to a
        h.seq.handleFailed("a"); h.settle()
        assertTrue(h.seq.isRunning)
    }

    // ---- NIT: restoreHeld keeps the persisted canonical order --------------------------------------

    @Test
    fun restoreHeld_shuffleOff_restoresPersistedCanonicalOrder() = runTest {
        val h = harness("a", "b", "c")
        val orig = rows("a", "b", "c")
        val shuffled = listOf(orig[0], orig[2], orig[1])
        h.seq.restoreHeld(shuffled, 0, null, null, null, RepeatMode.OFF, true, null, canonicalOrder = orig.map { it.uid })
        h.seq.setShuffle(false)
        assertEquals(listOf("a", "b", "c"), h.ids)
    }

    // ---- PB-6: cascade halt is a real sequencer signal (not inferred from player nullity) ---------

    @Test
    fun cascadeHaltOnAutoAdvance_setsPausedByCascade_andStartCurrentClearsIt() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b"))
        h.settle()
        assertFalse(h.seq.state.value.pausedByCascade)
        h.seq.autoAdvanceGate = { false }
        h.seq.handleEnded("a"); h.settle()
        // Halted: still on row 0 (a row HAS sounded, so currentNeverSounded alone would miss this).
        assertEquals(0, h.index)
        assertTrue(h.seq.state.value.pausedByCascade)
        assertFalse(h.seq.currentNeverSounded)
        h.seq.autoAdvanceGate = { true }
        h.seq.startCurrent(); h.settle()
        assertFalse(h.seq.state.value.pausedByCascade)
    }
}

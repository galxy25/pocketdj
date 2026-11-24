package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.TransitionCause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InMemoryRemoteTargetTest {
    private var clock = 1_000_000.0
    private fun target() = InMemoryRemoteTarget { clock }
    private fun items(vararg ids: String) = ids.map { QueueItem(id = it, title = it) }

    @Test
    fun position_advancesOnTheClockOnlyWhilePlaying() {
        val t = target()
        t.play(items("a", "b"), 0, atMs = 2_000, startPaused = false)
        clock += 500
        assertEquals(2_500L, t.positionMs)
        t.setPlaying(false)
        clock += 10_000
        assertEquals(2_500L, t.positionMs)
        t.setPlaying(true)
        clock += 100
        assertEquals(2_600L, t.positionMs)
    }

    @Test
    fun remoteMutations_areTaggedRemote_userActionsAreUser() {
        val t = target()
        val l = items("a", "b", "c")
        t.play(l, 0, 0, false)
        assertEquals(TransitionCause.REMOTE, t.lastTransitionCause)
        t.userSkipNext()
        assertEquals(TransitionCause.USER, t.lastUserTransitionSeq.let { t.lastTransitionCause })
        assertEquals(t.transitionSeq, t.lastUserTransitionSeq)
        t.jumpToUpcoming(l[2].uid, 3_000)
        assertEquals(TransitionCause.REMOTE, t.lastTransitionCause)
        assertEquals(3_000L, t.positionMs)
        assertEquals(listOf("play", "jump@3000"), t.log)
    }

    @Test
    fun autoAdvance_pastTheLastRow_stopsTheSet() {
        val t = target()
        t.play(items("a", "b"), 0, 0, false)
        t.simulateAutoAdvance(TransitionCause.NATURAL_END)
        assertEquals(1, t.currentIndex)
        t.simulateAutoAdvance(TransitionCause.NATURAL_END)
        assertFalse(t.isRunning)
        assertEquals(0, t.queueCount)
    }

    @Test
    fun systemPause_isNotUserIntent_andOnlyAPlayClearsIt() {
        val t = target()
        t.play(items("a", "b"), 0, 0, false)
        t.simulateSystemPause()
        assertTrue(t.isSystemPaused)
        assertFalse(t.isPlaying)
        assertEquals(0L, t.userPlayIntentSeq)
        t.setPlaying(true)
        assertFalse(t.isSystemPaused)
    }

    @Test
    fun pendingStart_racesAPlainPause_butSilenceWins() {
        val t = target()
        t.play(items("a"), 0, 0, true)
        t.beginPendingStart()
        assertTrue(t.isTransitioning)
        t.silenceForController()
        t.settlePendingStart()
        assertFalse("silence cancelled the start that would have sounded", t.isPlaying)
        t.beginPendingStart(); t.settlePendingStart()
        assertTrue(t.isPlaying)
    }

    @Test
    fun replaceInsertAppend_bumpGeneration() {
        val t = target()
        val l = items("a", "b", "c", "d")
        t.play(l, 0, 0, false)
        val g = t.queueGeneration
        t.replaceUpcoming(1, items("x")); t.insertUpcoming(items("y"), l[3].uid); t.appendToQueue(items("z"))
        assertEquals(listOf("a", "x", "c", "y", "d", "z"), (0 until t.queueCount).map { t.item(it).id })
        assertEquals(g + 3, t.queueGeneration)
    }
}

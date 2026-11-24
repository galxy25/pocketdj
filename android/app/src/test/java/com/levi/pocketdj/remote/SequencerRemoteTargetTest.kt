package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.health.EngineProbe
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.SequencerHarness
import com.levi.pocketdj.playback.sequencer.TransitionCause
import com.levi.pocketdj.playback.sequencer.TransportRedirect
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SequencerRemoteTargetTest {
    private fun items(vararg ids: String) = ids.map { QueueItem(id = it, title = it) }

    private fun TestScope.harness() = SequencerHarness(this, backgroundScope, setOf("a", "b", "c", "d", "e", "x", "y"))

    private class Engine : EngineProbe {
        var playing = false
        var pos = 0L
        override val hasLoadedItem = true
        override val isPlaying get() = playing
        override val positionMs get() = pos
        override val trackEnded = false
        override fun rekick(by: String) {}
    }

    private fun TestScope.target(h: SequencerHarness, sys: () -> Boolean = { false }, coarse: () -> Boolean = { false }) =
        SequencerRemoteTarget(h.seq, backgroundScope, systemPaused = sys, coarsePosition = coarse)

    @Test
    fun play_startsRunOnIndex_taggedRemote_notListenerIntent() = runTest {
        val h = harness(); val t = target(h)
        val intent0 = t.userPlayIntentSeq
        t.play(items("a", "b", "c"), startIndex = 1, atMs = 0, startPaused = false); h.settle()
        assertTrue(t.isRunning)
        assertEquals(1, t.currentIndex)
        assertEquals(3, t.queueCount)
        assertEquals("b", t.currentItem?.id)
        assertEquals(TransitionCause.REMOTE, t.lastTransitionCause)
        assertEquals("a remote start is not listener play intent", intent0, t.userPlayIntentSeq)
    }

    @Test
    fun play_startIndexIsClamped_andEmptyIsNoOp() = runTest {
        val h = harness(); val t = target(h)
        t.play(emptyList(), 0, 0, false); h.settle()
        assertFalse(t.isRunning)
        t.play(items("a", "b"), startIndex = 9, atMs = 0, startPaused = false); h.settle()
        assertEquals(1, t.currentIndex)
    }

    @Test
    fun playStartPaused_holdsAtCue_andPositionReadsTheCue() = runTest {
        val h = harness(); val t = target(h)
        t.play(items("a", "b"), 0, atMs = 5_000, startPaused = true); h.settle()
        assertTrue(t.isRunning)
        assertFalse(t.isPlaying)
        assertEquals(5_000L, t.positionMs)
        assertTrue(h.seq.isHeldByRemote)
    }

    @Test
    fun cueAtOrBelowOneSecond_isFromTheTop() = runTest {
        val h = harness(); val t = target(h)
        t.play(items("a"), 0, atMs = 1_000, startPaused = true); h.settle()
        assertEquals(0L, t.positionMs)
    }

    @Test
    fun jumpToUpcoming_byUid_movesCurrent_taggedRemote() = runTest {
        val h = harness(); val t = target(h)
        val list = items("a", "b", "c")
        t.play(list, 0, 0, false); h.settle()
        val seq0 = t.transitionSeq
        t.jumpToUpcoming(list[2].uid, atMs = 0); h.settle()
        assertEquals("c", t.currentItem?.id)
        assertTrue(t.transitionSeq > seq0)
        assertEquals(TransitionCause.REMOTE, t.lastTransitionCause)
        assertEquals("a remote jump is never a user transition", 0L, t.lastUserTransitionSeq)
    }

    @Test
    fun jumpToUpcoming_unknownOrPastUid_isIgnored() = runTest {
        val h = harness(); val t = target(h)
        val list = items("a", "b", "c")
        t.play(list, 1, 0, false); h.settle()
        t.jumpToUpcoming(list[0].uid, 0); t.jumpToUpcoming("nope", 0); h.settle()
        assertEquals("b", t.currentItem?.id)
    }

    @Test
    fun replaceUpcoming_swapsOnlyTheFirstNUpcoming_andBumpsGeneration() = runTest {
        val h = harness(); val t = target(h)
        t.play(items("a", "b", "c", "d"), 0, 0, false); h.settle()
        val gen = t.queueGeneration
        t.replaceUpcoming(2, items("x", "y")); h.settle()
        assertEquals(listOf("a", "x", "y", "d"), (0 until t.queueCount).map { t.item(it).id })
        assertTrue(t.queueGeneration > gen)
        assertEquals(0, t.currentIndex)
    }

    @Test
    fun insertAndAppend_landWhereAsked() = runTest {
        val h = harness(); val t = target(h)
        val list = items("a", "b", "c")
        t.play(list, 0, 0, false); h.settle()
        t.insertUpcoming(items("x"), beforeUid = list[2].uid); h.settle()
        t.appendToQueue(items("y")); h.settle()
        t.insertUpcoming(emptyList(), null); t.appendToQueue(emptyList())
        assertEquals(listOf("a", "b", "x", "c", "y"), (0 until t.queueCount).map { t.item(it).id })
    }

    @Test
    fun upcomingItems_isCapped_andEmptyWhenIdle() = runTest {
        val h = harness(); val t = target(h)
        assertTrue(t.upcomingItems(5).isEmpty())
        assertNull(t.currentItem)
        t.play(items("a", "b", "c", "d", "e"), 1, 0, false); h.settle()
        assertEquals(listOf("c", "d"), t.upcomingItems(2).map { it.id })
        assertEquals(listOf("c", "d", "e"), t.upcomingItems(10).map { it.id })
    }

    @Test
    fun setPlaying_onAHeldDeck_resumesWithoutListenerIntent_andOffIsANoOp() = runTest {
        val h = harness(); val t = target(h)
        t.play(items("a", "b"), 0, atMs = 4_000, startPaused = true); h.settle()
        val intent0 = t.userPlayIntentSeq
        t.setPlaying(false); h.settle()
        assertTrue("still held", h.seq.isHeldForResume)
        t.setPlaying(true); h.settle()
        assertFalse(h.seq.isHeldForResume)
        assertEquals(intent0, t.userPlayIntentSeq)
    }

    @Test
    fun setPlaying_pauseAndResume_routeThroughThePort() = runTest {
        val h = harness(); val t = target(h)
        val engine = Engine().also { h.seq.engine = it }
        t.play(items("a", "b"), 0, 0, false); h.settle()
        engine.playing = true
        assertTrue(t.isPlaying)
        val intent0 = t.userPlayIntentSeq
        t.setPlaying(true) // already playing: no-op
        t.setPlaying(false); h.settle()
        assertEquals(1, h.port.pauses)
        engine.playing = false
        t.setPlaying(true); h.settle()
        assertEquals(1, h.port.resumes)
        assertEquals("transport applied remotely is never the listener's", intent0, t.userPlayIntentSeq)
    }

    @Test
    fun setPlaying_goesPastTheControllerGate() = runTest {
        val h = harness(); val t = target(h)
        val engine = Engine().also { h.seq.engine = it }
        t.play(items("a", "b"), 0, 0, false); h.settle()
        engine.playing = true
        val redirects = mutableListOf<TransportRedirect>()
        h.seq.transportGate = { redirects += it; true }
        t.setPlaying(false); h.settle()
        assertTrue("an external apply bypasses the gate", redirects.isEmpty())
        assertEquals(1, h.port.pauses)
        // while a plain listener transport would have been redirected
        h.seq.skipNext(); h.settle()
        assertEquals(1, redirects.size)
    }

    @Test
    fun seek_onAHeldDeck_movesTheResumePoint_elseSeeksThePort() = runTest {
        val h = harness(); val t = target(h)
        t.play(items("a", "b"), 0, atMs = 4_000, startPaused = true); h.settle()
        t.seek(9_000); h.settle()
        assertEquals(9_000L, t.positionMs)
        t.setPlaying(true); h.settle()
        val engine = Engine().also { h.seq.engine = it }
        val transports = mutableListOf<com.levi.pocketdj.playback.sequencer.UserTransport>()
        h.seq.hooks.add(object : com.levi.pocketdj.playback.sequencer.SequencerListener {
            override fun onUserTransport(kind: com.levi.pocketdj.playback.sequencer.UserTransport) { transports += kind }
        })
        t.seek(7_000); h.settle()
        assertTrue("a remote seek is not a listener transport", transports.isEmpty())
        engine.pos = 7_000
        assertEquals(7_000L, t.positionMs)
    }

    @Test
    fun repeatAndShuffle_roundTrip() = runTest {
        val h = harness(); val t = target(h)
        t.play(items("a", "b", "c"), 0, 0, false); h.settle()
        t.setRepeatMode(RepeatMode.ALL); t.setShuffle(true); h.settle()
        assertEquals(RepeatMode.ALL, t.repeatMode)
        assertTrue(t.shuffleEnabled)
        t.setShuffle(false); h.settle()
        assertFalse(t.shuffleEnabled)
    }

    @Test
    fun silenceForController_parksDeckHeld_andRunsExtraSilencers() = runTest {
        val h = harness()
        var silenced = 0
        val t = SequencerRemoteTarget(h.seq, backgroundScope, extraSilencers = { listOf({ silenced++ }, { error("boom") }) })
        t.play(items("a", "b"), 0, 0, false); h.settle()
        t.silenceForController(); h.settle()
        assertTrue(h.seq.isHeldForResume)
        assertFalse(t.isPlaying)
        assertEquals(1, silenced)
        t.silenceForController(); h.settle() // idempotent, a throwing silencer never breaks the others
        assertEquals(2, silenced)
        assertTrue(h.seq.isHeldForResume)
    }

    @Test
    fun platformSeams_systemPausedAndCoarsePosition_areReadThrough() = runTest {
        val h = harness()
        var sys = false; var coarse = false
        val t = target(h, { sys }, { coarse })
        assertFalse(t.isSystemPaused); assertFalse(t.hasCoarsePosition)
        sys = true; coarse = true
        assertTrue(t.isSystemPaused); assertTrue(t.hasCoarsePosition)
    }

    @Test
    fun transitionCause_followsUserSkipsAndAutoAdvances() = runTest {
        val h = harness(); val t = target(h)
        t.play(items("a", "b", "c"), 0, 0, false); h.settle()
        h.seq.skipNext(); h.settle()
        assertEquals(TransitionCause.USER, t.lastTransitionCause)
        assertEquals(t.transitionSeq, t.lastUserTransitionSeq)
        t.jumpToUpcoming(t.item(2).uid, 0); h.settle()
        assertEquals(TransitionCause.REMOTE, t.lastTransitionCause)
        assertTrue(t.transitionSeq > t.lastUserTransitionSeq)
    }

    @Test
    fun close_unhooksTheListener() = runTest {
        val h = harness()
        val before = h.seq.hooks.count
        val t = SequencerRemoteTarget(h.seq, backgroundScope)
        assertEquals(before + 1, h.seq.hooks.count)
        t.close()
        assertEquals(before, h.seq.hooks.count)
    }

    @Test
    fun listenerPlayIntent_isVisibleThroughTheTarget() = runTest {
        val h = harness(); val t = target(h)
        h.seq.noteListenerPlayIntent(true)
        h.seq.noteListenerPlayIntent(false)
        assertEquals(2L, t.userPlayIntentSeq)
        assertFalse(t.lastUserPlayIntent)
    }
}

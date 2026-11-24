package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.health.EngineProbe
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ExternalDriverApiTest {
    private fun TestScope.harness() = SequencerHarness(this, backgroundScope, setOf("a", "b", "c", "d", "x", "y"))

    private class Engine : EngineProbe {
        var playing = false
        var pos = 0L
        override val hasLoadedItem = true
        override val isPlaying get() = playing
        override val positionMs get() = pos
        override val trackEnded = false
        override fun rekick(by: String) {}
    }

    private class Transitions : SequencerListener {
        val causes = mutableListOf<TransitionCause>()
        val tracks = mutableListOf<TrackStart>()
        val transports = mutableListOf<UserTransport>()
        var held = 0
        override fun onTransition(t: Transition) { causes += t.cause }
        override fun onTrackStarted(start: TrackStart) { tracks += start }
        override fun onUserTransport(kind: UserTransport) { transports += kind }
        override fun onHeld() { held++ }
    }

    // ---- applyingExternal ----------------------------------------------------------------------

    @Test
    fun applyingExternal_tagsTransitionsRemote_andIsNotListenerIntent() = runTest {
        val h = harness()
        val l = Transitions().also { h.seq.hooks.add(it) }
        h.seq.play(rows("a", "b", "c"), "set_1"); h.settle()
        val seq0 = h.seq.userPlayIntentSeq
        assertEquals("a listener play is intent", true, h.seq.lastUserPlayIntent)
        l.causes.clear(); l.transports.clear()

        h.seq.applyingExternal { h.seq.skipNext() }; h.settle()
        assertEquals(listOf(TransitionCause.REMOTE), l.causes)
        assertTrue("no listener transport reported inside an external apply", l.transports.isEmpty())
        assertEquals("▶/⏸ inside it is not the listener's", seq0, h.seq.userPlayIntentSeq)

        h.seq.skipNext(); h.settle()
        assertEquals(TransitionCause.USER, l.causes.last())
        assertEquals(listOf(UserTransport.SKIP), l.transports)
    }

    @Test
    fun noteListenerPlayIntent_countsOnlyTheListener() = runTest {
        val h = harness()
        assertEquals(0L, h.seq.userPlayIntentSeq)
        h.seq.noteListenerPlayIntent(true)
        h.seq.noteListenerPlayIntent(false)
        assertEquals(2L, h.seq.userPlayIntentSeq)
        assertFalse(h.seq.lastUserPlayIntent)
        h.seq.applyingExternal { h.seq.noteListenerPlayIntent(true) }
        assertEquals(2L, h.seq.userPlayIntentSeq)
        assertFalse(h.seq.lastUserPlayIntent)
        h.seq.pause()
        assertEquals("a listener pause is recorded", 3L, h.seq.userPlayIntentSeq)
    }

    // ---- play(items, startIndex, atMs, startPaused) ----------------------------------------------

    @Test
    fun play_atMs_carriesTheCueWithTheStart_andIsAFreshTrackStart() = runTest {
        val h = harness()
        val l = Transitions().also { h.seq.hooks.add(it) }
        h.seq.applyingExternal { h.seq.play(rows("a", "b", "c"), "set_1", startIndex = 1, atMs = 42_000) }
        h.settle()
        assertEquals(1, h.index)
        assertEquals(42_000L, h.port.loads.single().resumeAtMs)
        assertTrue("a cued start is a NEW track start, not a mid-song resume", l.tracks.single().fresh)
        assertEquals(TransitionCause.REMOTE, l.causes.last())
    }

    @Test
    fun play_startPaused_parksHeldAtTheCue_andFirstPlayStartsThere() = runTest {
        val h = harness()
        val l = Transitions().also { h.seq.hooks.add(it) }
        h.seq.applyingExternal { h.seq.play(rows("a", "b"), "set_1", startIndex = 0, atMs = 45_000, startPaused = true) }
        h.settle()
        assertTrue(h.port.loads.isEmpty())
        assertTrue(h.seq.isHeldForResume)
        assertTrue(h.seq.isHeldByRemote)
        assertEquals(45_000L, h.seq.resumeOffsetMs)
        assertEquals(1, l.held)
        assertTrue(h.seq.state.value.isRunning)

        h.seq.resumeFromHold(); h.settle()
        assertEquals(45_000L, h.port.loads.single().resumeAtMs)
        assertTrue(l.tracks.single().fresh)
        assertFalse(h.seq.isHeldForResume)
        assertFalse(h.seq.isHeldByRemote)
    }

    @Test
    fun play_startPaused_silencesWhateverWasSounding() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b"), "set_1"); h.settle()
        val pauses = h.port.pauses
        h.seq.applyingExternal { h.seq.play(rows("c", "d"), "set_2", startPaused = true) }
        h.settle()
        assertTrue("the old audio was paused", h.port.pauses > pauses)
        assertEquals("nothing new loaded", listOf("a"), h.port.loadedIds)
        assertNull(h.seq.resumeOffsetMs)
    }

    // ---- jumpToUpcoming(uid, atMs) ---------------------------------------------------------------

    @Test
    fun jumpToUpcoming_carriesTheStartCue_noSeekAfterTheJump() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c"), "set_1"); h.settle()
        val c = h.seq.state.value.queue[2].uid
        h.seq.applyingExternal { h.seq.jumpToUpcoming(c, atMs = 61_000) }
        h.settle()
        assertEquals(2, h.index)
        val req = h.port.loads.last()
        assertEquals("c", req.item.id)
        assertEquals("the cue rides the load itself", 61_000L, req.resumeAtMs)
        assertEquals("exactly one load per jump, never a load then a seek", listOf("a", "c"), h.port.loadedIds)
    }

    @Test
    fun jumpToUpcoming_withoutCue_isUnchanged() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c"), "set_1"); h.settle()
        h.seq.jumpToUpcoming(h.seq.state.value.queue[1].uid); h.settle()
        assertNull(h.port.loads.last().resumeAtMs)
    }

    // ---- transportGate -----------------------------------------------------------------------------

    @Test
    fun gate_routesEveryTransportEntry_andLocalAudioIsUntouched() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c"), "set_1"); h.settle()
        val b = h.seq.state.value.queue[1]
        val seen = mutableListOf<TransportRedirect>()
        h.seq.transportGate = { seen += it; true }
        val loads = h.port.loads.size
        val pauses = h.port.pauses

        h.seq.skipNext()
        h.seq.skipPrevious()
        h.seq.jumpToUpcoming(b.uid)
        h.seq.playNow(QueueItem("x", "x"))
        h.seq.play(rows("y"), "set_2")
        h.seq.startCurrent()
        h.seq.pause()
        h.seq.resume()
        h.settle()

        assertEquals(TransportRedirect.SkipNext, seen[0])
        assertEquals(TransportRedirect.SkipPrevious, seen[1])
        assertEquals(TransportRedirect.Jump(b.uid), seen[2])
        assertTrue(seen[3] is TransportRedirect.PlayNow)
        assertEquals(TransportRedirect.Play(rows("y").map { it.copy(uid = (seen[4] as TransportRedirect.Play).items[0].uid) }, 0), seen[4])
        assertEquals(TransportRedirect.LocalStart, seen[5])
        assertEquals(TransportRedirect.SetPlaying(false), seen[6])
        assertEquals(TransportRedirect.SetPlaying(true), seen[7])
        assertEquals("nothing moved here", 0, h.index)
        assertEquals(listOf("a", "b", "c"), h.ids)
        assertEquals(loads, h.port.loads.size)
        assertEquals(pauses, h.port.pauses)
        assertEquals("set_1", h.seq.state.value.sourceSetlistId)
    }

    @Test
    fun gate_resumeFromHold_isASetPlayingRedirect() = runTest {
        val h = harness()
        h.seq.restoreHeld(rows("a", "b"), 0, "set_1", null, null, RepeatMode.OFF, false, 5_000)
        val seen = mutableListOf<TransportRedirect>()
        h.seq.transportGate = { seen += it; true }
        h.seq.resumeFromHold(); h.settle()
        assertEquals(listOf<TransportRedirect>(TransportRedirect.SetPlaying(true)), seen)
        assertTrue(h.seq.isHeldForResume)
        assertTrue(h.port.loads.isEmpty())
    }

    @Test
    fun gate_isBypassedInsideApplyingExternal_andPassesWhenItReturnsFalse() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c"), "set_1"); h.settle()
        h.seq.transportGate = { true }
        h.seq.applyingExternal { h.seq.skipNext() }; h.settle()
        assertEquals("the session's own apply is never redirected back", 1, h.index)
        h.seq.skipNext(); h.settle()
        assertEquals("a listener skip is redirected", 1, h.index)

        h.seq.transportGate = { false }
        h.seq.skipNext(); h.settle()
        assertEquals("a gate that returns false changes nothing", 2, h.index)
        h.seq.transportGate = null
        h.seq.skipPrevious(); h.settle()
        assertEquals(1, h.index)
    }

    // ---- insertUpcoming ------------------------------------------------------------------------------

    @Test
    fun insertUpcoming_beforeUid_andFallbackAppend_notAListenerEdit() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c"), "set_1"); h.settle()
        val l = Transitions().also { h.seq.hooks.add(it) }
        val c = h.seq.state.value.queue[2].uid
        h.seq.insertUpcoming(rows("x"), c)
        assertEquals(listOf("a", "b", "x", "c"), h.ids)
        h.seq.insertUpcoming(rows("y"), "gone")
        assertEquals(listOf("a", "b", "x", "c", "y"), h.ids)
        h.seq.insertUpcoming(rows("d"), null)
        assertEquals(listOf("a", "b", "x", "c", "y", "d"), h.ids)
        assertTrue("no listener EDIT intent", l.transports.isEmpty())
        // a row landed at the next slot by a remote insert still announces it
        val landed = mutableListOf<String>()
        h.seq.hooks.add(object : SequencerListener { override fun onRowLandedNext(uid: String) { landed += uid } })
        val b = h.seq.state.value.queue[1].uid
        h.seq.insertUpcoming(rows("x"), b)
        assertEquals(1, landed.size)
        assertEquals("x", h.seq.state.value.queue[1].id)
    }

    @Test
    fun replaceUpcomingSegment_replacesTheFirstNUpcomingRowsOnly() = runTest {
        val h = harness()
        h.seq.play(rows("a", "b", "c", "d"), "set_1"); h.settle()
        h.seq.replaceUpcomingSegment(2, rows("x", "y"))
        assertEquals(listOf("a", "x", "y", "d"), h.ids)
        h.seq.replaceUpcomingSegment(10, rows("c"))
        assertEquals(listOf("a", "c"), h.ids)
    }

    // ---- silenceForController --------------------------------------------------------------------------

    @Test
    fun silenceForController_cancelsAnInFlightStart_andParksHeldAtThePosition() = runTest {
        val h = harness()
        h.port.gates["a"] = CompletableDeferred()
        h.seq.play(rows("a", "b"), "set_1"); h.settle()
        assertTrue("start in flight", h.seq.isStartPending)
        val l = Transitions().also { h.seq.hooks.add(it) }

        h.seq.silenceForController(); h.settle()
        assertTrue(h.seq.isHeldForResume)
        assertTrue(h.seq.isHeldByRemote)
        assertTrue(h.port.pauses > 0)
        assertEquals(1, l.held)
        h.port.gates["a"]!!.complete(Unit); h.settle()
        assertTrue("the cancelled start must never sound", h.port.sounded.isEmpty())

        // idempotent
        h.seq.silenceForController(); h.settle()
        assertEquals(1, l.held)

        // the next ▶ (the gate says "not a controller anymore") starts the row again
        h.port.gates.clear()
        h.seq.resumeFromHold(); h.settle()
        assertEquals(listOf("a"), h.port.sounded)
        assertFalse(h.seq.isHeldForResume)
    }

    @Test
    fun silenceForController_keepsTheSoundingPositionAsTheResumePoint() = runTest {
        val h = harness()
        val e = Engine().also { it.playing = true; it.pos = 73_000 }
        h.seq.engine = e
        h.seq.play(rows("a", "b"), "set_1"); h.settle()
        h.seq.onFirstAudio("a"); h.settle()
        h.seq.silenceForController(); h.settle()
        assertEquals(73_000L, h.seq.resumeOffsetMs)
        h.seq.setHeldResumePosition(90_000)
        assertEquals(90_000L, h.seq.resumeOffsetMs)
        h.seq.setHeldResumePosition(0)
        assertNull(h.seq.resumeOffsetMs)
    }

    @Test
    fun silenceForController_idleIsANoOp() = runTest {
        val h = harness()
        h.seq.silenceForController()
        assertFalse(h.seq.isHeldForResume)
        assertTrue(h.port.pauses == 0)
    }
}

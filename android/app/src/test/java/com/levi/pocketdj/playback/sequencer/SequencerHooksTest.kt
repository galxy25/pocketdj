package com.levi.pocketdj.playback.sequencer

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Event recorder: one short string per callback, in delivery order. */
class Recorder : SequencerListener {
    val events = mutableListOf<String>()
    override fun onSessionStarted(sessionId: String, source: SourceRef) { events += "started(${source.kind},${source.id})" }
    override fun onSessionEnded(reason: SessionEndReason) { events += "ended($reason)" }
    override fun onTrackStarted(start: TrackStart) { events += "track(${start.item.id}#${start.index},${start.path},fresh=${start.fresh})" }
    override fun onTransition(t: Transition) { events += "transition(${t.cause},seq=${t.seq})" }
    override fun onUserTransport(kind: UserTransport) { events += "user($kind)" }
    override fun onQueueChanged(generation: Long) { events += "queue($generation)" }
    override fun onFirstAudio(item: QueueItem, source: String) { events += "audio(${item.id})" }
    override fun onHeld() { events += "held" }
    override fun onResumedFromHold() { events += "resumed" }
}

@OptIn(ExperimentalCoroutinesApi::class)
class SequencerHooksTest {
    private fun TestScope.harness(vararg playable: String) = SequencerHarness(this, backgroundScope, playable.toSet())

    private fun SequencerHarness.record() = Recorder().also { seq.hooks.add(it) }

    @Test
    fun play_eventOrder_endsWithTrackStarted() = runTest {
        val h = harness("a", "b")
        val r = h.record()
        h.seq.play(rows("a", "b"), "set_1")
        h.settle()
        assertEquals(
            listOf("user(PLAY)", "started(setlist,set_1)", "queue(1)", "transition(USER,seq=1)", "track(a#0,EXO,fresh=true)"),
            r.events,
        )
        assertEquals(1L, h.seq.lastUserTransitionSeq)
        assertEquals(1L, h.seq.queueGeneration)
        assertEquals(1L, h.seq.state.value.transitionSeq)
    }

    @Test
    fun skip_isUserCause_andRecordsLastUserSeq() = runTest {
        val h = harness("a", "b", "c")
        h.seq.play(rows("a", "b", "c")); h.settle()
        val r = h.record()
        h.seq.skipNext(); h.settle()
        assertEquals(listOf("user(SKIP)", "transition(USER,seq=2)", "track(b#1,EXO,fresh=true)"), r.events)
        h.seq.skipPrevious(); h.settle()
        assertEquals("user(PREV)", r.events[3])
        assertEquals("transition(USER,seq=3)", r.events[4])
        assertEquals(3L, h.seq.lastUserTransitionSeq)
    }

    @Test
    fun naturalEnd_isNaturalEndCause_notUser() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b")); h.settle()
        val r = h.record()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("transition(NATURAL_END,seq=2)", "track(b#1,EXO,fresh=true)"), r.events)
        assertEquals("a natural end never moves the user seq", 1L, h.seq.lastUserTransitionSeq)
        assertEquals(2L, h.seq.transitionSeq)
    }

    @Test
    fun deadSource_isAutoSkip_andUnplayableIsUnplayable() = runTest {
        val h = harness("a", "c") // b has no source: unplayable
        h.seq.play(rows("a", "b", "c")); h.settle()
        val r = h.record()
        h.seq.handleFailed("a"); h.settle() // a dies mid-song -> AUTO_SKIP to b, which is unplayable -> UNPLAYABLE to c
        assertEquals(
            listOf("transition(AUTO_SKIP,seq=2)", "transition(UNPLAYABLE,seq=3)", "track(c#2,EXO,fresh=true)"),
            r.events,
        )
    }

    @Test
    fun stallHop_isStallHopCause() = runTest {
        val h = harness("a", "b", "c")
        h.seq.rowOnDevice = { it.id == "b" }
        h.seq.play(rows("a", "b", "c")); h.settle()
        val r = h.record()
        h.seq.escalateStalledStart("test stall"); h.settle()
        assertEquals("hop queue edit then transition", listOf("queue(2)", "transition(STALL_HOP,seq=2)", "track(b#0,EXO,fresh=true)"), r.events)
        assertEquals(listOf("b", "a", "c"), h.ids)
    }

    @Test
    fun edits_reportIntent_andBumpQueueGeneration() = runTest {
        val h = harness("a", "b", "c", "d")
        h.seq.play(rows("a", "b", "c")); h.settle()
        val r = h.record()
        h.seq.appendToQueue(rows("d"))
        assertEquals(listOf("user(EDIT)", "queue(2)"), r.events)
        val uid = h.seq.upcomingUid(1)!!
        h.seq.moveUpcomingNext(uid)
        assertEquals(listOf("user(EDIT)", "queue(3)"), r.events.takeLast(2))
        h.seq.moveUpcomingNext("no-such-uid") // a no-op edit announces nothing
        assertEquals(3L, h.seq.queueGeneration)
        assertEquals("edits do not move the cursor", 1L, h.seq.transitionSeq)
    }

    @Test
    fun stop_endsSession_andFinishedWhenSetRunsOut() = runTest {
        val h = harness("a")
        h.seq.play(rows("a")); h.settle()
        val r = h.record()
        h.seq.stop(); h.settle()
        assertEquals(listOf("ended(STOPPED)", "queue(2)"), r.events)

        h.seq.play(rows("a")); h.settle()
        r.events.clear()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("ended(FINISHED)", "queue(4)"), r.events)
    }

    @Test
    fun playOverRunning_endsOldSessionAsReplaced_thenStartsNew() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a")); h.settle()
        val r = h.record()
        h.seq.play(rows("b"), "set_2"); h.settle()
        assertEquals(
            listOf("user(PLAY)", "ended(REPLACED)", "started(setlist,set_2)", "queue(2)", "transition(USER,seq=2)", "track(b#0,EXO,fresh=true)"),
            r.events,
        )
    }

    @Test
    fun firstAudio_firesOncePerStart() = runTest {
        val h = harness("a")
        h.seq.play(rows("a")); h.settle()
        val r = h.record()
        h.seq.onFirstAudio("a"); h.seq.onFirstAudio("a")
        assertEquals(listOf("audio(a)"), r.events)
    }

    @Test
    fun heldRestore_thenResume_orderedHeldThenResumed_noAudioBeforePlay() = runTest {
        val h = harness("a", "b")
        val r = h.record()
        h.seq.restoreHeld(rows("a", "b"), 1, "set_1", null, null, RepeatMode.OFF, false, 5_000)
        h.settle()
        assertEquals(listOf("started(setlist,set_1)", "queue(1)", "held"), r.events)
        assertTrue(h.port.loads.isEmpty())
        h.seq.resumeFromHold(); h.settle()
        assertEquals(listOf("user(PLAY)", "resumed", "track(b#1,EXO,fresh=false)"), r.events.drop(3))
        assertEquals("resume at an offset is not a fresh track", 5_000L, h.port.loads.single().resumeAtMs)
    }

    @Test
    fun skipWhileHeld_leavesHold() = runTest {
        val h = harness("a", "b", "c")
        h.seq.restoreHeld(rows("a", "b", "c"), 0, null, null, null, RepeatMode.OFF, false, null)
        val r = h.record()
        h.seq.skipNext(); h.settle()
        assertEquals(listOf("user(SKIP)", "resumed", "transition(USER,seq=1)", "track(b#1,EXO,fresh=true)"), r.events)
    }

    @Test
    fun throwingListener_doesNotBreakPlaybackOrOtherListeners() = runTest {
        val h = harness("a", "b")
        val bad = object : SequencerListener {
            override fun onTransition(t: Transition) = error("boom")
            override fun onTrackStarted(start: TrackStart) = throw IllegalStateException("boom2")
        }
        h.seq.hooks.add(bad)
        val good = h.record()
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.skipNext(); h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertTrue(good.events.contains("transition(USER,seq=2)"))
        assertTrue(good.events.contains("track(b#1,EXO,fresh=true)"))
        assertTrue(h.logs.any { it.contains("listener") && it.contains("threw") })
    }

    @Test
    fun reentrantEmit_isDeliveredInEmissionOrder() = runTest {
        val h = harness("a", "b", "c")
        h.seq.play(rows("a", "b", "c")); h.settle()
        val order = mutableListOf<String>()
        h.seq.hooks.add(object : SequencerListener {
            var first = true
            override fun onQueueChanged(generation: Long) {
                order += "A:queue($generation)"
                if (first) { first = false; h.seq.appendToQueue(rows("x")) } // re-enters while A is mid-event
            }
        })
        h.seq.hooks.add(object : SequencerListener {
            override fun onQueueChanged(generation: Long) { order += "B:queue($generation)" }
        })
        h.seq.appendToQueue(rows("y"))
        // B sees gen 2 before the nested gen 3 is delivered to anyone
        assertEquals(listOf("A:queue(2)", "B:queue(2)", "A:queue(3)", "B:queue(3)"), order)
    }

    @Test
    fun applyingRemote_tagsTransitionsRemote_andIsNotUserIntent() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b")); h.settle()
        val r = h.record()
        h.seq.applyingCause(TransitionCause.REMOTE) { h.seq.skipNext() }
        h.settle()
        assertEquals(listOf("transition(REMOTE,seq=2)", "track(b#1,EXO,fresh=true)"), r.events)
        assertEquals("a REMOTE move is not a local user transition", 1L, h.seq.lastUserTransitionSeq)
    }

    @Test
    fun removedListener_stopsReceiving_andNoListenersIsBehaviourNeutral() = runTest {
        val h = harness("a", "b")
        val r = h.record()
        h.seq.hooks.remove(r)
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.skipNext(); h.settle()
        assertTrue(r.events.isEmpty())
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertFalse(h.seq.state.value.isHeldForResume)
    }

    @Test
    fun sessionLog_hasTransitionAndQueueGenLines() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.skipNext(); h.settle()
        assertTrue(h.logs.any { it.startsWith("[session] transition cause=USER seq=2 from=") })
        assertTrue(h.logs.any { it == "[session] queueGen=1 size=2" })
    }
}

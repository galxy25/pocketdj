package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.health.DeadAirMeter
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class NextRowPreloaderTest {
    private fun q(vararg ids: String) = rows(*ids)

    private fun NextRowPreloader.t(
        queue: List<QueueItem>,
        index: Int = 0,
        repeat: RepeatMode = RepeatMode.OFF,
        shuffle: Boolean = false,
        plays: Int = 1,
        active: Boolean = true,
    ) = target(queue, index, repeat, shuffle, plays, active)

    // ---- pure target rules -------------------------------------------------------------------------

    @Test fun target_isTheNextRow() {
        val queue = q("a", "b", "c")
        val t = NextRowPreloader().t(queue, 1)!!
        assertEquals(2, t.index)
        assertEquals("c", t.item.id)
        assertEquals(queue[2].uid, t.item.uid)
    }

    @Test fun target_noneAtTheEndExceptRepeatAllWrap() {
        val queue = q("a", "b")
        val p = NextRowPreloader()
        assertNull(p.t(queue, 1))
        assertEquals("a", p.t(queue, 1, repeat = RepeatMode.ALL)!!.item.id)
        assertEquals(0, p.t(queue, 1, repeat = RepeatMode.ALL)!!.index)
    }

    @Test fun target_wrapUnderShuffleIsUnknown_andSingleRowNeverWraps() {
        val p = NextRowPreloader()
        assertNull(p.t(q("a", "b"), 1, repeat = RepeatMode.ALL, shuffle = true))
        assertNull(p.t(q("a"), 0, repeat = RepeatMode.ALL))
    }

    @Test fun target_replayPathsNeverPreload() {
        val p = NextRowPreloader()
        val queue = q("a", "b")
        assertNull("repeat ONE replays", p.t(queue, 0, repeat = RepeatMode.ONE))
        assertNull("repeatCount passes remain", p.t(queue, 0, plays = 2))
        val dup = listOf(QueueItem("a"), QueueItem("a"), QueueItem("b"))
        assertNull("consecutive duplicate row replays in place", p.t(dup, 0))
        assertEquals("b", p.t(dup, 1)!!.item.id)
    }

    @Test fun target_disabledOrInactiveIsNothing() {
        assertNull(NextRowPreloader(enabled = false).t(q("a", "b")))
        assertNull(NextRowPreloader().t(q("a", "b"), active = false))
        assertNull(NextRowPreloader().t(q("a", "b"), index = 9))
    }

    // ---- decide: add / keep / replace / remove ------------------------------------------------------

    @Test fun decide_addKeepReplaceRemove() {
        val p = NextRowPreloader()
        val queue = q("a", "b", "c")
        val tb = p.t(queue, 0)
        val sb = stream("b")
        assertTrue(p.decide(tb, sb) is NextRowPreloader.Plan.Add)
        p.noteInstalled(queue[1], sb)
        assertEquals(NextRowPreloader.Plan.Keep, p.decide(tb, sb))
        // next row edited -> replace
        val tc = p.t(listOf(queue[0], queue[2], queue[1]), 0)
        assertTrue(p.decide(tc, stream("c")) is NextRowPreloader.Plan.Replace)
        // same row, better source (a burn landed) -> replace
        assertTrue(p.decide(tb, stream("b2")) is NextRowPreloader.Plan.Replace)
        // row removed -> remove
        assertEquals(NextRowPreloader.Plan.Remove, p.decide(null, null))
        assertTrue(p.isStale(null))
        assertTrue(p.isStale(tc))
        assertFalse(p.isStale(tb))
    }

    @Test fun decide_ineligibleSourcesAreNeverAdded() {
        val p = NextRowPreloader()
        val queue = q("a", "b")
        val t = p.t(queue, 0)
        assertEquals(NextRowPreloader.Plan.None, p.decide(t, RipOnDemandSource("b")))
        assertEquals(NextRowPreloader.Plan.None, p.decide(t, UnplayableSource(UnplayableSource.Reason.METADATA_ONLY)))
        assertEquals(NextRowPreloader.Plan.None, p.decide(t, null))
        assertTrue(p.eligible(LocalFileSource(LocalFile("file:///x.mp3", 0, null))))
        p.noteInstalled(queue[1], stream("b"))
        assertEquals("an installed slot goes when the next row turns out ineligible",
            NextRowPreloader.Plan.Remove, p.decide(t, RipOnDemandSource("b")))
    }

    @Test fun decide_disabledEmptiesTheWindow() {
        val p = NextRowPreloader()
        val queue = q("a", "b")
        p.noteInstalled(queue[1], stream("b"))
        p.enabled = false
        assertEquals(NextRowPreloader.Plan.Remove, p.decide(p.t(queue, 0), stream("b")))
        p.noteCleared()
        assertEquals(NextRowPreloader.Plan.None, p.decide(p.t(queue, 0), stream("b")))
    }

    @Test fun autoTransition_consumesOnlyTheSlotRow() {
        val p = NextRowPreloader()
        val queue = listOf(QueueItem("a"), QueueItem("b", resolveId = "b_clean"))
        p.noteInstalled(queue[1], stream("b"))
        assertNull(p.consumeAutoTransition("zzz"))
        assertEquals(queue[1].uid, p.slot!!.uid)
        assertEquals(queue[1].uid, p.consumeAutoTransition("b_clean")!!.uid)
        assertNull("consumed", p.slot)
        assertNull(p.consumeAutoTransition("b"))
    }

    // ---- sequencer integration ----------------------------------------------------------------------

    private fun TestHarness(t: kotlinx.coroutines.test.TestScope, playable: Set<String>) =
        SequencerHarness(t, t.backgroundScope, playable).also { it.seq.preloadEnabled = true }

    private fun SequencerHarness.start(vararg ids: String) {
        seq.play(rows(*ids), null)
        settle()
    }

    @Test fun nextRowIsPreloadedOnlyAfterTheCurrentRowIsAudible() = runTest {
        val h = TestHarness(this, setOf("a", "b", "c"))
        h.start("a", "b", "c")
        assertTrue("current still loading: nothing preloaded", h.port.preloadCalls.isEmpty())
        h.seq.onFirstAudio("a")
        h.settle()
        assertEquals(listOf<String?>("b"), h.port.preloadCalls)
        assertEquals("b", h.seq.preloader.slot!!.songId)
        assertEquals(listOf("a"), h.port.loadedIds) // ExoPlayer still loaded only the current row
    }

    @Test fun unplayableOrAmNextRowIsNotAdded() = runTest {
        val h = TestHarness(this, setOf("a", "c")) // b has no source
        h.start("a", "b", "c")
        h.seq.onFirstAudio("a")
        h.settle()
        assertTrue(h.port.preloadCalls.isEmpty())
        assertNull(h.seq.preloader.slot)
    }

    @Test fun liveEditReplacesThenRemovesTheWindowSlot() = runTest {
        val h = TestHarness(this, setOf("a", "b", "c", "d"))
        h.start("a", "b", "c", "d")
        h.seq.onFirstAudio("a"); h.settle()
        assertEquals("b", h.port.preloadedId)
        val dUid = h.seq.state.value.queue[3].uid
        h.seq.moveUpcomingNext(dUid)
        h.settle()
        assertEquals("d", h.port.preloadedId)
        assertEquals(dUid, h.seq.preloader.slot!!.uid)
        h.seq.removeUpcoming(setOf(dUid))
        h.settle()
        assertEquals("b", h.port.preloadedId) // b is next again
        h.seq.removeUpcoming(h.seq.state.value.queue.drop(1).map { it.uid }.toSet())
        h.settle()
        assertNull(h.port.preloadedId)
        assertNull(h.seq.preloader.slot)
    }

    @Test fun shuffleChangeReconcilesTheWindow() = runTest {
        val h = TestHarness(this, setOf("a", "b", "c", "d", "e", "f"))
        h.start("a", "b", "c", "d", "e", "f")
        h.seq.onFirstAudio("a"); h.settle()
        h.seq.setShuffle(true); h.settle()
        val nextAfterShuffle = h.seq.state.value.queue[1].id
        assertEquals(nextAfterShuffle, h.port.preloadedId)
        h.seq.setShuffle(false); h.settle()
        assertEquals("b", h.port.preloadedId)
    }

    @Test fun autoTransitionAdvancesToThePreloadedUid_andClosesTheGapAtZero() = runTest {
        val h = TestHarness(this, setOf("a", "b", "c", "d"))
        val gaps = mutableListOf<String>()
        h.seq.meter = DeadAirMeter(file = null, log = { gaps += it })
        h.start("a", "b", "c", "d")
        h.seq.onFirstAudio("a"); h.settle()
        // a live edit puts d next BEFORE the engine rolls on: the window follows, the cursor goes to d, not index+1 (b)
        val dUid = h.seq.state.value.queue[3].uid
        h.seq.moveUpcomingNext(dUid); h.settle()
        assertTrue(h.seq.handlePreloadedTransition("d"))
        h.settle()
        assertEquals("d", h.seq.state.value.current!!.id)
        assertEquals(dUid, h.seq.state.value.current!!.uid)
        assertEquals("no engine load: the window did the work", listOf("a"), h.port.loadedIds)
        assertTrue("gap line recorded ~0: $gaps", gaps.any { it.startsWith("gap=0.00s") && it.endsWith("cause=advance") })
        // the new current row is audible already, so the following row (b) is preloaded immediately
        assertEquals("b", h.port.preloadedId)
    }

    @Test fun transitionForAnUnknownRowIsIgnored() = runTest {
        val h = TestHarness(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.onFirstAudio("a"); h.settle()
        assertFalse(h.seq.handlePreloadedTransition("zzz"))
        assertEquals("a", h.seq.state.value.current!!.id)
        assertEquals("b", h.seq.preloader.slot!!.songId)
    }

    @Test fun repeatOne_neverPreloads_andClearsAnExistingSlot() = runTest {
        val h = TestHarness(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.onFirstAudio("a"); h.settle()
        assertEquals("b", h.port.preloadedId)
        h.seq.setRepeatMode(RepeatMode.ONE); h.settle()
        assertNull(h.port.preloadedId)
        assertNull(h.seq.preloader.slot)
        h.seq.handleEnded("a"); h.settle()
        assertEquals("replay by seek, no duplicate load", listOf("a"), h.port.loadedIds)
        assertEquals(listOf("a"), h.port.replays)
        h.seq.setRepeatMode(RepeatMode.OFF); h.settle()
        assertEquals("b", h.port.preloadedId)
    }

    @Test fun repeatCountPasses_replayBeforeAnythingIsPreloaded() = runTest {
        val h = TestHarness(this, setOf("a", "b"))
        h.seq.play(listOf(QueueItem("a", repeatCount = 2), QueueItem("b")), null)
        h.settle()
        h.seq.onFirstAudio("a"); h.settle()
        assertTrue("first of two passes: next play is the same row", h.port.preloadCalls.isEmpty())
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a"), h.port.replays)
        h.seq.onFirstAudio("a"); h.settle()
        assertEquals("final pass: now the different row is windowed", "b", h.port.preloadedId)
    }

    @Test fun disabledFlagBehavesLikePb3() = runTest {
        val h = SequencerHarness(this, backgroundScope, setOf("a", "b", "c"))
        assertFalse(h.seq.preloadEnabled)
        h.start("a", "b", "c")
        h.seq.onFirstAudio("a"); h.settle()
        assertTrue(h.port.preloadCalls.isEmpty())
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertFalse("without a slot a stray transition is ignored", h.seq.handlePreloadedTransition("c"))
    }

    @Test fun flippingTheFlagOffEmptiesTheWindow() = runTest {
        val h = TestHarness(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.onFirstAudio("a"); h.settle()
        assertEquals("b", h.port.preloadedId)
        h.seq.preloadEnabled = false; h.settle()
        assertNull(h.port.preloadedId)
    }

    @Test fun stoppingTheRunForgetsTheSlot() = runTest {
        val h = TestHarness(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.onFirstAudio("a"); h.settle()
        h.seq.stop(); h.settle()
        assertNull(h.seq.preloader.slot)
        assertFalse(h.seq.handlePreloadedTransition("b"))
    }
}

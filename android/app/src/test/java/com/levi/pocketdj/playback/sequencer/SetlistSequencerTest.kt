package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.PlaybackMode
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
class SetlistSequencerTest {
    private fun TestScope.harness(vararg playable: String, mode: PlaybackMode = PlaybackMode.CLOUD) =
        SequencerHarness(this, backgroundScope, playable.toSet(), mode)

    @Test
    fun play_empty_isNoOp() = runTest {
        val h = harness("a")
        h.seq.play(emptyList())
        h.settle()
        assertFalse(h.seq.isRunning)
        assertTrue(h.port.loads.isEmpty())
    }

    @Test
    fun play_loadsFirstRow_andPublishesState() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b"), "set_1")
        h.settle()
        assertEquals(listOf("a"), h.port.loadedIds)
        val s = h.seq.state.value
        assertTrue(s.isRunning)
        assertEquals("a", s.currentSongId)
        assertEquals(listOf("b"), s.upcoming.map { it.id })
        assertEquals("set_1", s.sourceSetlistId)
        assertTrue(h.logs.any { it.startsWith("[playback] track start song=a index=1/2 backend=rip") })
    }

    @Test
    fun play_capturesContextAndOriginOnce() = runTest {
        val h = harness("a", "b")
        var calls = 0
        h.seq.historyContextProvider = { PlayContext.playlist(it!!, "Road trip").also { calls++ } }
        h.seq.originProvider = { "playlist" to "pl_9" }
        h.seq.play(rows("a", "b"), NOW_PLAYING_SETLIST_ID)
        h.settle()
        // A later provider change (another playNow mutating the shared source) cannot retag this run.
        h.seq.historyContextProvider = { PlayContext.pocket("zzz", "Other") }
        h.seq.originProvider = { "pocket" to "pk_1" }
        h.seq.handleEnded("a")
        h.settle()
        assertEquals(1, calls)
        val second = h.port.loads[1]
        assertEquals("b", second.item.id)
        assertEquals(PlayContext.playlist(NOW_PLAYING_SETLIST_ID, "Road trip"), second.context)
        // contextId == set_now_playing -> History rows carry the origin collection id.
        assertEquals("pl_9", second.originCollectionId)
        assertEquals("playlist" to "pl_9", h.seq.state.value.capturedOrigin)
    }

    @Test
    fun originCollectionId_onlyForNowPlayingSetlist() = runTest {
        val h = harness("a")
        h.seq.originProvider = { "setlist" to "set_real" }
        h.seq.play(rows("a"), "set_real")
        h.settle()
        assertNull(h.port.loads.single().originCollectionId)
    }

    @Test
    fun play_replacesRunningSet_shuffleResets_repeatSticky() = runTest {
        val h = harness("a", "b", "c", "x", "y")
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        h.seq.setShuffle(true)
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("x", "y"))
        h.settle()
        val s = h.seq.state.value
        assertEquals(listOf("x", "y"), s.queue.map { it.id })
        assertEquals(0, s.index)
        assertFalse(s.shuffleEnabled)
        assertEquals(RepeatMode.ALL, s.repeatMode)
        assertEquals("x", h.port.loads.last().item.id)
    }

    @Test
    fun naturalEnd_advances_pastEndStopsAndClears() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        h.seq.handleEnded("b"); h.settle()
        val s = h.seq.state.value
        assertFalse(s.isRunning)
        assertTrue(s.queue.isEmpty())
        assertEquals(1, h.port.stops)
    }

    @Test
    fun repeatCount_isTotalPlaysBeforeAdvance() = runTest {
        val h = harness("a", "b")
        h.seq.play(listOf(QueueItem("a", repeatCount = 3), QueueItem("b")))
        h.settle()
        repeat(3) { h.seq.handleEnded("a"); h.settle() }
        // Passes 2 and 3 restart the held item in place (no reload = no extra History row).
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertEquals(listOf("a", "a"), h.port.replays)
        // The repeat loop never moved the cursor.
        assertEquals(1, h.index)
    }

    @Test
    fun repeatOne_replaysCurrentOnNaturalEnd() = runTest {
        val h = harness("a", "b")
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a"), h.port.loadedIds)
        assertEquals(listOf("a", "a"), h.port.replays)
        assertEquals(0, h.index)
    }

    @Test
    fun repeatAll_wrapsToTop() = runTest {
        val h = harness("a", "b")
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        h.seq.handleEnded("b"); h.settle()
        assertEquals(listOf("a", "b", "a"), h.port.loadedIds)
        assertTrue(h.seq.isRunning)
    }

    @Test
    fun repeatAll_withShuffle_reshufflesWholeQueueOnWrap_keepsMembers() = runTest {
        val ids = (1..12).map { "s$it" }
        val h = SequencerHarness(this, backgroundScope, ids.toSet())
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows(*ids.toTypedArray()))
        h.settle()
        h.seq.setShuffle(true)
        val before = h.ids
        // Walk to the end of the pass.
        repeat(ids.size) { h.seq.handleEnded(h.seq.currentSongId!!); h.settle() }
        assertEquals(0, h.index)
        assertEquals(ids.toSet(), h.ids.toSet())
        assertEquals(ids.size, h.ids.size)
        assertTrue("whole queue reshuffled on wrap", h.ids != before)
    }

    @Test
    fun deadSource_advances_neverReplays_evenUnderRepeatOne() = runTest {
        val h = harness("a", "b")
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleFailed("a"); h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertEquals(1, h.index)
    }

    @Test
    fun loadThrowing_advancesToNextRow() = runTest {
        val h = harness("a", "b")
        h.port.failing += "a"
        h.seq.play(rows("a", "b"))
        h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
        assertEquals(listOf("b"), h.port.sounded)
    }

    @Test
    fun metadataOnlyRowBetweenPlayableRows_isSkippedWithAdvanceLine() = runTest {
        val h = harness("a", "c") // "m" resolves nowhere
        h.seq.play(rows("a", "m", "c"))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "c"), h.port.loadedIds)
        assertEquals(2, h.index)
        assertTrue(h.logs.any { it.startsWith("[playback] advance: unplayable song=m") })
    }

    @Test
    fun endedForeignSingle_neverAdvancesTheSet() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.handleEnded("zzz"); h.settle()
        h.seq.handleFailed("zzz"); h.settle()
        assertEquals(0, h.index)
        assertEquals(listOf("a"), h.port.loadedIds)
    }

    @Test
    fun skipPrevious_floorAtZeroRestarts_neverBelow() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.skipPrevious(); h.settle()
        assertEquals(0, h.index)
        assertEquals(listOf("a", "a"), h.port.loadedIds) // restarted
        h.seq.skipNext(); h.settle()
        h.seq.skipPrevious(); h.settle()
        assertEquals(0, h.index)
        assertEquals(listOf("a", "a", "b", "a"), h.port.loadedIds)
    }

    @Test
    fun skipPrevious_atTopWrapsToLast_onlyWithRepeatAllAndMoreThanOneRow() = runTest {
        val h = harness("a", "b", "c")
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        h.seq.skipPrevious(); h.settle()
        assertEquals(2, h.index)
        assertEquals("c", h.port.loadedIds.last())

        val single = harness("z")
        single.seq.setRepeatMode(RepeatMode.ALL)
        single.seq.play(rows("z"))
        single.settle()
        single.seq.skipPrevious(); single.settle()
        assertEquals(0, single.index)
    }

    @Test
    fun skipNext_pastEnd_withRepeatOff_stops() = runTest {
        val h = harness("a")
        h.seq.play(rows("a"))
        h.settle()
        h.seq.skipNext(); h.settle()
        assertFalse(h.seq.isRunning)
    }

    @Test
    fun rapidSkips_onlyTheLastRowLoads_andCancelledJobsNeverClaimGenerations() = runTest {
        val h = harness("a", "b", "c", "d", "e")
        h.seq.play(rows("a", "b", "c", "d", "e"))
        repeat(3) { h.seq.skipNext() } // none of the intermediate jobs got to run
        h.settle()
        assertEquals(listOf("d"), h.port.loadedIds)
        assertEquals(3, h.index)
        // One live start = one claimed generation.
        assertEquals(1L, h.seq.state.value.playGeneration)
    }

    @Test
    fun supersededSlowLoad_failingLate_neverAdvancesTheNewerRow() = runTest {
        val h = harness("a", "b", "c")
        val gate = CompletableDeferred<Unit>()
        h.port.gates["a"] = gate
        h.seq.play(rows("a", "b", "c"))
        h.settle() // a is loading (gated)
        h.seq.skipNext(); h.settle() // b becomes current and sounds
        assertEquals(1, h.index)
        gate.completeExceptionally(IllegalStateException("late failure")) // a's engine error arrives late
        h.settle()
        assertEquals(1, h.index)
        assertEquals(listOf("a", "b"), h.port.loadedIds)
    }

    @Test
    fun supersededSlowResolve_returningLate_neverLoads() = runTest {
        val gate = CompletableDeferred<Unit>()
        val slow = MapResolver("slow", Rung.LOCAL_FILE, mapOf("a" to stream("a")), mapOf("a" to gate))
        val h = SequencerHarness(this, backgroundScope, setOf("b"), extra = listOf(slow))
        h.seq.play(rows("a", "b"))
        h.settle() // resolving a, suspended
        h.seq.skipNext(); h.settle()
        gate.complete(Unit)
        h.settle()
        assertEquals(listOf("b"), h.port.loadedIds)
        assertEquals(1, h.index)
    }

    @Test
    fun adoptCursor_member_picksNearestOccurrence_forwardPreferredOnTies() = runTest {
        val h = harness("a", "b", "c")
        h.seq.play(rows("a", "b", "c", "b", "a", "b"))
        h.settle()
        h.seq.skipNext(); h.settle() // index 1
        h.seq.skipNext(); h.settle() // index 2 (c)
        assertTrue(h.seq.adoptCursor("a"))
        // a sits at 0 and 4: distance 2 vs 2 -> forward (4).
        assertEquals(4, h.index)
        assertTrue(h.seq.adoptCursor("b"))
        assertEquals(5, h.index) // nearest to 4 is 3 (d=1) or 5 (d=1): forward preferred
        assertTrue(h.seq.isRunning)
    }

    @Test
    fun adoptCursor_nonMember_leavesIndexUntouched() = runTest {
        val h = harness("a", "b")
        h.seq.play(rows("a", "b"))
        h.settle()
        h.seq.skipNext(); h.settle()
        assertFalse(h.seq.adoptCursor("zzz"))
        assertEquals(1, h.index)
        assertTrue(h.seq.isRunning)
    }

    @Test
    fun adoptCursor_retiresAPendingResolveSoItNeverLoadsOverTheManualPlay() = runTest {
        val gate = CompletableDeferred<Unit>()
        val slow = MapResolver("slow", Rung.LOCAL_FILE, mapOf("b" to stream("b")), mapOf("b" to gate))
        val h = SequencerHarness(this, backgroundScope, setOf("a", "c"), extra = listOf(slow))
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        h.seq.skipNext(); h.settle() // resolving b (gated)
        assertTrue(h.seq.adoptCursor("c"))
        gate.complete(Unit)
        h.settle()
        assertEquals(listOf("a"), h.port.loadedIds)
        assertEquals(2, h.index)
    }

    @Test
    fun inRunningQueue_followsQueueEdits() = runTest {
        val h = harness("a", "b", "c")
        assertFalse(h.seq.inRunningQueue("a"))
        h.seq.play(rows("a", "b"))
        h.settle()
        assertTrue(h.seq.inRunningQueue("b"))
        assertFalse(h.seq.inRunningQueue("c"))
        h.seq.appendToQueue(rows("c"))
        assertTrue(h.seq.inRunningQueue("c"))
        h.seq.stop()
        assertFalse(h.seq.inRunningQueue("a"))
    }

    @Test
    fun deviceMode_skipsRowsWithoutLocalFile_withoutTrippingAnything() = runTest {
        val local = MapResolver(
            "local", Rung.LOCAL_FILE,
            mapOf("b" to LocalFileSource(LocalFile("file:///b.mp3"))),
        )
        val h = SequencerHarness(this, backgroundScope, setOf("a", "b", "c"), mode = PlaybackMode.DEVICE, extra = listOf(local))
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        assertEquals(listOf("b"), h.port.loadedIds)
        assertEquals(1, h.index)
        h.seq.handleEnded("b"); h.settle()
        // c has no on-device file: the run ends having loaded one, so NO banner.
        assertFalse(h.seq.isRunning)
        assertFalse(h.seq.state.value.deviceQueueUnplayable)
    }

    @Test
    fun deviceMode_runThatLoadsNoDeviceFile_raisesBannerSignal() = runTest {
        val h = harness("a", "b", mode = PlaybackMode.DEVICE)
        h.seq.play(rows("a", "b"), "set_9")
        h.settle()
        assertTrue(h.port.loads.isEmpty())
        val s = h.seq.state.value
        assertFalse(s.isRunning)
        assertTrue(s.deviceQueueUnplayable)
        assertEquals("set_9", s.deviceUnplayableSourceId)
        h.seq.clearDeviceUnplayable()
        assertFalse(h.seq.state.value.deviceQueueUnplayable)
        assertNull(h.seq.state.value.deviceUnplayableSourceId)
    }

    @Test
    fun repeatAll_withNothingPlayable_stopsInsteadOfSpinning() = runTest {
        val h = harness("none")
        h.seq.setRepeatMode(RepeatMode.ALL)
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        assertFalse(h.seq.isRunning)
        assertTrue(h.port.loads.isEmpty())
    }

    @Test
    fun appendRows_stampsRunTagIntoPlayContext() = runTest {
        val h = harness("a", "g1")
        h.seq.historyContextProvider = { PlayContext.setlist("set_1", "S") }
        h.seq.play(rows("a"), "set_1")
        h.settle()
        assertEquals(0, h.seq.currentIndex())
        h.seq.appendRows(rows("g1"), "game:itp-7")
        assertEquals("game:itp-7", h.seq.state.value.queue.last().runTag)
        h.seq.handleEnded("a"); h.settle()
        val req = h.port.loads.last()
        assertEquals("g1", req.item.id)
        assertEquals("game:itp-7", req.context.runTag)
        assertEquals("set_1", req.context.contextId)
        assertNull(h.port.loads.first().context.runTag)
    }

    @Test
    fun playUrl_leavesAHeldQueueUntouched_butReplacesARunningOne() = runTest {
        val h = harness("a", "b")
        h.seq.restoreHeld(rows("a", "b"), 1, "set_1", PlayContext.setlist("set_1", "S"), null, RepeatMode.OFF, false, 5_000)
        h.seq.playUrl("Live", "DJ", "https://x/hls/live.m3u8", 12_000)
        val s = h.seq.state.value
        assertTrue(s.isHeldForResume)
        assertTrue(s.isRunning)
        assertEquals(1, s.index)
        assertEquals(12_000L, h.port.urls.single().seekMs)
        assertTrue(h.port.loads.isEmpty())

        val r = harness("a", "b")
        r.seq.play(rows("a", "b"))
        r.settle()
        r.seq.playUrl("Live", null, "https://x/y.mp3")
        assertFalse(r.seq.isRunning)
        r.seq.handleEnded("a"); r.settle()
        assertEquals(listOf("a"), r.port.loadedIds) // the stream's era must not advance the dead cursor
    }

    @Test
    fun resumeFromHold_startsCurrentRowMidSong_withoutAudioBefore() = runTest {
        val h = harness("a", "b")
        h.seq.restoreHeld(rows("a", "b"), 1, "set_1", null, null, RepeatMode.OFF, false, 42_000)
        h.settle()
        assertTrue(h.port.loads.isEmpty())
        h.seq.resumeFromHold(); h.settle()
        val req = h.port.loads.single()
        assertEquals("b", req.item.id)
        assertEquals(42_000L, req.resumeAtMs)
        assertFalse(h.seq.isHeldForResume)
    }

    @Test
    fun outcomes_naturalEndEmitsCompleted_skipEmitsSkippedWhenFractionKnown() = runTest {
        val h = harness("a", "b", "c")
        val seen = mutableListOf<Triple<String, Boolean, Double>>()
        h.seq.outcomes = com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry(
            { listOf(com.levi.pocketdj.shell.PlayOutcomeListener { id, sk, f -> seen += Triple(id, sk, f) }) },
        )
        h.seq.play(rows("a", "b", "c"))
        h.settle()
        h.seq.handleEnded("a"); h.settle()
        h.seq.progressProvider = { 0.2 }
        h.seq.skipNext(); h.settle()
        assertEquals(listOf(Triple("a", false, 1.0), Triple("b", true, 0.2)), seen)
    }
}

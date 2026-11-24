package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.PlayStarted
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class InterceptorTest {
    private fun TestScope.harness(vararg playable: String) = SequencerHarness(this, backgroundScope, playable.toSet())

    private fun registry(sink: (String, Boolean) -> Unit) =
        com.levi.pocketdj.playback.outcome.PlayOutcomeRegistry {
            listOf(com.levi.pocketdj.shell.PlayOutcomeListener { id, sk, _ -> sink(id, sk) })
        }

    /** Claims one song and installs its "audio" itself (no PlayerPort.load). */
    private class Claimer(
        val seq: SetlistSequencer,
        override val priority: Int,
        val songId: String,
        val path: StartPath = StartPath.DJ,
    ) : StartInterceptor {
        val asked = mutableListOf<String>()
        var lastAttempt: StartAttempt? = null
        override suspend fun tryClaim(attempt: StartAttempt): Boolean {
            asked += attempt.item.id
            lastAttempt = attempt
            if (attempt.item.id != songId) return false
            return seq.completeClaimedStart(attempt.gen, path)
        }
    }

    @Test
    fun claimedStart_skipsDefaultLoad_andRunsStartBookkeeping() = runTest {
        val h = harness("a", "b")
        val rec = Recorder().also { h.seq.hooks.add(it) }
        val claimer = Claimer(h.seq, 90, "a")
        h.seq.addStartInterceptor(claimer)
        h.seq.play(rows("a", "b")); h.settle()
        assertTrue("claimed: the engine was never asked to load", h.port.loads.isEmpty())
        assertEquals("track(a#0,DJ,fresh=true)", rec.events.last())
        // generation + start window + watchdog bookkeeping: a pending start, current row loaded, a started run
        assertTrue(h.seq.isStartPending)
        assertTrue(h.seq.currentRowLoaded)
        assertEquals(1L, h.seq.state.value.playGeneration)
        h.seq.onFirstAudio("a")
        assertFalse("first audio closes the start window", h.seq.isStartPending)
        assertTrue(rec.events.contains("audio(a)"))
        assertTrue(h.logs.any { it.startsWith("[playback] track start song=a index=1/2 backend=dj claimed=true") })
    }

    @Test
    fun claimedStart_recordsExactlyOneHistoryPlay() = runTest {
        val h = harness("a")
        val seen = mutableListOf<PlayStarted>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { PlayEventBus.events.collect { seen += it } }
        h.seq.addStartInterceptor(Claimer(h.seq, 90, "a"))
        h.seq.play(rows("a")); h.settle()
        assertEquals(listOf("a"), seen.map { it.songId })
    }

    @Test
    fun priorityOrder_highestFirst_firstClaimWins_unclaimedFallsThrough() = runTest {
        val h = harness("a", "b")
        val low = Claimer(h.seq, 10, "a")
        val high = Claimer(h.seq, 100, "zzz") // asked first, declines
        val mid = Claimer(h.seq, 50, "a")
        h.seq.addStartInterceptor(low); h.seq.addStartInterceptor(high); h.seq.addStartInterceptor(mid)
        h.seq.play(rows("a", "b")); h.settle()
        assertEquals(listOf("a"), high.asked)
        assertEquals(listOf("a"), mid.asked)
        assertTrue("claimed by mid before low is asked", low.asked.isEmpty())
        // b is declined by everyone -> the default load runs
        h.seq.skipNext(); h.settle()
        assertEquals(listOf("b"), h.port.loadedIds)
    }

    @Test
    fun throwingInterceptor_isLoggedAndPlaybackFallsBackToDefaultLoad() = runTest {
        val h = harness("a")
        h.seq.addStartInterceptor(object : StartInterceptor {
            override val priority = 100
            override suspend fun tryClaim(attempt: StartAttempt): Boolean = error("kaboom")
        })
        h.seq.play(rows("a")); h.settle()
        assertEquals(listOf("a"), h.port.loadedIds)
        assertTrue(h.logs.any { it.contains("start interceptor") && it.contains("threw") })
    }

    @Test
    fun supersededClaim_neverCompletes() = runTest {
        val h = harness("a", "b")
        val gate = CompletableDeferred<Unit>()
        var lateResult: Boolean? = null
        h.seq.addStartInterceptor(object : StartInterceptor {
            override val priority = 100
            override suspend fun tryClaim(attempt: StartAttempt): Boolean {
                if (attempt.item.id != "a") return false
                gate.await()
                lateResult = h.seq.completeClaimedStart(attempt.gen, StartPath.DJ)
                return true
            }
        })
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.skipNext(); h.settle() // supersedes a's pending claim
        gate.complete(Unit); h.settle()
        assertEquals(listOf("b"), h.port.loadedIds)
        assertTrue("the cancelled claim never reached completeClaimedStart or it was refused", lateResult == null || lateResult == false)
        assertEquals("b", h.seq.currentSongId)
    }

    @Test
    fun completeClaimedStart_withStaleGeneration_isRefused() = runTest {
        val h = harness("a")
        h.seq.play(rows("a")); h.settle()
        assertFalse(h.seq.completeClaimedStart(gen = 999, path = StartPath.DJ))
    }

    // ---- advance interceptors / advanceWithoutLoad --------------------------------------------------------

    private class NaturalEndClaimer(override val priority: Int, val claim: Boolean) : AdvanceInterceptor {
        val attempts = mutableListOf<AdvanceAttempt>()
        override fun onNaturalEnd(attempt: AdvanceAttempt): Boolean { attempts += attempt; return claim }
    }

    @Test
    fun naturalEnd_claimedByInterceptor_doesNotAdvance_untilAdvanceWithoutLoad() = runTest {
        val h = harness("a", "b", "c")
        val c = NaturalEndClaimer(100, true)
        h.seq.addAdvanceInterceptor(c)
        h.seq.play(rows("a", "b", "c")); h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals("a", h.seq.currentSongId)
        assertEquals("b", c.attempts.single().next?.id)
        assertEquals(listOf("a"), h.port.loadedIds)
        assertTrue(h.seq.advanceWithoutLoad(AdvanceCause.NATURAL_END, StartPath.ALBUM_GLIDE))
        h.settle()
        assertEquals("b", h.seq.currentSongId)
        assertEquals("no PlayerPort.load for the glided row", listOf("a"), h.port.loadedIds)
    }

    @Test
    fun declinedInterceptor_fallsThroughToNormalAdvance() = runTest {
        val h = harness("a", "b")
        h.seq.addAdvanceInterceptor(NaturalEndClaimer(10, false))
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertEquals(listOf("a", "b"), h.port.loadedIds)
    }

    @Test
    fun repeatOne_neverOffersTheAdvance() = runTest {
        val h = harness("a", "b")
        val c = NaturalEndClaimer(10, true)
        h.seq.addAdvanceInterceptor(c)
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.handleEnded("a"); h.settle()
        assertTrue(c.attempts.isEmpty())
    }

    /** Everything observable about a transition, so the load-less and the loading advance can be compared. */
    private data class Observed(
        val events: List<String>, val index: Int, val histories: List<String>, val verdicts: List<Pair<String, Boolean>>,
        val log: List<String>, val seq: Long, val gen: Long,
    )

    private fun TestScope.advanceRun(withoutLoad: Boolean): Pair<Observed, List<String>> {
        val h = harness("a", "b", "c")
        val histories = mutableListOf<String>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { PlayEventBus.events.collect { if (it.songId != "x") histories += it.songId } }
        val verdicts = mutableListOf<Pair<String, Boolean>>()
        h.seq.outcomes = registry { id, sk -> verdicts += id to sk }
        h.seq.play(rows("a", "b", "c")); h.settle()
        val rec = Recorder().also { h.seq.hooks.add(it) }
        histories.clear()
        if (withoutLoad) {
            assertTrue(h.seq.advanceWithoutLoad(AdvanceCause.NATURAL_END, StartPath.ALBUM_GLIDE)); h.settle()
        } else {
            h.seq.handleEnded("a"); h.settle()
        }
        val log = h.logs.filter { it.startsWith("[session] transition") }.map { it.substringBefore(" from=") }
        return Observed(
            rec.events.filterNot { it.startsWith("audio") }.map { it.replace("ALBUM_GLIDE", "EXO") }, h.index, histories.toList(), verdicts.toList(), log,
            h.seq.transitionSeq, h.seq.state.value.playGeneration,
        ) to h.port.loadedIds
    }

    @Test
    fun advanceWithoutLoad_matchesNormalAdvance_minusTheLoad() = runTest {
        val (normal, normalLoads) = advanceRun(withoutLoad = false)
        val (glide, glideLoads) = advanceRun(withoutLoad = true)
        assertEquals(listOf("a", "b"), normalLoads)
        assertEquals(listOf("a"), glideLoads)
        assertEquals(normal.events, glide.events)
        assertEquals(normal.index, glide.index)
        assertEquals("exactly one History play for the new row", listOf("b"), glide.histories)
        assertEquals(normal.verdicts, glide.verdicts)
        assertEquals(listOf("a" to false), glide.verdicts)
        assertEquals(normal.log, glide.log)
        assertEquals(normal.seq, glide.seq)
        assertEquals(normal.gen, glide.gen)
    }

    @Test
    fun handleEnded_thenAdvanceWithoutLoad_countsTheNaturalEndOnce() = runTest {
        val h = harness("a", "b")
        val verdicts = mutableListOf<String>()
        h.seq.outcomes = registry { id, _ -> verdicts += id }
        h.seq.addAdvanceInterceptor(NaturalEndClaimer(1, true))
        h.seq.play(rows("a", "b")); h.settle()
        h.seq.handleEnded("a")
        h.seq.advanceWithoutLoad(AdvanceCause.NATURAL_END); h.settle()
        assertEquals(listOf("a"), verdicts)
    }

    @Test
    fun advanceWithoutLoad_resetsRepeatCounter_toTheNewRow() = runTest {
        val h = harness("a", "b")
        val items = listOf(QueueItem("a"), QueueItem("b", repeatCount = 2))
        h.seq.addAdvanceInterceptor(NaturalEndClaimer(1, true))
        h.seq.play(items); h.settle()
        h.seq.handleEnded("a")
        h.seq.advanceWithoutLoad(AdvanceCause.NATURAL_END); h.settle()
        // b plays twice: its first end replays in place (a load-less port.replay), its second end finishes the set
        h.seq.handleEnded("b"); h.settle()
        assertTrue("b is still current for its second pass", h.seq.isRunning)
        assertEquals("b", h.seq.currentSongId)
    }

    @Test
    fun advanceWithoutLoad_atEndOfSet_finishesTheRun() = runTest {
        val h = harness("a")
        val rec = Recorder().also { h.seq.hooks.add(it) }
        h.seq.play(rows("a")); h.settle()
        assertTrue(h.seq.advanceWithoutLoad(AdvanceCause.NATURAL_END)); h.settle()
        assertFalse(h.seq.isRunning)
        assertTrue(rec.events.contains("ended(FINISHED)"))
    }

    @Test
    fun advanceWithoutLoad_whenHeldOrIdle_isRefused() = runTest {
        val h = harness("a", "b")
        assertFalse(h.seq.advanceWithoutLoad())
        h.seq.restoreHeld(rows("a", "b"), 0, null, null, null, RepeatMode.OFF, false, null)
        assertFalse(h.seq.advanceWithoutLoad())
        assertEquals("a", h.seq.state.value.current?.id)
    }

    @Test
    fun advanceWithoutLoad_userCause_countsAsASkipVerdict() = runTest {
        val h = harness("a", "b")
        val verdicts = mutableListOf<Pair<String, Boolean>>()
        h.seq.outcomes = registry { id, sk -> verdicts += id to sk }
        h.seq.progressProvider = { 0.1 }
        h.seq.play(rows("a", "b")); h.settle()
        val rec = Recorder().also { h.seq.hooks.add(it) }
        h.seq.advanceWithoutLoad(AdvanceCause.USER, StartPath.DJ); h.settle()
        assertEquals("transition(USER,seq=2)", rec.events.first { it.startsWith("transition") })
        assertEquals(2L, h.seq.lastUserTransitionSeq)
        assertEquals("track(b#1,DJ,fresh=true)", rec.events.last { it.startsWith("track") })
        assertEquals("rendering=true closes the start at once", "audio(b)", rec.events.last())
        assertEquals("a USER advance-away at 10% is a skip verdict", listOf("a" to true), verdicts)
    }
}

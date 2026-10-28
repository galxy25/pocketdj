package com.levi.pocketdj.mix.nowplaying

import com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Network
import com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Step
import com.levi.pocketdj.mix.nowplaying.StemLockPrefetcher.Track
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class StemLockPrefetcherOrderTest {
    private val carry = StemLockState(enabled = true, stemsOn = true)

    private fun t(id: String, songLocal: Boolean = false, fetchable: Boolean = true, local: Set<String> = emptySet(), remote: Boolean = true) =
        Track(songId = id, audioId = id, title = id, artist = "a", songLocal = songLocal, songFetchable = fetchable, stemsLocal = local, stemsRemote = remote)

    private fun names(p: StemLockPrefetcher.Plan) = p.steps.map { it.toString() }

    @Test fun nextTrackIsSongThenVocalsDrumsOtherBass() {
        val p = StemLockPrefetcher.plan(null, listOf(t("n")), carry, Network.UNMETERED, 3)
        assertEquals(listOf("song:n", "vocals:n", "drums:n", "other:n", "bass:n"), names(p))
    }

    @Test fun localSongSkipsTheSongStepAndLocalPartsAreNotRefetched() {
        val p = StemLockPrefetcher.plan(null, listOf(t("n", songLocal = true, local = setOf("vocals"))), carry, Network.UNMETERED, 3)
        assertEquals(listOf("drums:n", "other:n", "bass:n"), names(p))
    }

    @Test fun furtherTracksFollowAndMutedPartsComeLastAcrossAllTracks() {
        val muted = carry.copy(muted = listOf("drums"))
        val p = StemLockPrefetcher.plan(null, listOf(t("a"), t("b")), muted, Network.UNMETERED, 2)
        assertEquals(
            listOf("song:a", "vocals:a", "other:a", "bass:a", "song:b", "vocals:b", "other:b", "bass:b", "drums:a", "drums:b"),
            names(p),
        )
    }

    @Test fun currentTracksMissingEnabledPartsLead() {
        val p = StemLockPrefetcher.plan(t("cur", songLocal = true, local = setOf("vocals", "drums")), listOf(t("n")), carry, Network.UNMETERED, 1)
        assertEquals(listOf("other:cur", "bass:cur", "song:n"), names(p).take(3))
    }

    @Test fun networkClassSizesThePlan() {
        val up = listOf(t("a"), t("b"))
        val muted = carry.copy(muted = listOf("bass"))
        assertEquals(10 - 0, names(StemLockPrefetcher.plan(null, up, carry, Network.UNMETERED, 2)).size)
        // cellular: next track only
        assertTrue(names(StemLockPrefetcher.plan(null, up, carry, Network.EXPENSIVE, 2)).none { it.endsWith(":b") })
        // low data: next track, muted parts skipped entirely
        assertEquals(listOf("song:a", "vocals:a", "drums:a", "other:a"), names(StemLockPrefetcher.plan(null, up, muted, Network.CONSTRAINED, 2)))
        assertEquals(emptyList<Step>(), StemLockPrefetcher.plan(null, up, carry, Network.OFFLINE, 2).steps)
    }

    @Test fun nothingPlannedUnlessTheLockWantsStems() {
        assertEquals(emptyList<Step>(), StemLockPrefetcher.plan(null, listOf(t("a")), carry.copy(stemsOn = false), Network.UNMETERED, 2).steps)
        assertEquals(emptyList<Step>(), StemLockPrefetcher.plan(null, listOf(t("a")), carry.copy(enabled = false), Network.UNMETERED, 2).steps)
    }

    @Test fun unfetchableSongIsSkippedAndNextTrackWithoutStemsGetsOneCloudRequest() {
        val p = StemLockPrefetcher.plan(null, listOf(t("a", fetchable = false, remote = false), t("b")), carry, Network.UNMETERED, 2)
        assertEquals(listOf("a"), p.stemify)
        assertEquals("song:b", names(p).first())
        assertTrue(names(p).none { it.endsWith(":a") })
    }

    // ---- the worker -------------------------------------------------------------------------

    @Test fun workerRunsStepsOneAtATimeInPlanOrder() {
        val scope = TestScope(StandardTestDispatcher())
        val pf = StemLockPrefetcher(scope, now = { scope.testScheduler.currentTime })
        val started = ArrayList<String>()
        var concurrent = 0; var maxConcurrent = 0
        pf.fetchSong = { s -> concurrent++; maxConcurrent = maxOf(maxConcurrent, concurrent); started += s.toString(); concurrent--; true }
        pf.fetchStemPart = { id, part -> concurrent++; maxConcurrent = maxOf(maxConcurrent, concurrent); started += "$part:$id"; concurrent--; true }
        pf.apply(StemLockPrefetcher.plan(null, listOf(t("n")), carry, Network.UNMETERED, 1))
        scope.advanceUntilIdle()
        assertEquals(listOf("song:n", "vocals:n", "drums:n", "other:n", "bass:n"), started)
        assertEquals(1, maxConcurrent)
        assertTrue(pf.isIdle)
    }

    @Test fun skipCancelsTheInFlightFetchTheNewPlanNoLongerWants() {
        val scope = TestScope(StandardTestDispatcher())
        val pf = StemLockPrefetcher(scope, now = { scope.testScheduler.currentTime })
        val gate = CompletableDeferred<Boolean>()
        var cancelled = false
        pf.fetchSong = { s ->
            if (s.id == "old") try { gate.await() } catch (e: kotlinx.coroutines.CancellationException) { cancelled = true; throw e } else true
        }
        pf.fetchStemPart = { _, _ -> true }
        pf.apply(StemLockPrefetcher.plan(null, listOf(t("old")), carry, Network.UNMETERED, 1))
        scope.runCurrent()
        assertEquals(Step.Song("old", "old", "a"), pf.inFlight)
        // the listener skipped: the upcoming track is now "new"
        pf.apply(StemLockPrefetcher.plan(null, listOf(t("new")), carry, Network.UNMETERED, 1))
        scope.advanceUntilIdle()
        assertTrue("old song fetch cancelled", cancelled)
        assertEquals(Step.Song("new", "new", "a"), pf.startedLog[1])
        assertTrue(pf.startedLog.none { it.toString().endsWith(":old") && it is Step.StemPart })
    }

    @Test fun replanKeepsAnInFlightFetchThatIsStillWanted() {
        val scope = TestScope(StandardTestDispatcher())
        val pf = StemLockPrefetcher(scope, now = { scope.testScheduler.currentTime })
        val gate = CompletableDeferred<Boolean>()
        var songCalls = 0
        pf.fetchSong = { s -> if (s.id == "n") songCalls++; gate.await() }
        pf.fetchStemPart = { _, _ -> true }
        pf.apply(StemLockPrefetcher.plan(null, listOf(t("n")), carry, Network.UNMETERED, 1))
        scope.runCurrent()
        pf.apply(StemLockPrefetcher.plan(null, listOf(t("n"), t("m")), carry, Network.UNMETERED, 2))
        scope.runCurrent()
        gate.complete(true)
        scope.advanceUntilIdle()
        assertEquals("not restarted", 1, songCalls)
        assertEquals("song:n", pf.startedLog.first().toString())
    }

    @Test fun cancelAllStopsEverythingAndFailureCoolsDown() {
        val scope = TestScope(StandardTestDispatcher())
        var clock = 0L
        val pf = StemLockPrefetcher(scope, now = { clock })
        var fails = 0
        pf.fetchSong = { fails++; false }
        pf.fetchStemPart = { _, _ -> true }
        val plan = StemLockPrefetcher.plan(null, listOf(t("n")), carry, Network.UNMETERED, 1)
        pf.apply(plan); scope.advanceUntilIdle()
        assertEquals(1, fails)
        pf.apply(plan); scope.advanceUntilIdle()
        assertEquals("inside the cooldown the failed song is not retried", 1, fails)
        clock += pf.failureCooldownMs
        pf.apply(plan); scope.advanceUntilIdle()
        assertEquals(2, fails)
        pf.cancelAll()
        assertTrue(pf.isIdle)
    }

    @Test fun stemifyIsRequestedOncePerSong() {
        val scope = TestScope(StandardTestDispatcher())
        val pf = StemLockPrefetcher(scope)
        val asked = ArrayList<String>()
        pf.requestStemify = { asked += it }
        val plan = StemLockPrefetcher.plan(null, listOf(t("n", remote = false)), carry, Network.UNMETERED, 1)
        pf.apply(plan); pf.apply(plan)
        assertEquals(listOf("n"), asked)
    }
}

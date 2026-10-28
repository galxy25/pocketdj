package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.stems.StemJob
import com.levi.pocketdj.data.stems.StemPhase
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class StemJobsTrackerTest {
    private class Env(scope: kotlinx.coroutines.CoroutineScope, phases: List<StemPhase>, stemmed: MutableSet<String> = mutableSetOf()) {
        val requests = mutableListOf<String>()
        var fetches = 0
        var refreshes = 0
        val stemmed = stemmed
        val tracker = RipJobTracker(
            scope, fetchJob = { RipJob("queued", it) }, refreshManifest = { refreshes++ },
            requestStemify = { id -> requests += id; StemJob(phase = StemPhase.QUEUED, jobId = "j", songId = id) },
            fetchStemJob = { StemJob(phase = phases[minOf(fetches++, phases.size - 1)], jobId = it) },
            isStemmed = { it in stemmed }, stemPollMs = 1_000,
        )
    }

    @Test fun pollKeepsGoingThroughWorkPhasesAndStopsOnReady() = runTest {
        val e = Env(backgroundScope, listOf(StemPhase.QUEUED, StemPhase.RIPPING, StemPhase.STEMMING, StemPhase.READY))
        e.tracker.stemify("a")
        advanceTimeBy(3_500)
        assertEquals(3, e.fetches); assertEquals(0, e.refreshes)
        assertEquals(StemPhase.STEMMING, e.tracker.stemJobs.value["a"]?.phase)
        advanceTimeBy(1_000)
        assertEquals(4, e.fetches); assertEquals(1, e.refreshes)
        advanceTimeBy(10_000)
        assertEquals(4, e.fetches) // terminal: no more polls
    }

    @Test fun pollStopsOnErrorAndIneligibleWithoutManifestRefresh() = runTest {
        for (terminal in listOf(StemPhase.ERROR, StemPhase.INELIGIBLE)) {
            val e = Env(backgroundScope, listOf(StemPhase.STEMMING, terminal))
            e.tracker.stemify("a")
            advanceTimeBy(10_000)
            assertEquals(2, e.fetches); assertEquals(0, e.refreshes)
            assertEquals(terminal, e.tracker.stemJobs.value["a"]?.phase)
        }
    }

    @Test fun stemifyIsIdempotentAcrossThreeLayers() = runTest {
        val e = Env(backgroundScope, listOf(StemPhase.STEMMING), stemmed = mutableSetOf("done"))
        e.tracker.stemify("done")
        assertTrue(e.requests.isEmpty()) // isStemmed
        e.tracker.stemify("a"); e.tracker.stemify("a")
        assertEquals(listOf("a"), e.requests) // in-flight phase
        e.tracker.stemify("smp_1")
        assertEquals(listOf("a"), e.requests) // studio fence
    }

    @Test fun pruneDropsJobsOfStemmedSongsOnly() = runTest {
        val e = Env(backgroundScope, listOf(StemPhase.STEMMING))
        e.tracker.seedStemJob("a", "j1"); e.tracker.seedStemJob("b", "j2")
        e.stemmed += "a"
        e.tracker.pruneFinishedStemJobs()
        assertEquals(setOf("b"), e.tracker.stemJobs.value.keys)
        e.tracker.cancelStems(listOf("b"))
        assertTrue(e.tracker.stemJobs.value.isEmpty())
    }
}

package com.levi.pocketdj.data.rips

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RipJobTrackerTest {

    private fun job(phase: String, url: String? = null) = RipJob(phase = phase, jobId = "j", url = url)

    @Test
    fun ignoresErrorPhases_firesOnRipReadyOnceOnReady_andRefreshesManifest() = runTest {
        val script = ArrayDeque(listOf(job("queued"), job("error"), job("queued"), job("ready", "https://x/a.mp3")))
        var refreshes = 0
        val ready = mutableListOf<String>()
        val tracker = RipJobTracker(
            scope = backgroundScope,
            fetchJob = { script.removeFirst() },
            refreshManifest = { refreshes++ },
            pollMs = 2_000,
        )
        tracker.onRipReady = { ready += it }
        tracker.pollToReady("sng_a", "j")
        advanceTimeBy(2_000 * 3 + 1); runCurrent()
        assertTrue("error must not terminate", tracker.isPolling("sng_a"))
        assertTrue(ready.isEmpty())
        advanceTimeBy(2_000); runCurrent()
        assertEquals(listOf("sng_a"), ready)
        assertEquals(1, refreshes)
        assertFalse(tracker.isPolling("sng_a"))
        assertEquals("ready", tracker.jobs.value["sng_a"]?.phase)
        advanceTimeBy(60_000); runCurrent()
        assertEquals(1, ready.size)
    }

    @Test
    fun stopsAtTheCap_withoutFiringReady() = runTest {
        var fetches = 0
        val ready = mutableListOf<String>()
        val tracker = RipJobTracker(
            scope = backgroundScope,
            fetchJob = { fetches++; job("error") },
            pollMs = 2_000,
            maxTries = 1_800,
        )
        tracker.onRipReady = { ready += it }
        tracker.pollToReady("s", "j")
        advanceTimeBy(2_000L * 1_800 + 10_000); runCurrent()
        assertEquals(1_800, fetches)
        assertTrue(ready.isEmpty())
        assertFalse(tracker.isPolling("s"))
    }

    @Test
    fun transientFetchFailuresAreSkipped_andOnePollPerSong() = runTest {
        var n = 0
        val ready = mutableListOf<String>()
        val tracker = RipJobTracker(
            scope = backgroundScope,
            fetchJob = {
                n++
                if (n < 3) throw RipServerClient.RipServerException(null, "down")
                job("ready", "https://x")
            },
            pollMs = 1_000,
        )
        tracker.onRipReady = { ready += it }
        val a = tracker.pollToReady("s", "j")
        val b = tracker.pollToReady("s", "j")
        assertTrue(a === b)
        advanceTimeBy(3_500); runCurrent()
        assertEquals(listOf("s"), ready)
    }

    @Test
    fun userRequestedIds_areRemembered() = runTest {
        val tracker = RipJobTracker(backgroundScope, fetchJob = { job("queued") })
        tracker.markUserRequested(listOf("a"))
        assertTrue(tracker.isUserRequestedRip("a"))
        assertFalse(tracker.isUserRequestedRip("b"))
    }
}

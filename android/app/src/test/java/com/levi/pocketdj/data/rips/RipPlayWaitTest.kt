package com.levi.pocketdj.data.rips

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RipPlayWaitTest {
    private fun tracker(scope: kotlinx.coroutines.CoroutineScope) =
        RipJobTracker(scope, fetchJob = { RipJob(phase = "queued", jobId = it) }, pollMs = 1_000)

    @Test
    fun stillRipping_handsJobToTracker() = runTest {
        val t = tracker(backgroundScope)
        val wait = RipPlayWait({ RipWaitOutcome.StillRipping(it) }, {}, { null }, t)
        assertEquals(RipPlayWait.Result.StillRipping, wait.run("sng_a", "j1") { true })
        assertTrue(t.isPolling("sng_a"))
    }

    @Test
    fun ready_playsPresignedUrlOverDirect() = runTest {
        var refreshed = 0
        val wait = RipPlayWait({ RipWaitOutcome.Ready("https://direct") }, { refreshed++ }, { "https://signed" }, null)
        assertEquals(RipPlayWait.Result.Play("https://signed"), wait.run("a", "j") { true })
        assertEquals(1, refreshed)
        val noSign = RipPlayWait({ RipWaitOutcome.Ready("https://direct") }, {}, { null }, null)
        assertEquals(RipPlayWait.Result.Play("https://direct"), noSign.run("a", "j") { true })
    }

    @Test
    fun readyAfterUserPlayedSomethingElse_refreshesButNeverPlays() = runTest {
        var refreshed = 0
        var current = true
        val wait = RipPlayWait(
            { current = false; RipWaitOutcome.Ready("https://direct") }, // user taps song B mid-wait
            { refreshed++ }, { "https://signed" }, null,
        )
        assertEquals(RipPlayWait.Result.Superseded, wait.run("a", "j") { current })
        assertEquals(1, refreshed)
    }

    @Test
    fun cancelRemovesPollAndUserProtection() = runTest {
        val t = tracker(backgroundScope)
        t.markUserRequested(listOf("a"))
        t.pollToReady("a", "j")
        t.cancel(listOf("a"))
        assertFalse(t.isPolling("a"))
        assertFalse(t.isUserRequestedRip("a"))
    }
}

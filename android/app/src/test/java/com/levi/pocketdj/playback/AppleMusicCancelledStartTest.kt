package com.levi.pocketdj.playback

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** FR1: a superseded Apple Music start stops the SDK, restores the backend, and never claims the session. */
@OptIn(ExperimentalCoroutinesApi::class)
class AppleMusicCancelledStartTest {
    /** Models SDK + backend + adapter: prepare(playWhenReady) is async; PLAYING claims the session unless stopped. */
    private class FakeSdk {
        val confirm = CompletableDeferred<Boolean>()
        var stops = 0
        var pending = false
        var claimed = false
        var activeBackend = "EXO"

        suspend fun play(): Boolean {
            pending = true // prepare(provider, playWhenReady = true)
            return confirm.await()
        }

        /** The SDK reaching PLAYING later: the adapter claims the session only if nothing stopped it. */
        fun reachPlaying() { if (pending) claimed = true }

        fun abort() { stops++; pending = false }
    }

    @Test
    fun cancelWhileConfirmPending_stopsSdkOnce_noClaim_priorBackendRestored() = runTest {
        val sdk = FakeSdk()
        sdk.activeBackend = "APPLE_MUSIC"
        val job = async(start = CoroutineStart.UNDISPATCHED) {
            runCancellableAppleMusicStart(play = { sdk.play() }, abort = { sdk.abort(); sdk.activeBackend = "EXO" })
        }
        runCurrent()
        assertTrue(sdk.pending)
        job.cancelAndJoin()
        sdk.reachPlaying() // the stalled song finally buffers - after the hop target took over
        assertEquals(1, sdk.stops)
        assertFalse("the superseded song must never claim the session", sdk.claimed)
        assertEquals("EXO", sdk.activeBackend)
        assertTrue(job.isCancelled)
    }

    @Test
    fun cancellationIsRethrown_notSwallowedIntoFalse() = runTest {
        val sdk = FakeSdk()
        val job = async(start = CoroutineStart.UNDISPATCHED) {
            runCancellableAppleMusicStart(play = { sdk.play() }, abort = { sdk.abort() })
        }
        job.cancel()
        val r = runCatching { job.await() }
        assertTrue(r.exceptionOrNull() is kotlinx.coroutines.CancellationException)
    }

    @Test
    fun abortRunsEvenThoughTheScopeIsCancelled_nonCancellable() = runTest {
        var cleaned = false
        val job = async(start = CoroutineStart.UNDISPATCHED) {
            runCancellableAppleMusicStart(
                play = { CompletableDeferred<Boolean>().await() },
                abort = { kotlinx.coroutines.yield(); cleaned = true },
            )
        }
        job.cancelAndJoin()
        assertTrue(cleaned)
    }

    @Test
    fun uncancelledFailureIsFalse_andNoAbort_andSuccessPassesThrough() = runTest {
        var aborted = 0
        assertFalse(runCancellableAppleMusicStart(play = { error("sdk") }, abort = { aborted++ }))
        assertTrue(runCancellableAppleMusicStart(play = { true }, abort = { aborted++ }))
        assertFalse(runCancellableAppleMusicStart(play = { false }, abort = { aborted++ }))
        assertEquals(0, aborted)
    }

    @Test
    fun controllerRestore_runsEvenWhenSdkAbortAlreadyHappened_exoPrior() = runTest {
        var backend = PlaybackController.ActiveBackend.APPLE_MUSIC
        var amId: String? = "am1"
        var exoResumed = 0
        // SDK-level abort already ran inside play(); the controller restore must not depend on it.
        restoreAfterCancelledAmStart(true, PlaybackController.ActiveBackend.EXO, { amId = null }, { backend = it }, { exoResumed++ })
        assertEquals(PlaybackController.ActiveBackend.EXO, backend)
        assertEquals(null, amId)
        assertEquals(1, exoResumed)
    }

    @Test
    fun controllerRestore_supersededStartLeavesStateAlone() = runTest {
        var backend = PlaybackController.ActiveBackend.APPLE_MUSIC
        var touched = false
        restoreAfterCancelledAmStart(false, PlaybackController.ActiveBackend.EXO, { touched = true }, { backend = it }, { touched = true })
        assertEquals(PlaybackController.ActiveBackend.APPLE_MUSIC, backend)
        assertFalse(touched)
    }

    @Test
    fun controllerRestore_amPrior_noExoResume() = runTest {
        var exoResumed = 0
        var backend = PlaybackController.ActiveBackend.APPLE_MUSIC
        restoreAfterCancelledAmStart(true, PlaybackController.ActiveBackend.APPLE_MUSIC, {}, { backend = it }, { exoResumed++ })
        assertEquals(0, exoResumed)
        assertEquals(PlaybackController.ActiveBackend.APPLE_MUSIC, backend)
    }
}

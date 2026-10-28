package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexSong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@Suppress("UNCHECKED_CAST")
private inline fun <reified T> assertIs(v: Any?): T {
    assertTrue("expected ${T::class.simpleName} but was $v", v is T)
    return v as T
}

@OptIn(ExperimentalCoroutinesApi::class)
class ShazamRecognizerTest {
    private fun hit() = ShazamHitInfo("Track", "X", null, "123")

    @Test fun matchedPhaseResolvesAgainstCatalog() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val r = ShazamRecognizer(scope, { RecognitionResult.Hit(hit()) }, { true },
            songs = { listOf(IndexSong(id = "s1", artist = "X", name = "Track")) })
        r.start()
        assertIs<ShazamMatch.InCatalog>(assertIs<ShazamPhase.Matched>(r.phase.value).match)
    }

    @Test fun permissionDeniedGoesToDeniedAndTapOpensSettings() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val r = ShazamRecognizer(scope, { RecognitionResult.NoMatch }, { false }, songs = { emptyList() })
        assertEquals(ShazamTap.STARTED, r.tap())
        assertEquals(ShazamPhase.Denied, r.phase.value)
        assertEquals(ShazamTap.OPEN_SETTINGS, r.tap())
    }

    @Test fun secondTapWhileListeningCancels() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val gate = CompletableDeferred<RecognitionResult>()
        val r = ShazamRecognizer(scope, { gate.await() }, { true }, songs = { emptyList() }, recognizingAfterMs = 10_000)
        assertEquals(ShazamTap.STARTED, r.tap())
        assertEquals(ShazamPhase.Listening, r.phase.value)
        assertEquals(ShazamTap.CANCELLED, r.tap())
        assertEquals(ShazamPhase.Idle, r.phase.value)
        gate.complete(RecognitionResult.NoMatch) // a late result must not resurrect a cancelled run
        assertEquals(ShazamPhase.Idle, r.phase.value)
    }

    @Test fun movesToRecognizingThenNoMatch() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val gate = CompletableDeferred<RecognitionResult>()
        val r = ShazamRecognizer(scope, { gate.await() }, { true }, songs = { emptyList() }, recognizingAfterMs = 600)
        r.start()
        scope.testScheduler.advanceTimeBy(601)
        assertEquals(ShazamPhase.Recognizing, r.phase.value)
        gate.complete(RecognitionResult.NoMatch)
        assertEquals(ShazamPhase.NoMatch, r.phase.value)
    }

    @Test fun gatedWhileMixRecording() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        var recording = true
        val r = ShazamRecognizer(scope, { RecognitionResult.NoMatch }, { true }, songs = { emptyList() }, blocked = { recording })
        assertEquals(ShazamTap.BLOCKED, r.tap())
        assertEquals(ShazamPhase.Idle, r.phase.value)
        recording = false
        assertEquals(ShazamTap.STARTED, r.tap())
        assertTrue(r.phase.value is ShazamPhase.NoMatch)
    }

    @Test fun backendErrorFails() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        val r = ShazamRecognizer(scope, { RecognitionResult.Error("boom") }, { true }, songs = { emptyList() })
        r.start()
        assertEquals(ShazamPhase.Failed("boom"), r.phase.value)
        r.reset()
        assertEquals(ShazamPhase.Idle, r.phase.value)
    }

    @Test fun deniedThenGrantedInSettingsRecoversOnTap() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        var granted = false
        val perm = object : MicPermission {
            override suspend fun ensureGranted() = granted
            override fun isGrantedNow() = granted
        }
        val r = ShazamRecognizer(scope, { RecognitionResult.NoMatch }, perm, songs = { emptyList() })
        assertEquals(ShazamTap.STARTED, r.tap())
        assertEquals(ShazamPhase.Denied, r.phase.value)
        assertEquals(ShazamTap.OPEN_SETTINGS, r.tap()) // still denied
        granted = true // user flipped the mic on in App info
        assertEquals(ShazamTap.STARTED, r.tap())
        assertEquals(ShazamPhase.NoMatch, r.phase.value)
    }

    @Test fun unavailableBackendFailsBeforeAskingForTheMic() = runTest {
        val scope = TestScope(UnconfinedTestDispatcher(testScheduler))
        var asked = false
        val r = ShazamRecognizer(scope, UnavailableRecognitionBackend, { asked = true; true }, songs = { emptyList() })
        assertEquals(false, UnavailableRecognitionBackend.isAvailable)
        r.tap()
        assertEquals(ShazamPhase.Failed(UNAVAILABLE_MESSAGE), r.phase.value)
        assertEquals(false, asked)
    }
}

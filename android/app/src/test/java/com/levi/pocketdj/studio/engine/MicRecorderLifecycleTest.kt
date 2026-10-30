package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MicRecorderLifecycleTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun readErrorMidTakeFilesTheTakeAndStopNeverHangs() = runBlocking {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val rec = MicRecorder(env.roots, store, audioManager = null)
        assertTrue(rec.beginTake())
        assertTrue(rec.isRecording.value)
        // The capture thread dies with a read error (ERROR_DEAD_OBJECT) while still recording.
        rec.onCaptureEnded(readError = true)
        assertFalse(rec.isRecording.value)
        assertNotNull(rec.writerFailureMessage.value)
        assertEquals(1, store.samples.size)
        assertEquals(StudioSource.Mic, store.samples[0].source)
        // Stop afterwards must return immediately (nothing left to finalize), never suspend forever.
        withTimeout(2000) { assertNull(rec.stopAwaitingFinalize()) }
    }

    @Test fun stopWithADeadCaptureThreadStillFinalizes() = runBlocking {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val rec = MicRecorder(env.roots, store, audioManager = null)
        assertTrue(rec.beginTake())
        // No capture thread exists (it died): stop must close the writer and complete without the 3 s timeout.
        val t0 = System.currentTimeMillis()
        val take = withTimeout(2500) { rec.stopAwaitingFinalize() }
        assertNotNull(take)
        assertTrue(System.currentTimeMillis() - t0 < 2000)
        assertFalse(rec.isRecording.value)
    }

    @Test fun stallWatchdogFiresWithoutAnyBuffersArriving() {
        val env = TestEnv(tmp.newFolder())
        val rec = MicRecorder(env.roots, env.store(), audioManager = null)
        assertTrue(rec.beginTake())
        // Ticks come from the independent timer, not from read(): no appended audio => stall after 5 s.
        var now = System.nanoTime() / 1e9 + 1000.0
        repeat(14) { rec.watchdogTick(now); now += 0.5 }
        assertTrue(rec.captureStalled.value)
        rec.stop()
    }

    @Test fun takeIsFinalizedInAppStorageThenRelocatedToTheUserFolder() {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        env.configured += StudioFamily.SAMPLES
        val rec = MicRecorder(env.roots, store, audioManager = null)
        assertTrue(rec.beginTake())
        // While recording the crash-safe file is in APP storage, never the user folder.
        val name = env.roots.appDir(StudioFamily.SAMPLES).list().single()
        assertTrue(env.appFile(StudioFamily.SAMPLES, name).isFile)
        assertFalse(env.userFile(StudioFamily.SAMPLES, name).exists())
        rec.finalizeForExit()
        val s = store.samples.single()
        assertEquals(name, s.fileName)
        assertTrue(s.wasUserFolder)
        assertTrue(env.userFile(StudioFamily.SAMPLES, name).isFile)
        assertFalse(env.appFile(StudioFamily.SAMPLES, name).exists())
    }

    @Test fun takeStaysInAppStorageWhenTheFolderIsRevokedAtFileTime() {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        env.configured += StudioFamily.SAMPLES
        val rec = MicRecorder(env.roots, store, audioManager = null)
        assertTrue(rec.beginTake())
        env.unreachable += StudioFamily.SAMPLES      // permission revoked mid-take
        rec.finalizeForExit()
        val s = store.samples.single()
        assertFalse(s.wasUserFolder)
        assertTrue(env.appFile(StudioFamily.SAMPLES, s.fileName).isFile)
        assertNotNull(store.samplesFolderNotice.value)
    }

    @Test fun pendingNameIsUsedWhenATakeIsFiledOnExit() {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val rec = MicRecorder(env.roots, store, audioManager = null)
        assertTrue(rec.beginTake())
        rec.pendingName = "Snare hit"
        rec.finalizeForExit()
        assertEquals("Snare hit", store.samples.single().name)
    }

    @Test fun activeTakeIsExposedForResetGuard() {
        val env = TestEnv(tmp.newFolder())
        val rec = MicRecorder(env.roots, env.store(), audioManager = null)
        assertNull(rec.activeTake)
        assertTrue(rec.beginTake())
        assertNotNull(rec.activeTake)
        rec.stop()
    }
}

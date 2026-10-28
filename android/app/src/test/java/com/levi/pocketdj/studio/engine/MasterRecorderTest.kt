package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.core.WavWriter
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioChannelStrip
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioTrack
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class MasterRecorderTest {
    @get:Rule val tmp = TemporaryFolder()
    private var n = 0
    private fun recorder() = MasterRecorder(tempDir = { tmp.root }, newName = { "rec-${n++}.wav" }, log = {})
    private fun block(frames: Int, v: Float) = FloatArray(frames * 2) { v }

    @Test fun manualStopDoesNotBumpTheNonceButKeepsTheCapture() {
        val r = recorder()
        assertTrue(r.begin(true, 44_100, false))
        assertTrue(r.isRecording)
        r.tap(block(100, 0.25f), 100); r.tap(block(50, -0.5f), 50)
        r.end(naturalEnd = false)
        assertFalse(r.isRecording)
        assertEquals(0, r.finishedNonce.value)
        val cap = r.consume()!!
        val pcm = MasterWav.read(cap.file)!!
        assertEquals(150, pcm.frames)
        assertEquals(0.25f, pcm.samples[0], 0f); assertEquals(-0.5f, pcm.samples[2 * 100], 0f)
        assertNull(r.consume())                 // handed out exactly once
    }

    @Test fun naturalEndBumpsTheNonceExactlyOnceAndOnlyWhenRecording() {
        val r = recorder()
        r.end(naturalEnd = true)                // nothing active: no bake signal
        assertEquals(0, r.finishedNonce.value)
        r.begin(true, 44_100, false); r.tap(block(10, 0.1f), 10)
        r.end(naturalEnd = true)
        assertEquals(1, r.finishedNonce.value)
        r.end(naturalEnd = true)                // a second stop (the player stops twice) must not re-bump
        assertEquals(1, r.finishedNonce.value)
        assertNotNull(r.consume())
    }

    @Test fun nonRecordingPlayNeverBumpsTheNonce() {
        val r = recorder()
        r.begin(false, 44_100, false); r.tap(block(10, 0.1f), 10)
        r.end(naturalEnd = true)
        assertEquals(0, r.finishedNonce.value); assertFalse(r.isRecording); assertNull(r.consume())
    }

    @Test fun restartKeepsRecordingAndDeletesThePreviousPartial() {
        val r = recorder()
        r.begin(true, 44_100, false); r.tap(block(100, 0.9f), 100)
        r.end(false)                             // player.stop() inside a seek/loop restart
        val first = File(tmp.root, "rec-0.wav")
        assertTrue(first.exists())
        r.begin(true, 44_100, false)             // ... then the new pass starts recording again
        assertFalse("leftover partial must be deleted", first.exists())
        r.tap(block(40, 0.3f), 40)
        assertTrue(r.isRecording)
        r.end(naturalEnd = true)
        assertEquals(1, r.finishedNonce.value)
        val pcm = MasterWav.read(r.consume()!!.file)!!
        assertEquals(40, pcm.frames)             // only the second pass, not concatenated
        assertEquals(0.3f, pcm.samples[0], 0f)
    }

    @Test fun beginWhileStillRecordingAlsoDiscardsTheActivePartial() {
        val r = recorder()
        r.begin(true, 44_100, false); r.tap(block(10, 0.5f), 10)
        r.begin(true, 44_100, false)
        assertFalse(File(tmp.root, "rec-0.wav").exists())
        r.discard()
        assertFalse(File(tmp.root, "rec-1.wav").exists())
        assertFalse(r.isRecording)
    }

    @Test fun aNonRecordBeginDropsAnUnconsumedLeftover() {
        val r = recorder()
        r.begin(true, 44_100, false); r.tap(block(10, 0.5f), 10); r.end(false)
        r.begin(false, 44_100, false)
        assertFalse(File(tmp.root, "rec-0.wav").exists()); assertNull(r.consume())
    }

    @Test fun captureWavCarriesTheCanonicalSampleRateAndWallClockDuration() {
        // Device-only on hardware, but the invariant is checkable here: header rate == canonical, duration == frames / rate.
        val r = recorder()
        r.begin(true, StudioAudio.CANONICAL_RATE, false)
        repeat(86) { r.tap(block(512, 0.1f), 512) }
        r.end(false)
        val cap = r.consume()!!
        val info = WavWriter.parse(cap.file.readBytes())!!
        assertEquals(StudioAudio.CANONICAL_RATE, info.sampleRate)
        assertEquals(86 * 512L * 2 * 4, info.dataBytes)
        assertEquals(86 * 512 / 44_100.0, MasterWav.read(cap.file)!!.seconds, 1e-9)
    }

    @Test fun tapAfterEndIsIgnored() {
        val r = recorder()
        r.begin(true, 44_100, false); r.tap(block(10, 0.5f), 10); r.end(false)
        r.tap(block(10, 0.9f), 10)               // a late block from a sink still draining
        assertEquals(10, MasterWav.read(r.consume()!!.file)!!.frames)
    }

    @Test fun cleanResamplesAHardwareRateCaptureButQuantizedRelabelsIt() {
        val baker = MasterRecordingBaker()
        fun cap(quantized: Boolean): MasterCapture {
            val f = tmp.newFile()
            WavWriter.write(f, PcmBuffer(48_000, 2, FloatArray(4800 * 2) { 0.2f }), WavWriter.Format.FLOAT32)
            return MasterCapture(f, 48_000, quantized)
        }
        val clean = baker.toCanonical(cap(false))!!
        assertEquals(StudioAudio.CANONICAL_RATE, clean.sampleRate)
        assertEquals(Math.ceil(4800 * 44_100 / 48_000.0).toInt(), clean.frames)    // pitch-correct: 100 ms stays 100 ms
        val lofi = baker.toCanonical(cap(true))!!
        assertEquals(StudioAudio.CANONICAL_RATE, lofi.sampleRate)
        assertEquals(4800, lofi.frames)                                             // relabeled, NOT resampled (plays slower)
    }

    @Test fun bakeFilesADatedRecordingArtifactAndDeletesTheTempWav() {
        val env = TestEnv(tmp.newFolder("studio"))
        val store = env.store()
        val a = store.createArrangement("A")
        val wav = tmp.newFile("cap.wav")
        WavWriter.write(wav, PcmBuffer(44_100, 2, FloatArray(44_100 * 2) { 0.2f }), WavWriter.Format.FLOAT32)
        val baker = MasterRecordingBaker(writeM4a = { _, f -> f.writeText("m4a") })
        val art = baker.bakeArtifact(a.id, MasterCapture(wav, 44_100, false), env.roots.arrangementsDir(), store, "2026-10-28 10-00-00", now = 7.0)!!
        assertEquals("live-recording-2026-10-28 10-00-00.m4a", art.fileName)
        assertEquals(StudioArrangementArtifact.Kind.RECORDING, art.kind)
        assertEquals(1000, art.durationMs)
        assertTrue(File(env.roots.arrangementsDir(), art.fileName).exists())
        assertFalse(wav.exists())
        assertEquals(listOf(art.id), store.artifacts(a.id, StudioArrangementArtifact.Kind.RECORDING).map { it.id })
        // Encoder failure: no artifact, no stray file, temp still cleaned.
        val wav2 = tmp.newFile("cap2.wav")
        WavWriter.write(wav2, PcmBuffer(44_100, 2, FloatArray(200) { 0.2f }), WavWriter.Format.FLOAT32)
        val bad = MasterRecordingBaker(writeM4a = { _, _ -> error("boom") })
        assertNull(bad.bakeArtifact(a.id, MasterCapture(wav2, 44_100, false), env.roots.arrangementsDir(), store, "z"))
        assertFalse(wav2.exists())
        assertEquals(1, store.artifacts(a.id, StudioArrangementArtifact.Kind.RECORDING).size)
    }

    // ---- through the real MultitrackPlayer ----

    private val scope = CoroutineScope(Dispatchers.Default)
    @After fun tearDown() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel() }

    private class Loader : MultitrackClipLoader {
        override suspend fun decode(fileName: String) = PcmBuffer(44_100, 2, FloatArray(4410 * 2) { 0.25f })
        override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? = null
    }

    private fun arr(strip: StudioChannelStrip = StudioChannelStrip()) = StudioArrangement(
        "A", "A", listOf(StudioTrack("t1", "t1", listOf(StudioClip("c1", "c1", "f", startMs = 0, durationMs = 100)), strip = strip)),
    )

    private fun player(sinks: MutableList<FakeSink>, rec: MasterRecorder, debounce: Long = 30) =
        MultitrackPlayer(Loader(), { FakeSink().also { sinks += it } }, scope, reprimeDebounceMs = debounce, recorder = rec)

    @Test fun playerTapsThePostLimiterMasterAndOnlyANaturalEndBumpsTheNonce() = runBlocking {
        val rec = recorder(); val sinks = mutableListOf<FakeSink>()
        val p = player(sinks, rec)
        assertEquals(PlayOutcome.STARTED, p.playOutcome(arr(), record = true))
        assertTrue(p.isRecording)
        val heard = sinks[0].pull(1024)
        p.stop()                                           // manual stop
        assertEquals(0, p.recordingFinishedNonce.value)
        val pcm = MasterWav.read(p.consumeRecording()!!.file)!!
        assertEquals(1024, pcm.frames)
        for (i in 0 until 1024 * 2) assertEquals(heard[i], pcm.samples[i], 0f)    // what you heard, bit for bit

        // Natural end: let the auto-stop fire.
        assertEquals(PlayOutcome.STARTED, p.playOutcome(arr(), record = true))
        sinks[1].pull(512)
        val deadline = System.currentTimeMillis() + 5_000
        while (p.recordingFinishedNonce.value == 0 && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertEquals(1, p.recordingFinishedNonce.value)
        assertFalse(p.isPlaying.value)
        assertNotNull(p.consumeRecording())
    }

    @Test fun seekRestartKeepsRecordingWithoutBakingAndDropsTheOldPartial() = runBlocking {
        val rec = recorder(); val sinks = mutableListOf<FakeSink>()
        val p = player(sinks, rec)
        p.playOutcome(arr(), record = true); sinks[0].pull(256)
        p.playOutcome(arr(), fromMs = 50, record = true)    // ruler seek restarts playback
        assertTrue(p.isRecording)
        assertEquals(0, p.recordingFinishedNonce.value)     // a restart must not look like a finished take
        assertFalse(File(tmp.root, "rec-0.wav").exists())   // the first partial is gone
        sinks[1].pull(128)
        p.stop()
        assertEquals(128, MasterWav.read(p.consumeRecording()!!.file)!!.frames)
    }

    @Test fun bakeAffectingEditRestartsPlaybackAndKeepsTheRecording() = runBlocking {
        val rec = recorder(); val sinks = mutableListOf<FakeSink>()
        val p = player(sinks, rec)
        p.playOutcome(arr(), record = true); sinks[0].pull(64)
        p.onArrangementChanged(arr(StudioChannelStrip(pitchSemitones = 3.0)))   // debounced re-prime
        val deadline = System.currentTimeMillis() + 5_000
        while (sinks.size < 2 && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertEquals(2, sinks.size)
        assertTrue("re-prime must keep recording", p.isRecording)
        assertEquals(0, p.recordingFinishedNonce.value)
        p.stop()
    }

    @Test fun aPlainPlayDoesNotRecord() = runBlocking {
        val rec = recorder(); val sinks = mutableListOf<FakeSink>()
        val p = player(sinks, rec)
        p.playOutcome(arr())
        sinks[0].pull(64)
        assertFalse(p.isRecording); p.stop(); assertNull(p.consumeRecording())
    }
}

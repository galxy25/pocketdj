package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.LocalSource
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.demux.BeatMath
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SampleFactoryTest {
    @get:Rule val tmp = TemporaryFolder()

    /** A 10 s mono-ish ramp: frame i holds i / 441000, so the first written frame reveals the carve offset. */
    private val ramp = PcmBuffer(44_100, 2, FloatArray(441_000 * 2) { (it / 2) / 441_000f })

    private class Codec(val src: PcmBuffer, val drm: Boolean = false) : StudioCodec {
        var written: PcmBuffer? = null
        override fun decode(path: String) = src
        override fun decodeNativeRate(path: String) = src
        override fun isProtected(path: String) = drm
        override fun writeM4a(pcm: PcmBuffer, file: File) { written = pcm; file.writeText("m4a") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    private fun setup(codec: Codec): Triple<TestEnv, SampleFactory, com.levi.pocketdj.studio.store.StudioStore> {
        val env = TestEnv(tmp.newFolder())
        val store = env.store()
        val f = SampleFactory(env.roots, store, StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { }), now = { 5.0 })
        return Triple(env, f, store)
    }

    @Test fun importFilesASampleNamedWithoutExtension() = runBlocking {
        val (env, f, store) = setup(Codec(ramp))
        val s = f.importFile(File("x.wav"), "My Loop.wav")
        assertEquals("My Loop", s.name)
        assertEquals(StudioSource.File("My Loop.wav"), s.source)
        assertEquals(10_000, s.durationMs)
        assertTrue(env.appFile(StudioFamily.SAMPLES, s.fileName).isFile)
        assertNotNull(store.sample(s.id))
        assertEquals("Imported sample", f.importName(".wav"))
    }

    @Test fun drmProtectedImportIsRejectedAndLeavesNothingBehind() = runBlocking {
        val (env, f, store) = setup(Codec(ramp, drm = true))
        try { f.importFile(File("x.m4p"), "Song.m4p"); fail("expected rejection") }
        catch (e: SampleFileException) { assertEquals(SampleFileFailure.Protected, e.failure) }
        assertTrue(store.samples.isEmpty())
        assertEquals(0, File(env.base, "app/samples").list()?.size ?: 0)
    }

    @Test fun unreadableImportIsRejected() = runBlocking {
        val codec = object : StudioCodec {
            override fun decode(path: String): PcmBuffer? = null
            override fun decodeNativeRate(path: String): PcmBuffer? = null
            override fun isProtected(path: String) = false
            override fun writeM4a(pcm: PcmBuffer, file: File) {}
            override fun writeWav(pcm: PcmBuffer, file: File) {}
        }
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val f = SampleFactory(env.roots, store, StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { }))
        try { f.importFile(File("x"), "x.mp3"); fail() } catch (e: SampleFileException) { assertEquals(SampleFileFailure.Unreadable, e.failure) }
        assertTrue(store.samples.isEmpty())
    }

    @Test fun digitalCarveStartsAtTheRegionAndRecordsProvenance() = runBlocking {
        val codec = Codec(ramp)
        val (_, f, store) = setup(codec)
        val s = f.carveTrack("sng_1", "Song", LocalSource(File("a.mp3"), isCut = false, offsetMs = 0), 2000, 3000, StudioGrid(120.0))
        assertEquals(StudioSource.Track("sng_1", 2000, 3000), s.source)
        assertEquals(1000, s.durationMs)
        assertEquals(2000 / 10000f, codec.written!!.samples[0], 1e-4f)
        assertEquals(StudioGrid(120.0), store.sample(s.id)!!.grid)
    }

    @Test fun analogCarveStartsAtEntryStartMs() = runBlocking {
        val codec = Codec(ramp)
        val (_, f, _) = setup(codec)
        // album file; the song begins 4 s in. Region 1.0-2.0 s of the SONG = file 5.0-6.0 s.
        val s = f.carveTrack("sng_2", "Song", LocalSource(File("album.mp3"), isCut = false, offsetMs = 4000), 1000, 2000, null)
        assertEquals(5000 / 10000f, codec.written!!.samples[0], 1e-4f)
        assertEquals(StudioSource.Track("sng_2", 1000, 2000), s.source)      // provenance stays SONG-relative
        // a standalone cut already starts at the song's 0:00: the offset must NOT be applied again
        val c = Codec(ramp); val (_, f2, _) = setup(c)
        f2.carveTrack("sng_2", "Song", LocalSource(File("cut.mp3"), isCut = true, offsetMs = 4000), 1000, 2000, null)
        assertEquals(1000 / 10000f, c.written!!.samples[0], 1e-4f)
    }

    @Test fun carvedGridKeepsOnlyBeatsInsideTheRegionOffsetShifted() = runBlocking {
        val (_, f, store) = setup(Codec(ramp))
        val bg = BeatMath.inheritedGrid(
            beatsMs = (0..20).map { it * 500 }, downbeatsMs = listOf(0, 2000, 4000), sidecarBpm = 120.0,
            regionStartMs = 2250, regionEndMs = 4300, fallbackBpm = null, scalarBpm = null,
        )!!
        val grid = StudioGrid(bg.bpm, bg.firstDownbeatMs, bg.beatsMs)
        val s = f.carveTrack("sng_3", "S", LocalSource(File("a.mp3"), false, 0), 2250, 4300, grid)
        val g = store.sample(s.id)!!.grid!!
        assertEquals(listOf(250, 750, 1250, 1750), g.beatsMs)            // beats 2500..4000 minus 2250
        assertTrue(g.beatsMs.all { it in 0 until s.durationMs })          // only inside the region
        assertEquals(1750, g.firstDownbeatMs)                              // downbeat 4000 -> first kept downbeat (2000 is before the region)
        assertEquals(120.0, g.bpm, 0.0)
    }

    @Test fun carveFailureCleansUp() = runBlocking {
        val bad = object : StudioCodec {
            override fun decode(path: String): PcmBuffer? = null
            override fun decodeNativeRate(path: String): PcmBuffer? = null
            override fun isProtected(path: String) = false
            override fun writeM4a(pcm: PcmBuffer, file: File) {}
            override fun writeWav(pcm: PcmBuffer, file: File) {}
        }
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val f = SampleFactory(env.roots, store, StudioRender(bad, ResampleStretcher, Dispatchers.Unconfined, { }))
        try { f.carveTrack("s", "S", LocalSource(File("a"), false, 0), 0, 1000, null); fail() } catch (e: SampleFileException) { assertEquals(SampleFileFailure.Carve, e.failure) }
        assertTrue(store.samples.isEmpty())
    }

    // ---- orphan recovery (MicRecorder) ------------------------------------------------------------

    @Test fun orphanTakeIsFiledOnceAndNeverARenderCache() {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val id = "smp_22222222-2222-2222-2222-222222222222"
        val name = StudioFolders.fileName(StudioFamily.SAMPLES, id)
        // a killed mid-record take: header + 1.5 s of audio, never closed
        val w = WavTakeWriter(env.appFile(StudioFamily.SAMPLES, name), 44100)
        w.append(ByteArray(44100 * 3) { 3 }, 44100 * 3)
        // a derived render cache and a header-only stray must NOT be adopted
        env.appFile(StudioFamily.SAMPLES, StudioFolders.renderedSampleFileName(id, 2)).writeBytes(ByteArray(500) { 1 })
        WavTakeWriter(env.appFile(StudioFamily.SAMPLES, StudioFolders.fileName(StudioFamily.SAMPLES, "smp_33333333-3333-3333-3333-333333333333")), 44100).close()

        val rec = MicRecorder(env.roots, store, audioManager = null)
        assertEquals(1, rec.recoverOrphans())
        val s = store.sample(id)!!
        assertEquals(1500, s.durationMs)
        assertEquals(StudioSource.Mic, s.source)
        assertEquals("Recovered recording", s.name)
        assertEquals(1, store.samples.size)
        // idempotent: a second pass (and a fresh recorder) files nothing more
        assertEquals(0, rec.recoverOrphans())
        assertEquals(0, MicRecorder(env.roots, store, null).recoverOrphans())
        assertNull(store.sample("smp_33333333-3333-3333-3333-333333333333"))
        assertFalse(AudioFocusPolicy.micCaptureActive)
        w.close()
    }
}

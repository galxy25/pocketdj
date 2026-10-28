package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFileRef
import com.levi.pocketdj.studio.store.StudioPlayable
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ArrangerClipBakerTest {
    @get:Rule val tmp = TemporaryFolder()

    /** Codec whose "m4a" body records the SOURCE path, so a snapshot's provenance is checkable. */
    private class Codec(val ms: Int = 1_500, val readable: Boolean = true) : StudioCodec {
        var lastDecoded: String? = null
        override fun decode(path: String): PcmBuffer? {
            lastDecoded = path
            return if (readable) PcmBuffer(44_100, 2, FloatArray(44_100 * 2 * ms / 1000) { 0.2f }) else null
        }
        override fun decodeNativeRate(path: String) = decode(path)
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText("snapshot-of:${lastDecoded}") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    private fun baker(env: TestEnv, codec: Codec, prepare: suspend (String) -> StudioPlayable?, now: Double = 7.0,
                      materialize: suspend (StudioFileRef) -> File? = { it.file }, release: (StudioFileRef, File) -> Unit = { _, _ -> }) =
        ArrangerClipBaker(env.roots, StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { }), prepare, materialize, release, { now })

    @Test fun bakeSnapshotsTheSourceIntoTheArrangementsDirAndStaysIndependent() = runBlocking {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val src = File(env.base, "smp.m4a").also { it.writeText("original") }
        store.addSample(StudioSample("smp_1", "Kick", "smp.m4a", false))
        val b = baker(env, Codec(1_500), { id -> StudioPlayable(StudioFileRef(src, "file://x"), "Kick", 1_500).takeIf { id == "smp_1" } })
        val clip = b.bake("smp_1", StudioClipSource.SAMPLE, startMs = -250)!!
        assertEquals(0, clip.startMs)                                       // clamped
        assertEquals(1_500, clip.durationMs); assertEquals("Kick", clip.name)
        assertEquals(StudioClipSource.SAMPLE, clip.source); assertEquals("smp_1", clip.sourceId); assertEquals(7.0, clip.createdAt, 0.0)
        assertTrue(clip.id.startsWith("clip_")); assertEquals("clip-${clip.id}.m4a", clip.fileName)
        val clipFile = File(env.roots.arrangementsDir(), clip.fileName)
        assertTrue(clipFile.isFile)
        val before = clipFile.readText()
        // The source is edited and then deleted: the placed clip's audio is unchanged (immutable snapshot).
        src.writeText("edited"); store.deleteSample("smp_1"); src.delete()
        assertEquals(before, clipFile.readText()); assertTrue(clipFile.isFile)
        // And filing it under a track keeps it addressable through the store.
        val a = store.createArrangement("A"); val t = store.addTrack(a.id)!!
        store.addClip(a.id, t.id, clip)
        assertNotNull(store.clipFile(clip.fileName))
    }

    @Test fun unresolvableSourceBakesNothing() = runBlocking {
        val env = TestEnv(tmp.newFolder())
        assertNull(baker(env, Codec(), { null }).bake("ptn_gone", StudioClipSource.PATTERN, 0))
        // A SAF ref the host can't materialize also yields nothing.
        assertNull(baker(env, Codec(), { StudioPlayable(StudioFileRef(null, "content://x"), "S", 1) }).bake("smp_1", StudioClipSource.SAMPLE, 0))
        assertEquals(0, env.roots.arrangementsDir().list()?.size ?: 0)
    }

    @Test fun unreadableOrEmptySourceLeavesNoPartialClipFile() = runBlocking {
        val env = TestEnv(tmp.newFolder())
        val src = File(env.base, "s.m4a").also { it.writeText("x") }
        val play: suspend (String) -> StudioPlayable? = { StudioPlayable(StudioFileRef(src, "u"), "S", 1) }
        assertNull(baker(env, Codec(readable = false), play).bake("smp_1", StudioClipSource.SAMPLE, 0))
        assertEquals(0, env.roots.arrangementsDir().list()?.size ?: 0)
    }

    @Test fun bakeFromFileMakesARecordingClipWithNoSourceId() = runBlocking {
        val env = TestEnv(tmp.newFolder())
        val take = File(env.base, "live.wav").also { it.writeText("w") }
        val clip = baker(env, Codec(2_000), { null }).bakeFromFile(take, "Live take", 1_000)!!
        assertEquals(StudioClipSource.RECORDING, clip.source); assertNull(clip.sourceId)
        assertEquals(1_000, clip.startMs); assertEquals(2_000, clip.durationMs)
        take.delete()                                                       // the caller deletes its recording
        assertTrue(File(env.roots.arrangementsDir(), clip.fileName).isFile)
        val stem = baker(env, Codec(), { null }).bakeFromFile(File(env.base, "x"), "Drums", 0, StudioClipSource.STEM)!!
        assertEquals(StudioClipSource.STEM, stem.source)
    }

    @Test fun materializeIsReleasedEvenWhenTheBakeFails() = runBlocking {
        val env = TestEnv(tmp.newFolder())
        val tmpCopy = File(env.base, "copy.tmp").also { it.writeText("c") }
        var released = 0
        val ref = StudioFileRef(null, "content://saf/1")
        val ok = baker(env, Codec(), { StudioPlayable(ref, "S", 1) }, materialize = { tmpCopy }, release = { _, f -> released++; f.delete() })
        assertNotNull(ok.bake("smp_1", StudioClipSource.SAMPLE, 0)); assertEquals(1, released); assertFalse(tmpCopy.exists())
        tmpCopy.writeText("c")
        val bad = baker(env, Codec(readable = false), { StudioPlayable(ref, "S", 1) }, materialize = { tmpCopy }, release = { _, _ -> released++ })
        assertNull(bad.bake("smp_1", StudioClipSource.SAMPLE, 0)); assertEquals(2, released)
    }
}

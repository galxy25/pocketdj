package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import com.levi.pocketdj.studio.store.DefaultStudioRoots
import com.levi.pocketdj.studio.store.SafStat
import com.levi.pocketdj.studio.store.StudioDir
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFileRef
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioMaterializer
import com.levi.pocketdj.studio.store.StudioStore
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.OutputStream

/** A user SAF folder whose documents are `content://` refs only (no java.io.File), like a real tree. */
class SampleRenderCacheSafTest {
    @get:Rule val tmp = TemporaryFolder()

    private val docs = HashMap<String, ByteArray>()
    private var reachable = true

    private val saf = object : StudioDir {
        override val key = "content://tree"
        override fun exists(name: String) = docs.containsKey(name)
        override fun list() = docs.keys.toList()
        override fun length(name: String) = docs[name]?.size?.toLong() ?: 0L
        override fun delete(name: String) = docs.remove(name) != null
        override fun isWritable() = true
        override fun resolve(name: String) = if (docs.containsKey(name)) StudioFileRef(null, "content://tree/$name") else null
        override fun openOutput(name: String): OutputStream = object : java.io.ByteArrayOutputStream() {
            override fun close() { super.close(); docs[name] = toByteArray() }
        }
    }

    private class Codec : StudioCodec {
        val decoded = mutableListOf<String>()
        var writes = 0
        private val pcm = PcmBuffer(44_100, 1, FloatArray(44_100))
        override fun decode(path: String): PcmBuffer { decoded += File(path).readText(); return pcm }
        override fun decodeNativeRate(path: String) = pcm
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { writes++; file.writeText("m4a") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    private fun mat() = StudioMaterializer(
        tmp.newFolder("mat"),
        { u -> docs[u.substringAfterLast('/')]?.let { SafStat(it.size.toLong(), 1) } },
        { u -> if (reachable) docs[u.substringAfterLast('/')]?.let { ByteArrayInputStream(it) } else null },
    )

    @Test fun relocatedSafSampleResolvesThroughTheMaterializerForNeutralAndEditedPlayback() = runBlocking {
        val env = TestEnv(tmp.newFolder("env"))
        val roots = DefaultStudioRoots(File(env.base, "app"), userConfigured = { true }) { saf }
        val store = StudioStore(env.docFile, roots)
        val id = "smp_saf1"
        val n = env.write(StudioFamily.SAMPLES, id, bytes = 8)
        store.addSampleRelocating(StudioSample(id, "S", n, wasUserFolder = false, durationMs = 1000))
        assertTrue(store.sample(id)!!.wasUserFolder)
        assertTrue(docs.containsKey(n))

        val codec = Codec()
        val cache = SampleRenderCache(roots, store, StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { }), mat())

        // neutral edit: the materialized local COPY of the SAF document plays
        val raw = cache.playableFile(id)!!
        assertTrue(raw.isFile)
        assertEquals(docs[n]!!.size.toLong(), raw.length())
        assertEquals(StudioMaterializer.DIR_NAME, raw.parentFile!!.name)

        // edited: renders from the materialized source into the APP root cache (derived data), not the SAF folder
        store.updateSampleEdit(id, StudioSampleEdit(gainDb = -3.0))
        val shaped = cache.playableFile(id)!!
        assertEquals(StudioFolders.renderedSampleFileName(id, 1), shaped.name)
        assertEquals(1, codec.writes)
        assertNotNull(env.roots.appDir(StudioFamily.SAMPLES).resolve(shaped.name))
        assertTrue(docs.keys.none { it.contains("-r1") })
        assertEquals(raw.parentFile, cache.sourceFileAsync(store.sample(id)!!)!!.parentFile)
    }

    @Test fun unreachableSafSourceYieldsNullNotAHalfFile() = runBlocking {
        val env = TestEnv(tmp.newFolder("env"))
        val roots = DefaultStudioRoots(File(env.base, "app"), userConfigured = { true }) { saf }
        val store = StudioStore(env.docFile, roots)
        val id = "smp_saf2"
        docs[StudioFolders.fileName(StudioFamily.SAMPLES, id)] = ByteArray(8)
        store.addSample(StudioSample(id, "S", StudioFolders.fileName(StudioFamily.SAMPLES, id), wasUserFolder = true, durationMs = 1000))
        reachable = false
        val cache = SampleRenderCache(roots, store, StudioRender(Codec(), ResampleStretcher, Dispatchers.Unconfined, { }), mat())
        assertNull(cache.playableFile(id))
        assertNull(cache.sourceFileAsync(store.sample(id)!!))
    }
}

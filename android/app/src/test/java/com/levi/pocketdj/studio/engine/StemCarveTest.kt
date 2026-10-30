package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
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

class StemCarveTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun files() = StemCarve.STEMS.associateWith { File("/s/$it.mp3") }

    @Test fun canonicalOrderIsVocalsDrumsBassOther() {
        assertEquals(listOf("vocals", "drums", "bass", "other"), StemCarve.STEMS)
    }

    @Test fun availabilityIsDownloadedOrStemmedRemotely() {
        assertFalse(StemCarve.available(false, false))
        assertTrue(StemCarve.available(true, false))
        assertTrue(StemCarve.available(false, true))
    }

    @Test fun lastEnabledStemCannotBeToggledOff() {
        var e = StemCarve.allEnabled()
        e = StemCarve.toggle(e, "vocals"); e = StemCarve.toggle(e, "drums"); e = StemCarve.toggle(e, "bass")
        assertEquals(setOf("other"), e)
        assertEquals(setOf("other"), StemCarve.toggle(e, "other"))
        assertEquals(setOf("other", "drums"), StemCarve.toggle(e, "drums"))
    }

    @Test fun selectedPathsAreCanonicalOrderAndAllOrNothing() {
        assertEquals(listOf("/s/drums.mp3", "/s/other.mp3"), StemCarve.selectedPaths(files(), setOf("other", "drums")))
        assertNull(StemCarve.selectedPaths(files(), emptySet()))
        assertNull(StemCarve.selectedPaths(files() - "drums", setOf("drums", "bass")))
    }

    @Test fun sampleNameListsSubsetOrSaysStems() {
        assertEquals("Song · stems", StemCarve.sampleName("Song", StemCarve.allEnabled()))
        assertEquals("Song · drums+bass", StemCarve.sampleName("Song", setOf("bass", "drums")))
        assertEquals("Song · vocals", StemCarve.sampleName("Song", setOf("vocals")))
    }

    @Test fun resolveUsesLocalWithoutDownloading() = runBlocking {
        var downloads = 0
        val r = StemCarve.resolve({ files() }, { downloads++; null })
        assertEquals(StemCarve.Resolved.Files(files()), r)
        assertEquals(0, downloads)
    }

    @Test fun resolveDownloadsWhenNotLocalAndRejectsPartialSets() = runBlocking {
        assertEquals(StemCarve.Resolved.Files(files()), StemCarve.resolve({ null }, { files() }))
        assertEquals(StemCarve.Resolved.Failed(StemCarve.NO_STEMS), StemCarve.resolve({ null }, { null }))
        assertEquals(StemCarve.Resolved.Failed(StemCarve.NO_STEMS), StemCarve.resolve({ null }, { files() - "bass" }))
        assertEquals(StemCarve.Resolved.Failed(StemCarve.NO_STEMS), StemCarve.resolve({ null }, { throw java.io.IOException("x") }))
    }

    private class Codec(val byPath: Map<String, PcmBuffer>) : StudioCodec {
        var written: PcmBuffer? = null
        override fun decode(path: String) = byPath[path]
        override fun decodeNativeRate(path: String) = byPath[path]
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { written = pcm; file.writeText("m4a") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    private fun tone(v: Float) = PcmBuffer(44_100, 2, FloatArray(44_100 * 2 * 4) { v })

    @Test fun carveStemsSumsOnlyTheEnabledStemsAndFilesTrackProvenance() = runBlocking {
        val stems = mapOf("vocals" to File("v"), "drums" to File("d"), "bass" to File("b"), "other" to File("o"))
        val codec = Codec(mapOf("v" to tone(0.1f), "d" to tone(0.2f), "b" to tone(0.4f), "o" to tone(0.05f)))
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val f = SampleFactory(env.roots, store, StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { }), now = { 9.0 })
        val s = f.carveStems("sng_1", "Song", stems, setOf("drums", "bass"), 1000, 3000, null)
        assertEquals("Song · drums+bass", s.name)
        assertEquals(StudioSource.Track("sng_1", 1000, 3000), s.source)   // song-relative, no album offset
        assertEquals(2000, s.durationMs)
        assertEquals(0.6f, codec.written!!.samples[10], 1e-5f)
        assertTrue(env.appFile(StudioFamily.SAMPLES, s.fileName).isFile)
        assertNotNull(store.sample(s.id))
    }

    @Test fun carveStemsWithAMissingStemFailsWithoutFilingASample() = runBlocking {
        val env = TestEnv(tmp.newFolder()); val store = env.store()
        val f = SampleFactory(env.roots, store, StudioRender(Codec(emptyMap()), ResampleStretcher, Dispatchers.Unconfined, { }))
        try { f.carveStems("s", "S", mapOf("drums" to File("d")), setOf("drums", "bass"), 0, 1000, null); fail() }
        catch (e: SampleFileException) { assertEquals(SampleFileFailure.Carve, e.failure) }
        try { f.carveStems("s", "S", mapOf("drums" to File("nope")), setOf("drums"), 0, 1000, null); fail() }
        catch (e: SampleFileException) { assertEquals(SampleFileFailure.Carve, e.failure) }
        assertTrue(store.samples.isEmpty())
    }
}

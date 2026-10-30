package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class TakeFilerTest {
    @get:Rule val tmp = TemporaryFolder()

    /** "Encodes" a PcmBuffer as its frame count in a text file; decodes it back as silence of that length. */
    private class TextCodec : StudioCodec {
        override fun decode(path: String): PcmBuffer? = File(path).takeIf { it.isFile }?.readText()?.toIntOrNull()?.let { PcmBuffer(44_100, 2, FloatArray(it * 2)) }
        override fun decodeNativeRate(path: String) = decode(path)
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText(pcm.frames.toString()) }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText(pcm.frames.toString()) }
    }

    private val bank = File("/bank.sf2")
    private fun ev(on: Int, off: Int) = StudioNoteEvent(on, off, 60, 90)
    private fun rig(): Triple<TestEnv, com.levi.pocketdj.studio.store.StudioStore, TakeFiler> {
        val env = TestEnv(tmp.newFolder("studio")); val store = env.store(); val codec = TextCodec()
        val renderer = TakeRenderer(env.roots, store, { FakeSynth() }, codec, Dispatchers.Unconfined)
        val sr = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, log = {})
        return Triple(env, store, TakeFiler(env.roots, store, renderer, sr) { 42.0 })
    }
    private fun result(events: List<StudioNoteEvent>) = TakeResult("tk_rec", "take-tk_rec.m4a", 1_200, events, 96.0, InstrumentKey.TRUMPET)

    @Test fun filingRendersTheRawAudioAndAddsTheRecord() = runBlocking {
        val (env, store, filer) = rig()
        val t = filer.file(result(listOf(ev(0, 500))), "Take 1", bank)
        assertEquals(t, store.take("tk_rec"))
        assertEquals(listOf(ev(0, 500)), t.events)              // ms from beat 1, as played
        assertEquals(96.0, t.bpm, 0.0); assertEquals(InstrumentKey.TRUMPET, t.instrument); assertEquals(1_200, t.durationMs)
        assertEquals(42.0, t.createdAt, 0.0)
        assertTrue(File(env.base, "app/takes/take-tk_rec.m4a").isFile)
        assertTrue(filer.currentAudioFile(t)!!.name == "take-tk_rec.m4a")   // never edited => the raw file is current
    }

    @Test fun overdubStaffsRideWithTheFiledTake() = runBlocking {
        val (_, store, filer) = rig()
        val extras = listOf(LiveExtraStaff("s2", InstrumentKey.VIOLIN, listOf(ev(0, 900))))
        val t = filer.file(result(listOf(ev(0, 500))).copy(extraStaffs = extras), "Take 1", bank)
        assertEquals(2, t.staffCount)
        assertEquals(2, store.take("tk_rec")!!.staffCount)
        assertEquals(InstrumentKey.VIOLIN, store.take("tk_rec")!!.extraStaffs!!.single().instrument)
    }

    @Test fun missingNativeLibraryFailsTheFilingInsteadOfCrashing() = runBlocking {
        val env = TestEnv(tmp.newFolder("studio2")); val store = env.store(); val codec = TextCodec()
        val renderer = TakeRenderer(env.roots, store, { throw UnsatisfiedLinkError("libpdjdsp") }, codec, Dispatchers.Unconfined)
        val sr = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, log = {})
        val filer = TakeFiler(env.roots, store, renderer, sr) { 42.0 }
        try { filer.file(result(listOf(ev(0, 500))), "Take 1", bank); fail() } catch (e: TakeFileException) { assertEquals(TakeFileFailure.Failed, e.failure) }
        assertNull(store.take("tk_rec"))
    }

    @Test fun emptyTakeOrMissingPackFilesNothing() = runBlocking {
        val (env, store, filer) = rig()
        try { filer.file(result(emptyList()), "x", bank); fail() } catch (e: TakeFileException) { assertEquals(TakeFileFailure.NoNotes, e.failure) }
        try { filer.file(result(listOf(ev(0, 5))), "x", null); fail() } catch (e: TakeFileException) { assertTrue(e.failure is TakeFileFailure.PackMissing) }
        assertTrue(store.takes(null).isEmpty())
        assertTrue(env.roots.appDir(StudioFamily.TAKES).list().isEmpty())
    }

    @Test fun useAsSampleCopiesTheAudioSoTheSampleOutlivesTheTake() = runBlocking {
        val (env, store, filer) = rig()
        val take = filer.file(result(listOf(ev(0, 500))), "Riff", bank)
        val s = filer.useAsSample(take, { bank })
        assertEquals("Riff", s.name)
        assertEquals(StudioSource.Take("tk_rec"), s.source)
        assertEquals(96.0, s.grid!!.bpm, 0.0)
        val sampleFile = File(env.base, "app/samples/${s.fileName}")
        assertTrue(sampleFile.isFile)
        assertNotEquals("a distinct file, not a reference", File(env.base, "app/takes/take-tk_rec.m4a").path, sampleFile.path)
        store.deleteTake("tk_rec")
        assertTrue("sample audio survives deleting the take", sampleFile.isFile)
        assertEquals(s, store.sample(s.id))
        assertTrue(s.durationMs > 0)
    }

    @Test fun useAsSampleOfAnEditedTakeRendersTheEditedScoreFirst() = runBlocking {
        val (env, store, filer) = rig()
        val take = filer.file(result(listOf(ev(0, 100))), "Riff", bank)
        store.setTakeEvents("tk_rec", listOf(ev(0, 2_000)))                 // edit => raw file no longer represents the score
        val edited = store.take("tk_rec")!!
        assertNull(filer.currentAudioFile(edited))
        val s = filer.useAsSample(edited, { bank })
        assertTrue("sample is the 2 s edited render (+tail), not the 0.1 s raw", s.durationMs >= 2_000)
        assertTrue(store.take("tk_rec")!!.isRenderFresh)
        assertFalse(take.id.isEmpty())
    }

    @Test fun useAsSampleWithoutThePackSaysSo() = runBlocking {
        val (_, store, filer) = rig()
        filer.file(result(listOf(ev(0, 100))), "Riff", bank)
        store.setTakeInstrument("tk_rec", InstrumentKey.HARP)               // invalidates the render
        try { filer.useAsSample(store.take("tk_rec")!!, { null }); fail() } catch (e: TakeFileException) {
            assertEquals(InstrumentKey.HARP, (e.failure as TakeFileFailure.PackMissing).instrument)
        }
        assertTrue(store.samples(null).isEmpty())
    }

    @Test fun safStoredTakeIsUsableAsSampleViaTheMaterializer() = runBlocking {
        val (env, store, _) = rig()
        val codec = TextCodec()
        val renderer = TakeRenderer(env.roots, store, { FakeSynth() }, codec, Dispatchers.Unconfined)
        val sr = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, log = {})
        // The take's audio lives behind a user folder whose ref has no File (SAF): roots resolve to a content:// ref.
        val safRoots = object : com.levi.pocketdj.studio.store.StudioRoots by env.roots {
            override fun userDir(family: StudioFamily): com.levi.pocketdj.studio.store.StudioDir? = object : com.levi.pocketdj.studio.store.StudioDir {
                override val key = "content://tree"
                override fun exists(name: String) = true
                override fun list() = listOf("take-tk_saf.m4a")
                override fun length(name: String) = 3L
                override fun delete(name: String) = false
                override fun isWritable() = true
                override fun resolve(name: String) = com.levi.pocketdj.studio.store.StudioFileRef(null, "content://tree/$name")
                override fun openOutput(name: String) = null
            }
        }
        val mat = com.levi.pocketdj.studio.store.StudioMaterializer(tmp.newFolder("cache"), { com.levi.pocketdj.studio.store.SafStat(3, 1) }, { java.io.ByteArrayInputStream("900".toByteArray()) })
        val filer = TakeFiler(safRoots, store, renderer, sr, materializer = mat, now = { 42.0 })
        val take = com.levi.pocketdj.studio.model.StudioTake(
            id = "tk_saf", name = "Saf riff", instrument = InstrumentKey.PIANO, fileName = "take-tk_saf.m4a", wasUserFolder = true,
            bpm = 100.0, events = listOf(ev(0, 500)), durationMs = 500, createdAt = 1.0,
        )
        assertNull("no File for a SAF ref", filer.currentAudioFile(take))
        val s = filer.useAsSample(take, { bank })
        assertEquals("Saf riff", s.name)
        assertTrue(File(env.base, "app/samples/${s.fileName}").isFile)
    }
}

package com.levi.pocketdj.data.profile

import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import com.levi.pocketdj.studio.store.SafStat
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFileRef
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioMaterializer
import com.levi.pocketdj.studio.store.StudioPlayable
import com.levi.pocketdj.studio.store.TestEnv
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Q125: every NEW sampler sample is auto-filed into the "Pocket DJ Samples" profile album (iOS Stage 5 parity). */
class SampleAlbumFilerTest {
    @get:Rule val tmp = TemporaryFolder()
    private val env by lazy { TestEnv(tmp.newFolder("studio")) }
    private val profileDir by lazy { tmp.newFolder("profile") }
    private val source by lazy { ProfileSourceStore(File(profileDir, ProfileSourceStore.FILE_NAME), File(profileDir, "profile-audio")) }
    private val audio by lazy { ProfileAudioStore(source) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var filer: SampleAlbumFiler? = null

    @After fun tearDown() { scope.cancel() }

    private fun bytes(n: Int) = ByteArray(n) { (it * 7 + 3).toByte() }

    private fun sample(id: String, name: String = "Kick", user: Boolean = false, durationMs: Int = 2000, bpm: Double? = null) =
        StudioSample(
            id, name, StudioFolders.fileName(StudioFamily.SAMPLES, id), wasUserFolder = user, createdAt = 1.0,
            durationMs = durationMs, grid = bpm?.let { StudioGrid(it) },
        )

    private fun writeRaw(id: String, data: ByteArray, user: Boolean = false): File {
        val n = StudioFolders.fileName(StudioFamily.SAMPLES, id)
        return (if (user) env.userFile(StudioFamily.SAMPLES, n) else env.appFile(StudioFamily.SAMPLES, n)).also { it.writeBytes(data) }
    }

    /** Attach the REAL wiring (the same call StudioGraph makes). */
    private fun attached(store: com.levi.pocketdj.studio.store.StudioStore): SampleAlbumFiler =
        SampleAlbumFiler.attach(store, { StudioMaterializer.FILES_ONLY.lease(it) }, { audio }, scope).also { filer = it }

    /** Wait on the asserted condition: every in-flight filing job has finished (no fixed sleeps). */
    private fun awaitFiling() = runBlocking { withTimeout(5000) { filer!!.awaitIdle() } }

    @Test fun newSampleLandsInThePocketDjSamplesAlbumWithIosMetadata() {
        source.setProfileName("DJ Nova")
        val store = env.store()
        attached(store)
        val raw = bytes(4096)
        writeRaw("smp_a", raw)
        store.addSample(sample("smp_a", name = "Vocal Chop", durationMs = 2000, bpm = 124.0)
            .copy(edit = StudioSampleEdit(trimStartMs = 500)))
        awaitFiling()

        val e = source.songs().single()
        assertTrue(ProfileSourceStore.isProfileSongId(e.songId))
        assertEquals(ProfileSourceStore.Kind.SAMPLE, e.kind)
        assertEquals("Vocal Chop", e.title)
        assertEquals(1500L, e.durationMs)          // effectiveDurationMs (trim window / rate), as iOS
        assertEquals(124.0, e.bpm!!, 0.0)          // the sample's beat-grid bpm
        assertNull(e.key); assertNull(e.camelot)
        assertTrue(e.fileName.endsWith(".m4a"))
        assertArrayEquals(raw, audio.originalFor(e.songId)!!.readBytes())   // byte-exact independent copy

        val doc = source.syntheticDocument()
        val album = doc.albums.single { it.id == ProfileSourceStore.SAMPLES_ALBUM_ID }
        assertEquals("Pocket DJ Samples", album.name)
        assertEquals("DJ Nova", album.artist)
        assertEquals(listOf(e.songId), album.trackList)
        assertTrue(doc.albums.single { it.id == ProfileSourceStore.DEMUXES_ALBUM_ID }.trackList.isEmpty())
        assertEquals("DJ Nova", doc.songs.single().artist)
    }

    @Test fun zeroDurationAndNoGridFileAsNulls() {
        val store = env.store()
        attached(store)
        writeRaw("smp_z", bytes(64))
        store.addSample(sample("smp_z", durationMs = 0))
        awaitFiling()
        val e = source.songs().single()
        assertNull(e.durationMs)
        assertNull(e.bpm)
    }

    @Test fun upsertAndCrashRetryReFileNeverDuplicateTheAlbumItem() {
        val store = env.store()
        attached(store)
        writeRaw("smp_a", bytes(128))
        store.addSample(sample("smp_a"))
        store.addSample(sample("smp_a", name = "Renamed by re-file"))
        store.addSampleRelocating(sample("smp_a"))
        awaitFiling()
        assertEquals(1, source.songs().size)
    }

    @Test fun userFolderSampleIsFiledFromItsFinalLocation() {
        env.configured += StudioFamily.SAMPLES
        val store = env.store()
        attached(store)
        val raw = bytes(2048)
        writeRaw("smp_u", raw)                       // finalized in app storage, then MOVED by addSampleRelocating
        store.addSampleRelocating(sample("smp_u"))
        awaitFiling()
        assertTrue(store.sample("smp_u")!!.wasUserFolder)
        assertArrayEquals(raw, audio.originalFor(source.songs().single().songId)!!.readBytes())
    }

    @Test fun sampleDeleteAndRenameLeaveTheIndependentAlbumItemAlone() {
        val store = env.store()
        attached(store)
        writeRaw("smp_a", bytes(256))
        store.addSample(sample("smp_a", name = "Original"))
        awaitFiling()
        val id = source.songs().single().songId
        store.renameSample("smp_a", "New name")
        assertTrue(store.deleteSample("smp_a"))
        // iOS parity: the profile item is an independent copy (own bytes, own title), untouched by Studio edits.
        assertEquals("Original", source.entry(id)!!.title)
        assertNotNull(audio.originalFor(id))
    }

    @Test fun missingAudioFilesNothingAndLeavesNoPartialState() {
        val store = env.store()
        attached(store)
        store.addSample(sample("smp_gone"))           // record without its file
        awaitFiling()
        assertTrue(source.songs().isEmpty())
        assertTrue((source.audioDir.listFiles() ?: emptyArray()).isEmpty())
    }

    @Test fun safMaterializedCopyKeepsTheSamplesRealExtension() = runBlocking {
        val backing = File(tmp.root, "saf-doc").also { it.writeBytes(bytes(512)) }
        val mat = StudioMaterializer(tmp.newFolder("cache"), { SafStat(backing.length(), 42L) }, { backing.inputStream() })
        val uri = "content://tree/document/sample-smp_s.m4a"
        val s = sample("smp_s", user = true)
        val f = SampleAlbumFiler({ StudioPlayable(StudioFileRef(null, uri), s.name, 2000) }, { mat.lease(it) }, { audio }, scope)
        val e = f.file(s)
        assertNotNull(e)
        // The materializer's cache file is `<hash>.audio`: the album item must keep the sample's own `.m4a`.
        assertTrue(e!!.fileName, e.fileName.endsWith(".m4a"))
        assertArrayEquals(backing.readBytes(), audio.originalFor(e.songId)!!.readBytes())
    }

    @Test fun firstLeaseFailureIsRetriedOnceThenGivesUpCleanly() = runBlocking {
        val raw = writeRaw("smp_r", bytes(300))
        val s = sample("smp_r")
        val calls = AtomicInteger()
        val flaky = SampleAlbumFiler(
            { StudioPlayable(StudioFileRef(raw, raw.path), s.name, 2000) },
            { ref -> if (calls.incrementAndGet() == 1) null else StudioMaterializer.FILES_ONLY.lease(ref) },
            { audio }, scope,
        )
        assertNotNull(flaky.file(s))
        assertEquals(2, calls.get())

        val dead = SampleAlbumFiler({ StudioPlayable(StudioFileRef(null, "content://revoked"), s.name, 2000) }, { null }, { audio }, scope)
        assertNull(dead.file(s.copy(id = "smp_dead")))
        assertEquals(1, source.songs().size)
    }

    @Test fun concurrentDuplicateAnnouncementsFileOnce() = runBlocking {
        val raw = writeRaw("smp_c", bytes(1000))
        val s = sample("smp_c")
        val f = SampleAlbumFiler({ StudioPlayable(StudioFileRef(raw, raw.path), s.name, 2000) }, { StudioMaterializer.FILES_ONLY.lease(it) }, { audio }, scope)
        (1..8).map { async(Dispatchers.IO) { f.file(s) } }.awaitAll()
        assertEquals(1, source.songs().size)
        assertEquals(1, (source.audioDir.listFiles() ?: emptyArray()).count { it.isFile })
    }
}

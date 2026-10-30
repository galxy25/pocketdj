package com.levi.pocketdj.data.profile

import com.levi.pocketdj.data.profile.ProfileSourceStore.Kind
import com.levi.pocketdj.data.profile.ProfileSourceStore.SongEntry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProfileSourceStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun store(dir: File = tmp.root) =
        ProfileSourceStore(File(dir, ProfileSourceStore.FILE_NAME), File(dir, "profile-audio"))

    private fun entry(id: String, kind: Kind, title: String = id) =
        SongEntry(songId = id, title = title, kind = kind, fileName = "$id.m4a", durationMs = 1000, bpm = 120.0, camelot = "8A")

    private fun file(name: String, bytes: ByteArray = byteArrayOf(1, 2, 3, 4)) = File(tmp.root, "src-$name").also { it.writeBytes(bytes) }

    @Test fun emptyStoreStillSynthesizesBothDefaultAlbums() {
        val doc = store().syntheticDocument()
        assertEquals("Pocket DJ", doc.manifest.sourceName)
        assertEquals("profile-source", doc.manifest.source)
        assertEquals(setOf("pdjalb_samples", "pdjalb_demuxes"), doc.albums.map { it.id }.toSet())
        assertEquals("Pocket DJ Demuxes", doc.albums.first { it.id == "pdjalb_demuxes" }.name)
        assertTrue(doc.albums.all { it.trackList.isEmpty() && it.artist == "Pocket DJ" })
        assertTrue(doc.songs.isEmpty())
    }

    @Test fun emptyStoreContributesNoMergeDocumentUntilFirstItem() {
        val s = store()
        assertTrue(s.syntheticDocumentsIfAny().isEmpty())
        s.add(listOf(entry("pdj_x", Kind.DEMUX)))
        assertEquals(1, s.syntheticDocumentsIfAny().size)
    }

    @Test fun whitespaceOnlyNameEditDoesNotFireOnChanged() {
        val s = store(); var fired = 0
        s.onChanged = { fired++ }
        s.setProfileName("Levi"); s.setProfileName("Levi ")
        assertEquals(1, fired)
    }

    @Test fun kindRoutesToAlbumAndArtistIsTheProfileName() {
        val s = store(); s.setProfileName("DJ Nova")
        s.add(listOf(entry("pdj_s", Kind.SAMPLE), entry("pdj_d", Kind.DEMUX)))
        val doc = s.syntheticDocument()
        assertEquals("DJ Nova", doc.manifest.sourceName)
        assertEquals("DJ Nova", doc.songs.first { it.id == "pdj_s" }.artist)
        assertEquals("pdjalb_samples", doc.songs.first { it.id == "pdj_s" }.albumId)
        assertEquals("pdjalb_demuxes", doc.songs.first { it.id == "pdj_d" }.albumId)
        assertEquals(listOf("pdj_d"), doc.albums.first { it.id == "pdjalb_demuxes" }.trackList)
        assertEquals(120.0, doc.songs.first().bpm!!, 0.0)
    }

    @Test fun blankProfileNameFallsBackAndRenameRetagsWithoutStoringArtist() {
        val s = store(); s.add(listOf(entry("pdj_a", Kind.DEMUX)))
        s.setProfileName("   ")
        assertEquals("Pocket DJ", s.syntheticDocument().manifest.sourceName)
        var fired = 0; s.onChanged = { fired++ }
        s.setProfileName("Levi")
        assertEquals(1, fired)
        s.setProfileName("Levi")           // unchanged: no remerge
        assertEquals(1, fired)
        assertEquals("Levi", s.syntheticDocument().songs.single().artist)
        assertFalse(File(tmp.root, ProfileSourceStore.FILE_NAME).readText().contains("Levi"))
    }

    @Test fun addDedupesPersistsAndFiresOnChangedOnlyForFreshRows() {
        val s = store(); var fired = 0; s.onChanged = { fired++ }
        assertEquals(2, s.add(listOf(entry("pdj_a", Kind.SAMPLE), entry("pdj_b", Kind.DEMUX))).size)
        assertTrue(s.add(listOf(entry("pdj_a", Kind.SAMPLE))).isEmpty())
        assertEquals(1, fired)
        assertEquals(listOf("pdj_a", "pdj_b"), store().songs().map { it.songId })
    }

    @Test fun syntheticDocumentIsTheSameInstanceUntilSomethingChanges() {
        val s = store()
        val a = s.syntheticDocument()
        assertSame(a, s.syntheticDocument())
        s.add(listOf(entry("pdj_a", Kind.DEMUX)))
        assertTrue(a !== s.syntheticDocument())
    }

    @Test fun documentUsesTheIosShapeAndDecodesAnIosFile() {
        val ios = """{"schemaVersion":1,"songs":[{"songId":"pdj_x","title":"T","kind":"demux","fileName":"pdj_x.m4a",
            |"durationMs":180000,"bpm":90,"addedAtMs":5,"futureField":1}]}""".trimMargin()
        File(tmp.root, ProfileSourceStore.FILE_NAME).writeText(ios)
        val s = store()
        assertEquals(Kind.DEMUX, s.entry("pdj_x")!!.kind)
        assertEquals(180000L, s.entry("pdj_x")!!.durationMs)
        s.add(listOf(entry("pdj_y", Kind.SAMPLE)))
        val out = File(tmp.root, ProfileSourceStore.FILE_NAME).readText()
        assertTrue(out.contains("\"kind\":\"sample\"")); assertTrue(out.contains("\"songId\":\"pdj_x\""))
    }

    @Test fun corruptDocumentIsAnEmptyStore() {
        File(tmp.root, ProfileSourceStore.FILE_NAME).writeText("{nope")
        assertTrue(store().songs().isEmpty())
    }

    @Test fun idPrefixFenceExcludesDefaultAlbumIds() {
        assertTrue(ProfileSourceStore.isProfileSongId("pdj_123"))
        assertFalse(ProfileSourceStore.isProfileSongId("pdjalb_demuxes"))
        assertFalse(ProfileSourceStore.isProfileSongId("smp_1"))
    }

    @Test fun ingestCopiesOriginalByteExactAndStemsAndMintsPdjId() = runBlocking {
        val s = store(); s.setProfileName("Levi"); val audio = ProfileAudioStore(s)
        val orig = file("o.mp3", ByteArray(50) { it.toByte() })
        val stems = listOf("vocals", "drums", "bass", "other").associateWith { file("$it.mp3", it.toByteArray()) }
        val e = audio.ingest(Kind.DEMUX, "Song - Vox", orig, durationMs = 2000, stems = stems, bpm = 100.0)!!
        assertTrue(e.songId.startsWith("pdj_")); assertTrue(e.fileName.endsWith(".mp3"))
        assertEquals(orig.readBytes().toList(), audio.originalFor(e.songId)!!.readBytes().toList())
        assertEquals(setOf("vocals", "drums", "bass", "other"), audio.stemFiles(e.songId)!!.keys)
        assertEquals("drums", audio.stemFiles(e.songId)!!.getValue("drums").readText())
        assertEquals("Levi", s.syntheticDocument().songs.single().artist)
        assertEquals("pdjalb_demuxes", s.syntheticDocument().songs.single().albumId)
        assertTrue(audio.usageBytes() >= 50)
        assertTrue(audio.hasLocalAsset(e.songId))
    }

    @Test fun incompleteStemsFailTheWholeIngestAndLeaveNothingBehind() = runBlocking {
        val s = store(); val audio = ProfileAudioStore(s)
        val partial = mapOf("vocals" to file("v.mp3"), "drums" to file("d.mp3"))
        assertNull(audio.ingest(Kind.DEMUX, "x", file("o.mp3"), stems = partial))
        assertTrue(s.songs().isEmpty())
        assertTrue(s.audioDir.listFiles().orEmpty().none { it.isFile })
        assertTrue(s.audioDir.resolve("stems").listFiles().orEmpty().isEmpty())
    }

    @Test fun missingSourceFailsWithoutRecord() = runBlocking {
        val s = store(); val audio = ProfileAudioStore(s)
        assertNull(audio.ingest(Kind.SAMPLE, "x", File(tmp.root, "absent.m4a")))
        assertTrue(s.songs().isEmpty())
    }

    @Test fun stemsRequireAllFourAndMatchAnyExtension() = runBlocking {
        val s = store(); val audio = ProfileAudioStore(s)
        val e = audio.ingest(Kind.DEMUX, "x", file("o.m4a"))!!
        assertNull(audio.stemFiles(e.songId))
        val d = audio.stemsDir(e.songId); d.mkdirs()
        listOf("vocals.mp3", "drums.caf", "bass.flac").forEach { File(d, it).writeText("x") }
        assertNull(audio.stemFiles(e.songId))
        File(d, "other.m4a").writeText("x")
        assertNotNull(audio.stemFiles(e.songId))
    }

    @Test fun resolveOriginalRejectsTraversalAndHostileNames() {
        val s = store(); val audio = ProfileAudioStore(s)
        s.audioDir.mkdirs(); File(tmp.root, "secret.txt").writeText("s")
        listOf("", ".", "..", "../secret.txt", "a/b", "a\\b").forEach { assertNull(it, audio.resolveOriginal(it)) }
    }

    @Test fun deleteAssetRemovesAudioStemsAndRecord() = runBlocking {
        val s = store(); val audio = ProfileAudioStore(s)
        val stems = listOf("vocals", "drums", "bass", "other").associateWith { file(it) }
        val e = audio.ingest(Kind.DEMUX, "x", file("o.m4a"), stems = stems)!!
        audio.deleteAsset(e.songId)
        assertNull(s.entry(e.songId)); assertFalse(audio.stemsDir(e.songId).exists())
        assertFalse(audio.hasLocalAsset(e.songId))
    }

    @Test fun clearPurgesRecordsDocumentAndAudio() = runBlocking {
        val s = store(); val audio = ProfileAudioStore(s)
        audio.ingest(Kind.SAMPLE, "x", file("o.m4a"))!!
        audio.deleteAll()
        assertTrue(s.songs().isEmpty()); assertFalse(s.audioDir.exists())
        assertFalse(File(tmp.root, ProfileSourceStore.FILE_NAME).exists())
        assertEquals(0L, audio.usageBytes())
        assertTrue(store().songs().isEmpty())
    }
}

package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppleMusicLibraryStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private fun file() = File(tmp.root, AppleMusicLibraryStore.FILE_NAME)

    /** What Swift's JSONEncoder writes: nil omitted, whole doubles as integers. */
    private val iosDoc = """{"schemaVersion":1,"songs":[{"songId":"amlib_i.1","libraryId":"i.1","appleMusicId":"900","title":"One","artist":"A","album":"Alb","albumId":"amlib_alb_x","trackNumber":2,"addedAtMs":1700000000000},{"songId":"amlib_i.2","libraryId":"i.2","title":"Two","artist":"B","addedAtMs":1700000500000}],"albums":[{"albumId":"amlib_alb_x","title":"Alb","artist":"A","trackIds":["amlib_i.1"]}],"playlists":[{"id":"amlibpl_p.1","name":"Mine","songIds":["amlib_i.1","amlib_i.2"]}],"lastAddedMs":1700000500000,"supersededAddedAt":{"sng_9":1699999999000}}"""

    private fun song(id: String, added: Double = 1.0) =
        AppleMusicLibraryStore.SongEntry(songId = "amlib_$id", libraryId = id, title = id, artist = "x", addedAtMs = added)

    @Test fun iosFixtureDecodesAndRoundTripsFieldForField() {
        file().writeText(iosDoc)
        val s = AppleMusicLibraryStore(file())
        assertEquals(2, s.songs.size)
        assertEquals("900", s.songs[0].appleMusicId)
        assertNull(s.songs[1].appleMusicId)
        assertEquals(1700000500000.0, s.lastAddedMs!!, 0.0)
        assertEquals(1699999999000.0, s.supersededAddedAt["sng_9"]!!, 0.0)
        assertEquals(listOf("amlib_i.1", "amlib_i.2"), s.playlists.single().songIds)
        // Re-encoding keeps every iOS field, with whole-number doubles still integers (no 1.7E12).
        val out = PdjJson.lenient.parseToJsonElement(s.encoded()) as JsonObject
        assertEquals(PdjJson.lenient.parseToJsonElement(iosDoc), out)
        assertFalse(s.encoded().contains("E12"))
    }

    @Test fun missingAlbumsAndPlaylistsKeysDecodeEmptyNotCrash() {
        file().writeText("""{"schemaVersion":1,"songs":[{"songId":"amlib_i.1","libraryId":"i.1","title":"T","artist":"A","addedAtMs":5}],"futureField":{"x":1}}""")
        val s = AppleMusicLibraryStore(file())
        assertEquals(1, s.songs.size)
        assertTrue(s.albums.isEmpty() && s.playlists.isEmpty())
        assertNull(s.lastAddedMs)
    }

    @Test fun incrementalWithNullPlaylistsNeverWipesThem() {
        file().writeText(iosDoc)
        val s = AppleMusicLibraryStore(file())
        s.applyIncremental(listOf(song("i.3", 1700000900000.0)), emptyList(), playlists = null, lastAddedMs = 1700000900000.0)
        assertEquals(3, s.songs.size)
        assertEquals(1, s.playlists.size)
        assertEquals(1, s.albums.size)
        // The key stays on disk (a missing key must not mean "wiped" to a peer).
        val disk = PdjJson.lenient.parseToJsonElement(file().readText()).jsonObject
        assertEquals(1, disk["playlists"]!!.jsonArray.size)
    }

    @Test fun incrementalIsIdempotentAndHighWaterMarkNeverLowers() {
        val s = AppleMusicLibraryStore(file())
        s.replaceAll(listOf(song("i.1", 10.0)), emptyList(), emptyList(), 10.0)
        val batch = listOf(song("i.1", 99.0), song("i.2", 20.0))
        assertTrue(s.applyIncremental(batch, emptyList(), null, 20.0))
        assertFalse(s.applyIncremental(batch, emptyList(), null, 5.0))
        assertEquals(listOf("amlib_i.1", "amlib_i.2"), s.songs.map { it.songId })
        assertEquals(10.0, s.songs[0].addedAtMs, 0.0) // existing row is not overwritten
        assertEquals(20.0, s.lastAddedMs!!, 0.0)
    }

    @Test fun incrementalUnionsAlbumTrackListsAndReplacesPlaylists() {
        val s = AppleMusicLibraryStore(file())
        val a1 = AppleMusicLibraryStore.AlbumEntry("alb", "Alb", "A", trackIds = listOf("amlib_i.1"))
        s.replaceAll(listOf(song("i.1")), listOf(a1), listOf(AppleMusicLibraryStore.PlaylistEntry("amlibpl_p", "Old", listOf("amlib_i.1"))), 1.0)
        s.applyIncremental(
            listOf(song("i.2")), listOf(a1.copy(trackIds = listOf("amlib_i.1", "amlib_i.2"))),
            listOf(AppleMusicLibraryStore.PlaylistEntry("amlibpl_p", "New", emptyList())), 2.0,
        )
        assertEquals(listOf("amlib_i.1", "amlib_i.2"), s.albums.single().trackIds)
        assertEquals("New", s.playlists.single().name)
    }

    @Test fun fullRunReplacesWholesaleButKeepsSupersededAddedAt() {
        file().writeText(iosDoc)
        val s = AppleMusicLibraryStore(file())
        s.replaceAll(listOf(song("i.9")), emptyList(), emptyList(), 3.0)
        assertEquals(listOf("amlib_i.9"), s.songs.map { it.songId })
        assertTrue(s.albums.isEmpty() && s.playlists.isEmpty())
        assertNotNull(s.supersededAddedAt["sng_9"])
        assertEquals(3.0, AppleMusicLibraryStore(file()).lastAddedMs!!, 0.0)
    }

    @Test fun supersedeCarriesAddTimeAndPrunesAlbums() {
        val s = AppleMusicLibraryStore(file())
        s.replaceAll(
            listOf(song("i.1", 50.0), song("i.2", 60.0)),
            listOf(AppleMusicLibraryStore.AlbumEntry("a", "A", "x", trackIds = listOf("amlib_i.1")), AppleMusicLibraryStore.AlbumEntry("b", "B", "x", trackIds = listOf("amlib_i.1", "amlib_i.2"))),
            emptyList(), 60.0,
        )
        s.supersede(listOf("amlib_i.1" to "sng_77"))
        assertEquals(listOf("amlib_i.2"), s.songs.map { it.songId })
        assertEquals(50.0, s.supersededAddedAt["sng_77"]!!, 0.0)
        assertEquals(listOf("b"), s.albums.map { it.albumId }) // emptied album dropped
        // an older add never lowers a carried time
        s.supersede(listOf("amlib_gone" to "sng_77"))
        assertEquals(50.0, s.supersededAddedAt["sng_77"]!!, 0.0)
    }

    @Test fun clearDeletesFileAndReloadPicksUpPeerCopy() {
        file().writeText(iosDoc)
        val s = AppleMusicLibraryStore(file())
        var fired = 0
        s.onChanged = { fired++ }
        file().writeText(iosDoc.replace("\"One\"", "\"Uno\""))
        assertTrue(s.reloadFromDisk())
        assertEquals("Uno", s.songs[0].title)
        assertFalse(s.reloadFromDisk())
        s.clear()
        assertFalse(file().exists())
        assertTrue(s.isEmpty)
        assertEquals(2, fired)
    }

    @Test fun corruptFileDecodesToEmptyDoc() {
        file().writeText("not json {")
        assertTrue(AppleMusicLibraryStore(file()).isEmpty)
    }
}

package com.levi.pocketdj.data.discover

import com.levi.pocketdj.data.discover.DiscoverAddsStore.AlbumEntry
import com.levi.pocketdj.data.discover.DiscoverAddsStore.Entry
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DiscoverAddsStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun file() = File(tmp.root, DiscoverAddsStore.FILE_NAME)
    private fun song(id: String, am: String = id.removePrefix("amrec_"), albumId: String? = null) =
        Entry(songId = id, appleMusicId = am, title = "T-$id", artist = "Artist", albumId = albumId, durationMs = 1000, addedAtMs = 5.0)

    @Test fun oldDocumentWithoutAlbumsDecodes() {
        // iOS-shape doc written before album support: no `albums`, none of the appended optional keys.
        file().writeText(
            """{"schemaVersion":1,"entries":[{"songId":"amrec_9","appleMusicId":"9","title":"Old","artist":"A","addedAtMs":123.0}]}""",
        )
        val s = DiscoverAddsStore(file())
        assertEquals(listOf("amrec_9"), s.entries.map { it.songId })
        assertTrue(s.albums.isEmpty())
        assertNull(s.entries[0].libraryWrite)
        assertNull(s.entries[0].albumId)
    }

    @Test fun unknownKeysAndNullsAreIgnored() {
        file().writeText(
            """{"schemaVersion":7,"future":{"x":1},"entries":[{"songId":"amrec_1","appleMusicId":"1","title":"T","artist":"A","addedAtMs":1,"album":null,"zzz":true}],
              "albums":[{"albumId":"amrec_album_5","appleMusicId":"5","title":"Al","artist":"A","addedAtMs":2,"trackIds":["amrec_1"],"preparedCopies":false,"newKey":"x"}]}""",
        )
        val s = DiscoverAddsStore(file())
        assertEquals(1, s.entries.size)
        assertEquals(false, s.albums.single().preparedCopies)
        assertEquals(listOf("amrec_1"), s.albums.single().trackIds)
    }

    @Test fun corruptOrMissingFileIsAnEmptyStore() {
        assertTrue(DiscoverAddsStore(file()).entries.isEmpty())
        file().writeText("not json")
        assertTrue(DiscoverAddsStore(file()).entries.isEmpty())
    }

    @Test fun addIsIdempotentPersistsAndLogsOnce() {
        val s = DiscoverAddsStore(file())
        var changed = 0
        val logged = mutableListOf<Pair<List<DiscoverAddsStore.CatalogItem>, String?>>()
        s.onChanged = { changed++ }
        s.onUserCatalogAdd = { items, lw -> logged += items to lw }
        assertTrue(s.add(song("amrec_1").copy(libraryWrite = "confirmed (web)")))
        assertFalse(s.add(song("amrec_1")))
        assertEquals(1, changed)
        assertEquals(1, logged.size)
        assertEquals("confirmed (web)", logged[0].second)
        assertEquals("amrec_1", logged[0].first.single().id)
        assertEquals("Artist", logged[0].first.single().artist)
        // Round trips through disk; a song-only store keeps the legacy shape (no `albums` key).
        assertFalse(file().readText().contains("albums"))
        assertEquals(listOf("amrec_1"), DiscoverAddsStore(file()).entries.map { it.songId })
    }

    @Test fun albumBatchFiresOneChangeAndOneAlbumLevelLog() {
        val s = DiscoverAddsStore(file())
        var changed = 0
        val logged = mutableListOf<List<DiscoverAddsStore.CatalogItem>>()
        s.onChanged = { changed++ }
        s.onUserCatalogAdd = { items, _ -> logged += items }
        val tracks = (1..12).map { song("amrec_$it", albumId = "amrec_album_9") }
        val album = AlbumEntry(albumId = "amrec_album_9", appleMusicId = "9", title = "LP", artist = "A", trackIds = tracks.map { it.songId })
        assertTrue(s.addAlbumBatch(album, tracks))
        assertEquals("one catalog rebuild for the whole album", 1, changed)
        assertEquals(listOf(listOf("amrec_album_9")), logged.map { l -> l.map { it.id } })
        assertEquals(12, s.entries.size)
        // Re-adding the same album records nothing and rebuilds nothing.
        assertFalse(s.addAlbumBatch(album, tracks))
        assertEquals(1, changed)
        assertEquals(1, logged.size)
        // New tracks for an existing album land (idempotent album), without a second album log.
        assertTrue(s.addAlbumBatch(album, listOf(song("amrec_13", albumId = "amrec_album_9"))))
        assertEquals(2, changed)
        assertEquals(1, logged.size)
        assertEquals(13, s.entries.size)
        assertTrue(file().readText().contains("albums"))
    }

    @Test fun userRemoveDropsRowAndRefreshesCatalogUnlikeSupersede() {
        val s = DiscoverAddsStore(file())
        s.add(song("amrec_1")); s.add(song("amrec_2"))
        var changed = 0
        s.onChanged = { changed++ }
        s.remove(listOf("amrec_2")) // supersede path: silent
        assertEquals(0, changed)
        val item = s.userRemove("amrec_1")
        assertEquals("amrec_1", item?.id)
        assertEquals("T-amrec_1", item?.title)
        assertEquals(1, changed)
        assertNull(s.userRemove("amrec_1"))
        assertTrue(s.entries.isEmpty())
        assertTrue(DiscoverAddsStore(file()).entries.isEmpty())
    }

    @Test fun cloudPullReloadRefreshesButNeverLogsAUserAdd() {
        val a = DiscoverAddsStore(file())
        a.add(song("amrec_1"))
        // A peer's copy lands on disk, then the sync engine calls reloadFromDisk.
        file().writeText("""{"schemaVersion":1,"entries":[{"songId":"amrec_1","appleMusicId":"1","title":"T","artist":"A","addedAtMs":1},{"songId":"amrec_2","appleMusicId":"2","title":"U","artist":"A","addedAtMs":2}]}""")
        var changed = 0
        var logged = 0
        a.onChanged = { changed++ }
        a.onUserCatalogAdd = { _, _ -> logged++ }
        a.reloadFromDisk()
        assertEquals(listOf("amrec_1", "amrec_2"), a.entries.map { it.songId })
        assertEquals(1, changed)
        assertEquals(0, logged)
        a.reloadFromDisk() // unchanged -> nothing
        assertEquals(1, changed)
    }

    @Test fun recordAlbumLibraryWriteLogsOnlyWhenNewlyProven() {
        val s = DiscoverAddsStore(file())
        s.addAlbumBatch(AlbumEntry(albumId = "al", appleMusicId = "1", title = "L", artist = "A", libraryWrite = "failed: x"), listOf(song("amrec_1")))
        val logged = mutableListOf<String?>()
        s.onUserCatalogAdd = { _, lw -> logged += lw }
        s.recordAlbumLibraryWrite("al", "failed: x") // unchanged
        s.recordAlbumLibraryWrite("al", "failed: y") // changed but not proof
        s.recordAlbumLibraryWrite("al", "confirmed") // heal
        s.recordAlbumLibraryWrite("al", "confirmed") // idempotent
        assertEquals(listOf<String?>("confirmed"), logged)
        assertEquals("confirmed", s.albums.single().libraryWrite)
    }

    @Test fun indexSongCarriesEveryKnownField() {
        val e = Entry(songId = "amrec_1", appleMusicId = "1", title = "T", artist = "A", durationMs = 200_000, addedAtMs = 99.0,
            albumId = "amrec_album_2", trackNumber = 3, year = 2020, explicit = true)
        val row = DiscoverAddsStore.indexSong(e)
        assertEquals("amrec_1", row.id); assertEquals("T", row.name); assertEquals("1", row.appleMusicId)
        assertEquals(200_000L, row.length); assertEquals("amrec_album_2", row.albumId); assertEquals(3, row.trackNumber)
        assertEquals(2020, row.year); assertEquals(true, row.explicit); assertEquals(99.0, row.dateAdded)
    }

    @Test fun syntheticIndexIsNamedDiscoverAndBuildsAlbums() {
        val al = AlbumEntry(albumId = "amrec_album_2", appleMusicId = "2", title = "LP", artist = "A", trackIds = listOf("amrec_1"), artworkUrl = "https://x/y.jpg", year = 2019)
        val idx = DiscoverAddsStore.syntheticIndex(listOf(song("amrec_1")), listOf(al))
        assertEquals("Discover", idx.manifest.displayName)
        val a = idx.albums.single()
        assertEquals(listOf("amrec_1"), a.trackList); assertEquals("2", a.appleMusicId); assertEquals("https://x/y.jpg", a.coverArt)
    }

    @Test fun clearEmptiesAndDeletesFile() {
        val s = DiscoverAddsStore(file())
        s.add(song("amrec_1"))
        assertNotNull(s.entry("amrec_1"))
        s.clear()
        assertTrue(s.entries.isEmpty()); assertFalse(file().exists())
    }
}

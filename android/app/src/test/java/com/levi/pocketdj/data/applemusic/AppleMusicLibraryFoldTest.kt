package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.RecentlyAdded
import com.levi.pocketdj.data.reset.AccountDeletionService
import com.levi.pocketdj.screens.settings.sections.libraryIndexCaption
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppleMusicLibraryFoldTest {
    @get:Rule val tmp = TemporaryFolder()

    @After fun resetHook() { RecentlyAdded.extraOverrides = { emptyMap() } }

    private fun lib(id: String, am: String? = null, album: String? = null, added: Double = 1000.0) =
        AppleMusicLibraryStore.SongEntry(
            songId = "amlib_$id", libraryId = id, appleMusicId = am, title = "T$id", artist = "A",
            album = album?.let { "Alb" }, albumId = album, trackNumber = 3, durationMs = 180000, addedAtMs = added,
        )

    private fun local(vararg songs: IndexSong, name: String = "Apple Music (Local)") = IndexJson(
        manifest = IndexManifest(source = "x", sourceName = name),
        songs = songs.toList(),
        albums = listOf(IndexAlbum(id = "alb_l", artist = "A", name = "Alb", trackList = songs.map { it.id })),
    )

    private fun idx(id: String, am: String?) = IndexSong(id = id, artist = "A", name = id, appleMusicId = am)

    @Test fun sourceIsNamedAppleMusicDistinctFromLocal() {
        val r = AppleMusicLibraryFold.fold(listOf(lib("1")), emptyList(), emptyList(), emptyList(), true)
        val doc = r.documents.single()
        assertEquals("Apple Music", doc.manifest.displayName)
        assertEquals("apple-music-library", doc.manifest.source)
        assertTrue(doc.manifest.displayName != com.levi.pocketdj.data.config.Endpoints.SOURCE_NAME_APPLE_MUSIC)
        val s = doc.songs.single()
        assertEquals("amlib_1", s.id)
        assertEquals(180000L, s.length)
        assertEquals(3, s.trackNumber)
        assertEquals(1000.0, s.dateAdded!!, 0.0)
    }

    @Test fun supersedesOntoIndexedLocalTwinByAppleMusicId() {
        val real = listOf(local(idx("sng_9", "900")))
        val r = AppleMusicLibraryFold.fold(listOf(lib("1", "900"), lib("2", "901"), lib("3", null)), emptyList(), emptyList(), real, true)
        assertEquals(listOf("amlib_1" to "sng_9"), r.pairs)
        assertEquals(listOf("amlib_2", "amlib_3"), r.documents.single().songs.map { it.id })
    }

    @Test fun mergedCatalogHasTwinOnceAndLibrarySongUnderAppleMusic() {
        val real = listOf(local(idx("sng_9", "900")))
        val r = AppleMusicLibraryFold.fold(listOf(lib("1", "900"), lib("2", "901")), emptyList(), emptyList(), real, true)
        val cat = MergedCatalog.merge(real + r.documents)
        assertEquals(setOf("sng_9", "amlib_2"), cat.songs.map { it.id }.toSet())
        assertEquals("Apple Music (Local)", cat.sourceOfSong["sng_9"])
        assertEquals("Apple Music", cat.sourceOfSong["amlib_2"])
        assertEquals(listOf("Apple Music (Local)", "Apple Music"), cat.availableSources)
    }

    @Test fun twinInAnotherSourceNeverSupersedes() {
        // Defense-in-depth: only the private "Apple Music (Local)" index may eat a library row.
        val real = listOf(local(idx("sng_9", "900"), name = "My Vinyl"))
        val r = AppleMusicLibraryFold.fold(listOf(lib("1", "900")), emptyList(), emptyList(), real, true)
        assertTrue(r.pairs.isEmpty())
        assertEquals(listOf("amlib_1"), r.documents.single().songs.map { it.id })
    }

    @Test fun ownerGateOffKeepsEverything() {
        val real = listOf(local(idx("sng_9", "900")))
        val r = AppleMusicLibraryFold.fold(listOf(lib("1", "900")), emptyList(), emptyList(), real, false)
        assertTrue(r.pairs.isEmpty())
        assertEquals(1, r.documents.single().songs.size)
    }

    @Test fun foldThenSupersedeThenFoldKeepsPlaylistsResolvable() {
        val store = AppleMusicLibraryStore(File(tmp.root, "f.json"))
        store.applyIncremental(listOf(lib("1", "900"), lib("2", "800")), emptyList(),
            listOf(AppleMusicLibraryStore.PlaylistEntry(id = "amlibpl_p", name = "P", songIds = listOf("amlib_1", "amlib_2"))), 1000.0)
        val real = listOf(local(idx("sng_9", "900")))
        val r1 = AppleMusicLibraryFold.fold(store.songs, store.albums, store.playlists, real, true)
        assertEquals(listOf("amlib_1" to "sng_9"), r1.pairs)
        store.supersede(r1.pairs)
        val r2 = AppleMusicLibraryFold.fold(store.songs, store.albums, store.playlists, real, true)
        assertEquals(listOf("sng_9", "amlib_2"), r2.documents.single().playlists!!.single().songIds)
    }

    @Test fun gateOffNeverSupersedesGateOnDoes() {
        val real = listOf(local(idx("sng_9", "900")))
        val store = AppleMusicLibraryStore(File(tmp.root, "g.json"))
        store.applyIncremental(listOf(lib("1", "900")), emptyList(), null, 1000.0)
        var gate = false
        val src = AppleMusicLibraryFold.Source(store) { gate }
        assertTrue(src.resolve(real).pairs.isEmpty())
        gate = true
        assertEquals(1, src.resolve(real).pairs.size)
    }

    @Test fun sameIdTwinIsNotASupersede() {
        val real = listOf(local(idx("amlib_1", "900")))
        val sp = AppleMusicLibraryFold.split(listOf(lib("1", "900")), AppleMusicLibraryFold.ownIndexedByAppleMusicId(real))
        assertTrue(sp.superseded.isEmpty())
        assertEquals(1, sp.keep.size)
    }

    @Test fun playlistsAppearAndRemapSupersededSongIds() {
        val real = listOf(local(idx("sng_9", "900")))
        val pl = AppleMusicLibraryStore.PlaylistEntry("amlibpl_p.1", "Mine", listOf("amlib_1", "amlib_2"))
        val r = AppleMusicLibraryFold.fold(listOf(lib("1", "900"), lib("2", "901")), emptyList(), listOf(pl), real, true)
        val cat = MergedCatalog.merge(real + r.documents)
        val p = cat.playlists.single()
        assertEquals("Apple Music", p.sourceName)
        assertEquals("amlibpl_p.1", p.playlist.id)
        assertEquals(listOf("sng_9", "amlib_2"), p.playlist.songIds)
    }

    @Test fun playlistsOnlyLibraryStillEmitsADocument() {
        val pl = AppleMusicLibraryStore.PlaylistEntry("amlibpl_p.1", "Mine", emptyList())
        val r = AppleMusicLibraryFold.fold(emptyList(), emptyList(), listOf(pl), emptyList(), true)
        assertEquals(1, r.documents.size)
        assertTrue(r.documents.single().songs.isEmpty())
    }

    @Test fun emptyLibraryEmitsNothing() {
        val r = AppleMusicLibraryFold.fold(emptyList(), emptyList(), emptyList(), listOf(local(idx("s", "1"))), true)
        assertTrue(r.documents.isEmpty() && r.pairs.isEmpty())
    }

    @Test fun albumsDropSupersededTracksAndEmptyAlbumsVanish() {
        val real = listOf(local(idx("sng_9", "900")))
        val a1 = AppleMusicLibraryStore.AlbumEntry("amlib_alb_a", "A1", "A", trackIds = listOf("amlib_1", "amlib_2"))
        val a2 = AppleMusicLibraryStore.AlbumEntry("amlib_alb_b", "A2", "A", trackIds = listOf("amlib_1"))
        val r = AppleMusicLibraryFold.fold(listOf(lib("1", "900"), lib("2", "901")), listOf(a1, a2), emptyList(), real, true)
        val albums = r.documents.single().albums
        assertEquals(listOf("amlib_alb_a"), albums.map { it.id })
        assertEquals(listOf("amlib_2"), albums.single().trackList)
    }

    @Test fun sourceMemoizesOnIdentityAndFollowsStoreChanges() {
        val store = AppleMusicLibraryStore(File(tmp.root, AppleMusicLibraryStore.FILE_NAME))
        store.replaceAll(listOf(lib("1", "900")), emptyList(), emptyList(), 1.0)
        var gate = true
        val src = AppleMusicLibraryFold.Source(store) { gate }
        val real = listOf(local(idx("sng_9", "900")))
        val a = src.resolve(real)
        assertSame(a, src.resolve(real))
        assertEquals(1, a.pairs.size)
        gate = false
        val b = src.resolve(real)
        assertTrue(b.pairs.isEmpty())
        store.replaceAll(listOf(lib("1", "900"), lib("2", "5")), emptyList(), emptyList(), 2.0)
        assertEquals(2, src.resolve(real).documents.single().songs.size)
    }

    @Test fun supersedeCarriesAddedAtIntoRecentlyAddedOverrides() {
        val store = AppleMusicLibraryStore(File(tmp.root, AppleMusicLibraryStore.FILE_NAME))
        store.replaceAll(listOf(lib("1", "900", added = 5555.0)), emptyList(), emptyList(), 5555.0)
        store.supersede(listOf("amlib_1" to "sng_9"))
        assertEquals(5555.0, store.supersededAddedAt["sng_9"]!!, 0.0)
        assertTrue(store.songs.isEmpty())
        assertTrue(RecentlyAdded.addTimeOverrides(emptyList()).isEmpty())
        RecentlyAdded.extraOverrides = { store.supersededAddedAt }
        assertEquals(mapOf("sng_9" to 5555.0), RecentlyAdded.addTimeOverrides(emptyList()))
    }

    @Test fun writePulledAdoptsPeerDocWholesaleAndNotifies() {
        val f = File(tmp.root, AppleMusicLibraryStore.FILE_NAME)
        val store = AppleMusicLibraryStore(f)
        store.replaceAll(listOf(lib("1")), emptyList(), emptyList(), 1.0)
        var fired = 0
        store.onChanged = { fired++ }
        val peer = """{"schemaVersion":1,"songs":[{"songId":"amlib_i.7","libraryId":"i.7","title":"P","artist":"Q","addedAtMs":1700000000000}],"lastAddedMs":1700000000000}"""
        store.writePulled(peer.toByteArray())
        assertEquals(listOf("amlib_i.7"), store.songs.map { it.songId })
        assertEquals(1, fired)
        assertEquals(peer, f.readText())
        store.writePulled(peer.toByteArray())
        assertEquals(1, fired)
    }

    @Test fun iosShapedDocWithoutNewFieldsStaysByteStableThroughFold() {
        val f = File(tmp.root, AppleMusicLibraryStore.FILE_NAME)
        val ios = """{"schemaVersion":1,"songs":[{"songId":"amlib_i.1","libraryId":"i.1","title":"One","artist":"A","addedAtMs":1700000000000}]}"""
        f.writeText(ios)
        val store = AppleMusicLibraryStore(f)
        AppleMusicLibraryFold.Source(store).resolve(emptyList())
        assertEquals(com.levi.pocketdj.data.PdjJson.lenient.parseToJsonElement(ios),
            com.levi.pocketdj.data.PdjJson.lenient.parseToJsonElement(store.encoded()))
        assertEquals(ios, f.readText())
    }

    @Test fun syncKeyIsInAccountDeletionList() {
        assertEquals("apple-music-library", AppleMusicLibraryFold.SYNC_KEY)
        assertTrue("apple-music-library" in AccountDeletionService.cloudDocKeys)
        assertEquals("pocketdj-apple-music-library.json", AppleMusicLibraryStore.FILE_NAME)
    }

    @Test fun libraryIndexCaptionBuckets() {
        val now = 10_000_000_000.0
        assertEquals("Not indexed yet.", libraryIndexCaption(0.0, now))
        assertEquals("Last indexed just now.", libraryIndexCaption(now - 5_000, now))
        assertEquals("Last indexed 30 min ago.", libraryIndexCaption(now - 30 * 60_000, now))
        assertEquals("Last indexed 3 h ago.", libraryIndexCaption(now - 3 * 3_600_000, now))
        assertEquals("Last indexed 2 d ago.", libraryIndexCaption(now - 2 * 86_400_000, now))
    }
}

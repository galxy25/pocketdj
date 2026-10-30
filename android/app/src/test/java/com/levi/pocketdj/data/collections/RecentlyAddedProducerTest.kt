package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.catalog.ImportedSongsStore
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.screens.history.activityArtUrl
import com.levi.pocketdj.screens.history.buildActivityRows
import com.levi.pocketdj.screens.shazam.AppleMusicRecognitionPort
import com.levi.pocketdj.data.applemusic.AppleMusicResolution
import com.levi.pocketdj.screens.shazam.RecognitionAddController
import com.levi.pocketdj.screens.shazam.RipStart
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RecentlyAddedProducerTest {
    private fun tmp(): File = File.createTempFile("imp", ".json").also { it.delete(); it.deleteOnExit() }

    private fun song(id: String, album: String? = null) =
        ImportedSongsStore.SongEntry(songId = id, title = "T-$id", artist = "A", albumId = album)

    @Test fun importPlanner_albumRowPlusLooseSongsOnly() {
        val adds = RecentlyAdded.importCatalogAdds(
            songs = listOf(
                Triple("s1", "One", "A") to "alb",
                Triple("s2", "Two", "A") to "alb",
                Triple("s3", "Loose", "") to null,
                Triple("s4", "Orphan", "A") to "other-album",
            ),
            albums = listOf(Triple("alb", "Album", "A")),
        )
        assertEquals(listOf("alb", "s3", "s4"), adds.map { it.id })
        assertNull("blank artist becomes null", adds[1].artist)
    }

    @Test fun importStore_firesOnlyForFreshUserAdds() {
        val store = ImportedSongsStore(tmp())
        val got = mutableListOf<List<RecentlyAdded.CatalogAddItem>>()
        store.onUserCatalogAdd = { got += it }
        store.add(
            listOf(song("s1", "alb"), song("s2", "alb"), song("s3")),
            listOf(ImportedSongsStore.AlbumEntry(albumId = "alb", name = "Album", artist = "A", trackIds = listOf("s1", "s2"))),
        )
        assertEquals(listOf("alb", "s3"), got.single().map { it.id })
        store.add(listOf(song("s3"))) // repeat import adds nothing -> no event
        assertEquals(1, got.size)
    }

    @Test fun catalogAddEvent_feedsRecentlyAdded_andRemoveCancels() {
        fun ev(id: String, at: Double, kind: ActivityKind, item: String) =
            ActivityEvent(id = id, at = at, kind = kind, itemId = item)
        val overrides = RecentlyAdded.addTimeOverrides(
            listOf(
                ev("1", 100.0, ActivityKind.CATALOG_ADD, "amrec_9"),
                ev("2", 200.0, ActivityKind.CATALOG_ADD, "imp_1"),
                ev("3", 300.0, ActivityKind.CATALOG_REMOVE, "imp_1"),
            ),
        )
        assertEquals(mapOf("amrec_9" to 100.0), overrides)
    }

    @Test fun recognizer_confirmedAddEmitsCatalogAdd_failureDoesNot() = runTest {
        val scope = TestScope(StandardTestDispatcher(testScheduler))
        var ok = true
        val port = object : AppleMusicRecognitionPort {
            override val available = true
            override suspend fun canContribute() = true
            override val canAdd = true
            override suspend fun resolve(storeId: String?, title: String?, artist: String?): AppleMusicResolution? = null
            override suspend fun addSongToLibrary(storeId: String) = ok
            override suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String) = RipStart.REQUESTED
        }
        val c = RecognitionAddController(scope, port)
        val seen = mutableListOf<Triple<String, String, String>>()
        c.onCatalogAdd = { id, t, a -> seen += Triple(id, t, a) }
        c.add("111", "Song", "Art", null)
        scope.advanceUntilIdle()
        assertEquals(listOf(Triple("amrec_111", "Song", "Art")), seen)
        ok = false
        c.add("222", "Nope", "Art", null)
        scope.advanceUntilIdle()
        assertEquals(1, seen.size)
    }

    @Test fun timelineArt_songUsesAlbum_albumUsesOwn_unresolvedNull() {
        val album = IndexAlbum(id = "alb", artist = "A", name = "Al", coverArt = "https://x/y.jpg")
        val s = IndexSong(id = "s", artist = "A", name = "S", albumId = "alb")
        val cat = MergedCatalog.EMPTY.copy(
            songs = listOf(s), albums = listOf(album),
            songsById = mapOf("s" to s), albumsById = mapOf("alb" to album),
        )
        assertTrue(activityArtUrl("alb", "s", cat)!!.endsWith("y.jpg"))
        assertTrue(activityArtUrl(null, "alb", cat)!!.endsWith("y.jpg"))
        assertNull(activityArtUrl(null, "gone", cat))
        val rows = buildActivityRows(
            listOf(ActivityEvent("e", 1.0, ActivityKind.CATALOG_ADD, "s"), ActivityEvent("f", 2.0, ActivityKind.CATALOG_ADD, "gone")),
            cat,
        )
        assertNull(rows[0].artUrl)
        assertTrue(rows[1].artUrl!!.endsWith("y.jpg"))
    }

    @Test fun importedAlbumTracks_appearInRecentlyAdded() {
        val store = ImportedSongsStore(tmp())
        store.add(
            listOf(song("s1", "alb"), song("s2", "alb")).map { it.copy(addedAtMs = 5000.0) },
            listOf(ImportedSongsStore.AlbumEntry(albumId = "alb", name = "Album", artist = "A", trackIds = listOf("s1", "s2"))),
        )
        val cat = MergedCatalog.merge(listOf(store.syntheticDocument()!!))
        val ids = RecentlyAddedBuilder().songIds(cat, emptyList(), 50)
        assertEquals(setOf("s1", "s2"), ids.toSet())
    }
}

package com.levi.pocketdj.data.favorites

import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.browse.BrowseEngine
import com.levi.pocketdj.screens.browse.BrowseFilters
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.SongRow
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FavoritesActivityTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun wired(): Pair<FavoritesStore, CollectionActivityStore> {
        val activity = CollectionActivityStore(File(tmp.root, "act.json"))
        val f = File(tmp.root, "fav.json")
        val store = FavoritesStore(f, writer = VersionedJsonWriter(f))
        store.onChanged = favoriteActivityRecorder(activity) { id ->
            if (id == "s1") "Tiny Dancer" to "Elton John" else null
        }
        return store to activity
    }

    @Test
    fun oneHeartThenOneUnheartRowPerTap() {
        val (store, activity) = wired()
        store.toggle("s1", null)
        store.toggle("s1", null)
        assertEquals(listOf(ActivityKind.HEART, ActivityKind.UNHEART), activity.events.map { it.kind })
        val heart = activity.events.first()
        assertEquals("s1", heart.itemId)
        assertEquals("Tiny Dancer", heart.itemTitle)
        assertEquals("Elton John", heart.itemArtist)
        assertNull(heart.collectionId)
    }

    @Test
    fun seedRemoteImportAndNoopsWriteNoActivity() {
        val (store, activity) = wired()
        store.applySeed(listOf("a", "b"), version = 1)
        store.applyRemote("c", true, null, 5.0)
        store.importMerging("""{"entries":[{"songId":"d","favorited":true,"atMs":1}]}""")
        store.set("zzz", false, null) // first explicit tombstone IS a user act
        store.set("zzz", false, null) // idempotent
        assertEquals(1, activity.events.size)
        assertEquals(ActivityKind.UNHEART, activity.events.single().kind)
        assertEquals("zzz", activity.events.single().itemId) // unknown to catalog: id-only row
        assertNull(activity.events.single().itemTitle)
    }

    private fun row(id: String) = SongRow(
        song = IndexSong(id = id, artist = "A", name = id),
        albumName = null, source = null, genreCategory = "x", searchKey = id,
    )

    @Test
    fun browseFavoriteFilterAppliesInEngine() {
        val rows = listOf(row("a"), row("b"), row("c"))
        val fav = setOf("b")
        assertEquals(listOf("a", "b", "c"), BrowseEngine.applyFavorites(rows, FavoriteFilter.ANY, fav).map { it.song.id })
        assertEquals(listOf("b"), BrowseEngine.applyFavorites(rows, FavoriteFilter.FAVORITE, fav).map { it.song.id })
        assertEquals(listOf("a", "c"), BrowseEngine.applyFavorites(rows, FavoriteFilter.NOT, fav).map { it.song.id })
    }

    @Test
    fun favoriteFilterIsKindGatedAndSurvivesClauseEdits() {
        val f = BrowseFilters().withFavorite(FavoriteFilter.FAVORITE).withGenres(setOf("Rock"))
        assertEquals(FavoriteFilter.FAVORITE, f.favorite) // clause edits copy(), not rebuild
        assertEquals(1, f.activeCount)
        assertEquals(2, f.activeCount(BrowseKind.SONGS))
        assertEquals(1, f.activeCount(BrowseKind.ALBUMS))
        assertFalse(BrowseFilters().favoriteActive)
        assertTrue(f.favoriteActive)
    }
}

package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CollectionsRecsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun store(): CollectionsStore {
        val s = CollectionsStore(file = File(tmp.root, CollectionsStore.FILE_NAME), now = { 1_750_000_000_000.0 })
        val songs = listOf(
            IndexSong(id = "s1", artist = "Artist", name = "Echo"),
            IndexSong(id = "s2", artist = "Artist", name = "Echo (Deluxe)"),
            IndexSong(id = "s3", artist = "Other", name = "Fresh"),
        )
        val merged = MergedCatalog.merge(listOf(IndexJson(manifest = IndexManifest(sourceName = "My Vinyl"), songs = songs)))
        s.catalogProvider = { merged }
        return s
    }

    @Test fun enabledByDefaultAndForUnknownIds() {
        val s = store()
        val pl = s.createPlaylist("Mix", listOf("s1"))
        assertTrue(s.recommendationsEnabled(pl.id))
        assertTrue("an id that resolves to nothing answers true", s.recommendationsEnabled("nope"))
    }

    @Test fun toggleFromAnIdOfUnknownKindAndOffListIsSortedAndIncludesEmptyCollections() {
        val s = store()
        val pl = s.createPlaylist("beta", listOf("s1"))
        val pk = s.createPocket("Alpha")  // empty on purpose
        assertTrue(s.setRecommendationsEnabled(false, pl.id))
        assertTrue(s.setRecommendationsEnabled(false, pk.id))
        assertFalse(s.setRecommendationsEnabled(false, "nope"))
        assertFalse(s.recommendationsEnabled(pl.id))
        assertFalse(s.recommendationsEnabled(pk.id))
        assertEquals(setOf(pl.id, pk.id), s.recommendationsOffIds())
        assertEquals(listOf("Alpha" to "pocket", "beta" to "playlist"),
            s.recommendationsOffCollections().map { it.name to it.kind })
        // back on: stored as absence (default), and the list empties
        s.setRecommendationsEnabled(true, pl.id)
        assertTrue(s.recommendationsEnabled(pl.id))
        assertEquals(listOf(pk.id), s.recommendationsOffCollections().map { it.id })
        assertEquals(null, s.playlist(pl.id)!!.recsEnabled)
    }

    @Test fun suggestibleCollectionsKeepsRecsOffOnesButDropsEmptyOnes() {
        val s = store()
        val on = s.createPlaylist("On", listOf("s1"))
        val off = s.createPlaylist("Off", listOf("s3"))
        s.createPocket("Empty")
        s.setRecommendationsEnabled(false, off.id)
        val got = s.suggestibleCollections()
        assertEquals(setOf(on.id, off.id), got.map { it.id }.toSet())
        assertEquals(listOf("s1"), got.first { it.id == on.id }.songIds)
        assertEquals("playlist", got.first { it.id == on.id }.kind)
    }

    @Test fun playableIdsForAnyCollectionResolvesEitherKind() {
        val s = store()
        val pl = s.createPlaylist("P", listOf("s1", "s3"))
        assertEquals(listOf("s1", "s3"), s.playableIdsForAnyCollection(pl.id))
        assertEquals(emptyList<String>(), s.playableIdsForAnyCollection("nope"))
    }

    @Test fun suggestionsExcludingMembersDropsMembersAndOtherVersionsAtReadTime() {
        val s = store()
        val pl = s.createPlaylist("P", listOf("s1"))
        // s1 is a member; s2 is another version of the same recording (Echo vs Echo (Deluxe)); s3 is fresh
        assertEquals(listOf("s3"), s.suggestionsExcludingMembers(listOf("s1", "s2", "s3"), pl.id))
        // an empty collection filters nothing
        val empty = s.createPlaylist("Empty")
        assertEquals(listOf("s1", "s3"), s.suggestionsExcludingMembers(listOf("s1", "s3"), empty.id))
    }

    @Test fun membershipMemoFollowsTheStoreRevision() {
        val s = store()
        val pl = s.createPlaylist("P", listOf("s1"))
        assertEquals(listOf("s3"), s.suggestionsExcludingMembers(listOf("s1", "s3"), pl.id))
        s.addSongs(listOf("s3"), AddTarget(AddTarget.Kind.PLAYLIST, pl.id))
        assertEquals(emptyList<String>(), s.suggestionsExcludingMembers(listOf("s1", "s3"), pl.id))
    }

    @Test fun forYouAdapterReadsTheLiveStore() {
        val s = store()
        val pl = s.createPlaylist("P", listOf("s1"))
        val c = s.asForYouCollections()
        assertTrue(c.exists(pl.id))
        assertFalse(c.exists("nope"))
        s.setRecommendationsEnabled(false, pl.id)
        assertFalse(c.recommendationsEnabled(pl.id))
        assertEquals(listOf("s3"), c.suggestionsExcludingMembers(listOf("s1", "s3"), pl.id))
    }
}

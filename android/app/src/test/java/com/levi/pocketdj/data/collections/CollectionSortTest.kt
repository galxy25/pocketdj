package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.SourcePlaylist
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The collection-sort comparator contract (specs/playlists-ui.md §2.3, iOS
 * `CollectionSortOrder`): exact orders + tie-breaks, never-played-sorts-last,
 * neutral source-playlist keys, and the missing-token default.
 */
class CollectionSortTest {

    private fun pocket(
        name: String,
        updatedAt: Double = 0.0,
        lastPlayedAt: Double? = null,
    ) = Pocket(id = "pkt_$name", name = name, updatedAt = updatedAt, lastPlayedAt = lastPlayedAt)

    @Test
    fun name_isCaseInsensitiveAscending() {
        val sorted = CollectionSortOrder.NAME.sorted(
            listOf(pocket("beta"), pocket("Alpha"), pocket("gamma")),
        )
        assertEquals(listOf("Alpha", "beta", "gamma"), sorted.map { it.name })
    }

    @Test
    fun lastUpdated_newestFirst_tieBreaksByName() {
        val sorted = CollectionSortOrder.LAST_UPDATED.sorted(
            listOf(
                pocket("beta", updatedAt = 100.0),
                pocket("alpha", updatedAt = 100.0),
                pocket("old", updatedAt = 50.0),
                pocket("new", updatedAt = 200.0),
            ),
        )
        assertEquals(listOf("new", "alpha", "beta", "old"), sorted.map { it.name })
    }

    @Test
    fun recentlyPlayed_newestFirst_neverPlayedSortsLast_thenUpdatedAt_thenName() {
        val sorted = CollectionSortOrder.RECENTLY_PLAYED.sorted(
            listOf(
                pocket("neverB", updatedAt = 100.0),
                pocket("playedOld", updatedAt = 0.0, lastPlayedAt = 500.0),
                pocket("neverA", updatedAt = 100.0),
                pocket("playedNew", updatedAt = 0.0, lastPlayedAt = 900.0),
                pocket("neverStale", updatedAt = 10.0),
            ),
        )
        assertEquals(
            listOf("playedNew", "playedOld", "neverA", "neverB", "neverStale"),
            sorted.map { it.name },
        )
    }

    @Test
    fun sourcePlaylists_alwaysDegradeToNameOrder() {
        val sources = listOf(
            SourcePlaylist(IndexPlaylist(id = "b", name = "beta"), "S"),
            SourcePlaylist(IndexPlaylist(id = "a", name = "Alpha"), "S"),
        )
        for (order in CollectionSortOrder.entries) {
            assertEquals(
                listOf("Alpha", "beta"),
                order.sortedSourcePlaylists(sources).map { it.playlist.name },
            )
        }
    }

    @Test
    fun fromToken_parsesPersistedTokens_missingOrUnknownIsName() {
        assertEquals(CollectionSortOrder.RECENTLY_PLAYED, CollectionSortOrder.fromToken("recentlyPlayed"))
        assertEquals(CollectionSortOrder.LAST_UPDATED, CollectionSortOrder.fromToken("lastUpdated"))
        assertEquals(CollectionSortOrder.NAME, CollectionSortOrder.fromToken("name"))
        assertEquals(CollectionSortOrder.NAME, CollectionSortOrder.fromToken(null))
        assertEquals(CollectionSortOrder.NAME, CollectionSortOrder.fromToken("wormhole"))
        assertEquals(CollectionSortOrder.NAME, CollectionSortOrder.DEFAULT)
    }
}

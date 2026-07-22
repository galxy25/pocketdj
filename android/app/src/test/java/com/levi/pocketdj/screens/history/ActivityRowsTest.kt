package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The Activity-segment rendering contract (specs/activity-favorites.md §5):
 * exact headline wording per kind incl. the `"a collection"` and raw-id
 * fallbacks, live-catalog-first title precedence, newest-first order, and
 * tap-inert rows for unresolvable item ids.
 */
class ActivityRowsTest {

    private fun event(
        id: String = "e1",
        at: Double = 1_000.0,
        kind: ActivityKind = ActivityKind.ADD,
        itemId: String = "sng_1",
        itemTitle: String? = null,
        collectionName: String? = null,
    ) = ActivityEvent(
        id = id,
        at = at,
        kind = kind,
        itemId = itemId,
        itemTitle = itemTitle,
        collectionId = collectionName?.let { "pkt_x" },
        collectionKind = collectionName?.let { "pocket" },
        collectionName = collectionName,
    )

    private fun catalog(
        songs: List<IndexSong> = emptyList(),
        albums: List<IndexAlbum> = emptyList(),
    ) = MergedCatalog.EMPTY.copy(
        songs = songs,
        albums = albums,
        songsById = songs.associateBy { it.id },
        albumsById = albums.associateBy { it.id },
    )

    // MARK: Headline wording (copy is exact)

    @Test
    fun headlines_perKind_withSnapshotTitleAndCollection() {
        val e = event(itemTitle = "Tiny Dancer", collectionName = "Warmups")
        fun of(kind: ActivityKind) =
            activityHeadline(e.copy(kind = kind), liveSongName = null, liveAlbumName = null)
        assertEquals("Added “Tiny Dancer” to Warmups", of(ActivityKind.ADD))
        assertEquals("Hearted “Tiny Dancer”", of(ActivityKind.HEART))
        assertEquals("Removed heart from “Tiny Dancer”", of(ActivityKind.UNHEART))
        assertEquals("Removed “Tiny Dancer” from Warmups", of(ActivityKind.REMOVE))
    }

    @Test
    fun headline_missingCollectionName_fallsBackToACollection() {
        val e = event(itemTitle = "Tiny Dancer", collectionName = null)
        assertEquals(
            "Added “Tiny Dancer” to a collection",
            activityHeadline(e, liveSongName = null, liveAlbumName = null),
        )
    }

    @Test
    fun headline_rawIdFallback_isUnquoted() {
        val e = event(itemId = "sng_gone", itemTitle = null, collectionName = "Warmups")
        assertEquals(
            "Added sng_gone to Warmups",
            activityHeadline(e, liveSongName = null, liveAlbumName = null),
        )
        // Empty snapshot title is treated as absent too.
        assertEquals(
            "Added sng_gone to Warmups",
            activityHeadline(e.copy(itemTitle = ""), liveSongName = null, liveAlbumName = null),
        )
    }

    @Test
    fun headline_precedence_liveSongBeatsAlbumBeatsSnapshot() {
        val e = event(itemTitle = "Old Snapshot")
        assertEquals(
            "Added “Live Song” to a collection",
            activityHeadline(e, liveSongName = "Live Song", liveAlbumName = "Live Album"),
        )
        assertEquals(
            "Added “Live Album” to a collection",
            activityHeadline(e, liveSongName = null, liveAlbumName = "Live Album"),
        )
        assertEquals(
            "Added “Old Snapshot” to a collection",
            activityHeadline(e, liveSongName = null, liveAlbumName = null),
        )
    }

    // MARK: buildActivityRows

    @Test
    fun rows_areNewestFirst() {
        val events = listOf(
            event(id = "e1", at = 1_000.0),
            event(id = "e2", at = 2_000.0),
            event(id = "e3", at = 3_000.0),
        )
        val rows = buildActivityRows(events, catalog())
        assertEquals(listOf("e3", "e2", "e1"), rows.map { it.eventId })
        assertEquals(3_000L, rows.first().atMs)
    }

    @Test
    fun rows_query_filtersByResolvedTitleOrCollectionName() {
        val song = IndexSong(id = "sng_1", artist = "Elton John", name = "Tiny Dancer")
        val events = listOf(
            event(id = "e1", itemId = "sng_1", collectionName = "Warmups"),
            event(id = "e2", itemId = "sng_2", itemTitle = "Rocket Man", collectionName = "Encores"),
        )
        val cat = catalog(songs = listOf(song))
        // Match on the live-resolved item title.
        assertEquals(listOf("e1"), buildActivityRows(events, cat, "dancer").map { it.eventId })
        // Match on the collection name.
        assertEquals(listOf("e2"), buildActivityRows(events, cat, "Encores").map { it.eventId })
        // Blank query keeps everything (newest first).
        assertEquals(listOf("e2", "e1"), buildActivityRows(events, cat, "").map { it.eventId })
        // No match drops all.
        assertEquals(emptyList<String>(), buildActivityRows(events, cat, "zzz").map { it.eventId })
    }

    @Test
    fun rows_resolveLiveTitles_andTapOnlyForLiveSongs() {
        val song = IndexSong(id = "sng_1", artist = "Elton John", name = "Tiny Dancer")
        val album = IndexAlbum(id = "alb_1", artist = "Elton John", name = "Madman")
        val events = listOf(
            event(id = "e1", itemId = "sng_1", itemTitle = "Stale Name"),
            event(id = "e2", itemId = "alb_1", itemTitle = null),
            event(id = "e3", itemId = "sng_gone", itemTitle = null),
        )
        val rows = buildActivityRows(events, catalog(songs = listOf(song), albums = listOf(album)))

        val bySongId = rows.associateBy { it.eventId }
        // Live song: quoted live name, tappable.
        assertEquals("Added “Tiny Dancer” to a collection", bySongId["e1"]!!.headline)
        assertEquals("sng_1", bySongId["e1"]!!.songId)
        // Album resolves for the title but is NOT a tappable song row.
        assertEquals("Added “Madman” to a collection", bySongId["e2"]!!.headline)
        assertNull(bySongId["e2"]!!.songId)
        // Vanished item: raw id, inert.
        assertEquals("Added sng_gone to a collection", bySongId["e3"]!!.headline)
        assertNull(bySongId["e3"]!!.songId)
    }
}

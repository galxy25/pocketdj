package com.levi.pocketdj.playback

import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.collections.SetlistTrack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Setlist -> sequencer rows. Since PB-1 nothing is resolved or repeat-expanded at build time: the
 * sequencer resolves each row fresh at its turn and loops repeatCount on natural end.
 */
class QueuePlanTest {

    @Test
    fun items_isOneToOne_repeatCountCarriedNotExpanded() {
        val items = QueuePlan.items(
            listOf(
                QueuePlan.QueueEntry("sng_1", repeatCount = 3),
                QueuePlan.QueueEntry("sng_2"),
            ),
        )
        assertEquals(listOf("sng_1", "sng_2"), items.map { it.id })
        assertEquals(listOf(3, null), items.map { it.repeatCount })
    }

    @Test
    fun items_dropEmptyIds_andGiveEveryRowADistinctUid() {
        val items = QueuePlan.items(
            listOf(QueuePlan.QueueEntry(""), QueuePlan.QueueEntry("a"), QueuePlan.QueueEntry("a")),
        )
        assertEquals(2, items.size)
        assertNotEquals(items[0].uid, items[1].uid)
    }

    @Test
    fun items_fillMetadataFromCatalogOnlyWhenEntryHasNone() {
        val items = QueuePlan.items(
            listOf(
                QueuePlan.QueueEntry("a"),
                QueuePlan.QueueEntry("b", title = "Frozen", artist = "FA", lengthMs = 1_000),
            ),
        ) { Triple("Cat $it", "CatArtist", 99_000L) }
        assertEquals("Cat a", items[0].title)
        assertEquals("CatArtist", items[0].artist)
        assertEquals(99_000L, items[0].lengthMs)
        assertEquals("Frozen", items[1].title)
        assertEquals("FA", items[1].artist)
        assertEquals(1_000L, items[1].lengthMs)
    }

    @Test
    fun items_unknownSong_fallsBackToIdAsTitle() {
        assertEquals("sng_x", QueuePlan.items(listOf(QueuePlan.QueueEntry("sng_x"))).single().title)
    }

    @Test
    fun queueIndexForEntry_mapsAroundDroppedEmptyIds_andClamps() {
        val entries = listOf(
            QueuePlan.QueueEntry("a"), QueuePlan.QueueEntry(""), QueuePlan.QueueEntry("b"), QueuePlan.QueueEntry("c"),
        )
        assertEquals(0, QueuePlan.queueIndexForEntry(entries, 0))
        assertEquals(1, QueuePlan.queueIndexForEntry(entries, 2))
        assertEquals(2, QueuePlan.queueIndexForEntry(entries, 3))
        assertEquals(2, QueuePlan.queueIndexForEntry(entries, 99))
        assertEquals(0, QueuePlan.queueIndexForEntry(entries, -4))
    }

    @Test
    fun entriesForSetlist_filtersTextCuesAndEmptyIds_carriesRepeatsAndFrozenMeta() {
        val setlist = Setlist(
            id = "set_1",
            playlistId = "pls_1",
            seed = "s",
            tracks = listOf(
                SetlistTrack(songId = "sng_1", artist = "A", name = "One", lengthMs = 5_000, repeatCount = 2),
                SetlistTrack(name = "mic break", isText = true),
                SetlistTrack(songId = "", artist = "", name = "blank"),
                SetlistTrack(songId = "sng_2", artist = "B", name = "Two"),
            ),
        )
        assertEquals(
            listOf(
                QueuePlan.QueueEntry("sng_1", 2, "One", "A", 5_000),
                QueuePlan.QueueEntry("sng_2", null, "Two", "B", null),
            ),
            QueuePlan.entriesForSetlist(setlist),
        )
    }
}

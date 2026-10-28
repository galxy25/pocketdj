package com.levi.pocketdj.data.recs

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForYouTilesTest {
    private fun col(id: String, name: String, n: Int, kind: String = "playlist") =
        ForYouCollectionInput(id, kind, name, (1..n).map { "$id$it" })

    @Test fun pinnedOrderThenCountDescThenName() {
        val tiles = ForYouTiles.build(
            newReleaseCount = 4, zone = listOf("a"),
            collections = listOf(col("1", "b", 2), col("2", "a", 2), col("3", "z", 9), col("4", "none", 0)),
        )
        assertEquals(listOf("new", "zone", "col-3", "col-2", "col-1"), tiles.map { it.id })
        assertEquals(listOf(true, true, false, false, false), tiles.map { it.isPinned })
        assertEquals(listOf(4, 1, 9, 2, 2), tiles.map { it.count })
        assertEquals(ForYouTiles.NEW_TINT, tiles[0].tintHex)
        assertEquals(ForYouTiles.ZONE_TINT, tiles[1].tintHex)
        assertEquals(ForYouTiles.COLLECTION_TINT, tiles[2].tintHex)
    }

    @Test fun newReleaseSubtitleMatrix() {
        assertEquals("No releases in the last 30 days", ForYouTiles.newReleaseSubtitle(0, 0))
        assertEquals("From artists you play · upcoming", ForYouTiles.newReleaseSubtitle(0, 2))
        assertEquals("From artists you play · last 30 days", ForYouTiles.newReleaseSubtitle(3, 0))
        assertEquals("From artists you play · last 30 days + upcoming", ForYouTiles.newReleaseSubtitle(3, 2))
    }

    @Test fun emptyNoteOnlyWinsWhenNothingIsLiveAndTheNoteIsNonBlank() {
        assertEquals("Connect Apple Music", ForYouTiles.newReleaseSubtitle(0, 0, "Connect Apple Music"))
        assertEquals("No releases in the last 30 days", ForYouTiles.newReleaseSubtitle(0, 0, ""))
        assertEquals("No releases in the last 30 days", ForYouTiles.newReleaseSubtitle(0, 0, null))
        assertEquals("From artists you play · last 30 days", ForYouTiles.newReleaseSubtitle(1, 0, "ignored"))
    }

    @Test fun comingSoonCountSplitsTheNewCount() {
        // 5 total of which 2 upcoming => 3 out now
        val t = ForYouTiles.build(newReleaseCount = 5, comingSoonCount = 2, zone = emptyList(), collections = emptyList())[0]
        assertEquals("From artists you play · last 30 days + upcoming", t.subtitle)
        // all upcoming
        val u = ForYouTiles.build(newReleaseCount = 2, comingSoonCount = 2, zone = emptyList(), collections = emptyList())[0]
        assertEquals("From artists you play · upcoming", u.subtitle)
        // coming-soon larger than total never goes negative
        val w = ForYouTiles.build(newReleaseCount = 1, comingSoonCount = 3, zone = emptyList(), collections = emptyList())[0]
        assertEquals("From artists you play · upcoming", w.subtitle)
    }

    @Test fun zoneSubtitleAndSource() {
        assertEquals("Play a few songs to build your zone", ForYouTiles.zoneSubtitle(0, ForYouTileSource.CLOUD))
        val cloud = ForYouTiles.build(newReleaseCount = 0, zone = listOf("a"), zoneSource = ForYouTileSource.CLOUD, collections = emptyList())[1]
        assertEquals(ForYouTileSource.CLOUD, cloud.source)
        assertEquals("Top picks · recommendation engine", cloud.subtitle)
        assertEquals(ForYouTileSource.ON_DEVICE, ForYouTiles.build(newReleaseCount = 0, zone = emptyList(), collections = emptyList())[0].source)
    }

    @Test fun collectionTileShapes() {
        val t = ForYouTiles.build(0, zone = emptyList(), collections = listOf(col("p", "Pocket", 1, "pocket"), col("l", "List", 2)))
        assertEquals("square.stack", t[3].symbol)
        assertEquals("music.note.list", t[2].symbol)
        assertEquals("Suggested for this pocket", t[3].subtitle)
        assertEquals(ForYouTileKind.COLLECTION, t[2].route.kind)
        assertEquals("l", t[2].route.collectionId)
        assertFalse(t[2].isPinned)
        assertTrue(ForYouTiles.MIN_COLLECTION_SUGGESTIONS == 1)
    }
}

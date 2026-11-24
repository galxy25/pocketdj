package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.discover.DiscoverAddsStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AlbumTrackRowLayoutTest {
    private fun song(
        kw: List<String>? = null, bpm: Double? = 128.4, key: String? = "A minor", camelot: String? = "8A", length: Long? = 215_000,
    ) = IndexSong(
        id = "s1", artist = "Ar", name = "A very long title that wraps", sentimentKeywords = kw,
        bpm = bpm, key = key, camelot = camelot, length = length,
    )

    @Test fun compactBoundaryIs600dp() {
        assertTrue(AlbumTrackRowLayout.isCompact(360))
        assertTrue(AlbumTrackRowLayout.isCompact(599))
        assertFalse(AlbumTrackRowLayout.isCompact(600))
        assertFalse(AlbumTrackRowLayout.isCompact(840))
    }

    @Test fun titleLinesTwoOnPhonesOneOnTablets() {
        assertEquals(2, AlbumTrackRowLayout.titleLines(true))
        assertEquals(1, AlbumTrackRowLayout.titleLines(false))
    }

    @Test fun keywordsTruncateToTwoOnPhonesThreeOnTablets() {
        val s = song(kw = listOf("dreamy", "", "warm", "slow", "late"))
        assertEquals(listOf("dreamy", "warm"), AlbumTrackRowLayout.keywords(s, compact = true))
        assertEquals(listOf("dreamy", "warm", "slow"), AlbumTrackRowLayout.keywords(s, compact = false))
        assertEquals("dreamy · warm", AlbumTrackRowLayout.keywordText(s, compact = true))
    }

    @Test fun noKeywordsMeansNoKeywordText() {
        assertNull(AlbumTrackRowLayout.keywordText(song(kw = null), true))
        assertNull(AlbumTrackRowLayout.keywordText(song(kw = emptyList()), true))
        assertNull(AlbumTrackRowLayout.keywordText(song(kw = listOf(" ", "")), false))
    }

    @Test fun line2OrderIsBpmKeyTimeKeywords() {
        val parts = AlbumTrackRowLayout.line2(song(kw = listOf("a", "b", "c")))
        assertEquals(listOf("128 BPM", "A minor · 8A", "3:35", "a · b"), parts)
    }

    @Test fun line2OmitsMissingPieces() {
        val parts = AlbumTrackRowLayout.line2(song(bpm = null, key = null, camelot = null, length = null))
        assertEquals(listOf("– BPM", "–"), parts)
    }

    @Test fun keyLabelVariants() {
        assertEquals("8A", AlbumTrackRowLayout.keyLabel(song(key = null)))
        assertEquals("A minor", AlbumTrackRowLayout.keyLabel(song(camelot = null)))
        assertEquals("A minor · 8A", AlbumTrackRowLayout.keyLabel(song()))
    }

    @Test fun queueItemsCarryTitleArtistLengthInOrder() {
        val a = song().copy(id = "a")
        val b = song().copy(id = "b", name = "B", length = null)
        val items = AlbumQueueMenu.queueItems(listOf(a, b))
        assertEquals(listOf("a", "b"), items.map { it.id })
        assertEquals("B", items[1].title)
        assertEquals("Ar", items[1].artist)
        assertEquals(215_000L, items[0].lengthMs)
        assertNull(items[1].lengthMs)
    }

    @Test fun queueMenuLabelsAndEmptyHiding() {
        assertEquals("Play next (12)", AlbumQueueMenu.nextLabel(12, album = true))
        assertEquals("Play last", AlbumQueueMenu.lastLabel(1, album = false))
        assertFalse(AlbumQueueMenu.showsQueueRows(0))
        assertTrue(AlbumQueueMenu.showsQueueRows(1))
    }

    @Test fun trackActionsFireNextThenLast() {
        val calls = mutableListOf<Pair<List<String>, Boolean>>()
        val actions = AlbumQueueMenu.trackActions(song()) { items, next -> calls += items.map { it.id } to next }
        assertEquals(listOf("Play next", "Play last"), actions.map { it.label })
        actions.forEach { it.action() }
        assertEquals(listOf(listOf("s1") to true, listOf("s1") to false), calls)
    }

    private fun entry(token: String?) = DiscoverAddsStore.AlbumEntry(albumId = "amrec_album_1", appleMusicId = "1", libraryWrite = token)

    @Test fun libraryStateRetryWhenUnprovenAndWritable() {
        assertEquals(AlbumLibraryState.Kind.RETRY, AlbumLibraryState.of(entry(null), true))
        assertEquals(AlbumLibraryState.Kind.RETRY, AlbumLibraryState.of(entry("Apple Music write failed: x"), true))
    }

    @Test fun libraryStateConfirmedWhenProven() {
        assertEquals(AlbumLibraryState.Kind.CONFIRMED, AlbumLibraryState.of(entry("confirmed"), true))
        assertEquals(AlbumLibraryState.Kind.CONFIRMED, AlbumLibraryState.of(entry("confirmed"), false))
    }

    @Test fun libraryStateNoneForNonProvisionalOrCannotWrite() {
        assertEquals(AlbumLibraryState.Kind.NONE, AlbumLibraryState.of(null, true))
        assertEquals(AlbumLibraryState.Kind.NONE, AlbumLibraryState.of(entry(null), false))
    }
}

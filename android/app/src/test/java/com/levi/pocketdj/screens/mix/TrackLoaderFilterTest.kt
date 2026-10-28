package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.model.MixLoadable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackLoaderFilterTest {
    private val all = listOf(
        MixLoadable("s1", "Blue Monday", "New Order", albumId = "a1"),
        MixLoadable("s2", "Temptation", "New Order", albumId = "a1"),
        MixLoadable("s3", "Cities in Dust", "Siouxsie", albumId = "a2"),
        MixLoadable("s4", "Hurt", "Johnny Cash", albumId = null),
    )
    private val albums = mapOf("a1" to "Substance", "a2" to "Tinderbox")
    private val albumName = { id: String? -> albums[id].orEmpty() }
    private val played = setOf("s1", "s3")
    private val hasPlayed = { id: String -> id in played }

    @Test fun queryMatchesTitleArtistAndAlbum_caseInsensitive() {
        assertEquals(listOf("s1"), TrackLoaderFilter.queried(all, "BLUE", albumName).map { it.songId })
        assertEquals(listOf("s1", "s2"), TrackLoaderFilter.queried(all, "new order", albumName).map { it.songId })
        assertEquals(listOf("s3"), TrackLoaderFilter.queried(all, " tinder ", albumName).map { it.songId })
        assertEquals(all, TrackLoaderFilter.queried(all, "   ", albumName))
    }

    @Test fun autoHideDropsPlayedByDefault() {
        val r = TrackLoaderFilter.apply(all, "", autoHidePlayed = true, showPlayed = false, albumName, hasPlayed)
        assertEquals(listOf("s2", "s4"), r.rows.map { it.songId })
        assertEquals(2, r.hiddenPlayed)
    }

    @Test fun revealShowsEverythingAndCountMatches() {
        val hidden = TrackLoaderFilter.apply(all, "", true, false, albumName, hasPlayed)
        val shown = TrackLoaderFilter.apply(all, "", true, true, albumName, hasPlayed)
        // Flipping the toggle reveals exactly the counted rows.
        assertEquals(hidden.hiddenPlayed, shown.rows.size - hidden.rows.size)
    }

    @Test fun countIsTakenFromTheQueriedSetNotTheWholeCrate() {
        val r = TrackLoaderFilter.apply(all, "new order", true, false, albumName, hasPlayed)
        assertEquals(listOf("s2"), r.rows.map { it.songId })
        assertEquals(1, r.hiddenPlayed)           // s1 only; s3 does not match the query
    }

    @Test fun autoHideOffShowsAllWithZeroHidden() {
        val r = TrackLoaderFilter.apply(all, "", autoHidePlayed = false, showPlayed = false, albumName, hasPlayed)
        assertEquals(4, r.rows.size)
        assertEquals(0, r.hiddenPlayed)
    }

    @Test fun toggleVisibilityAndLabel() {
        assertFalse(TrackLoaderFilter.showToggle(0, false))
        assertTrue(TrackLoaderFilter.showToggle(2, false))
        assertTrue(TrackLoaderFilter.showToggle(0, true))
        assertEquals("Show 2 played", TrackLoaderFilter.toggleLabel(2, false))
        assertEquals("Showing played", TrackLoaderFilter.toggleLabel(2, true))
    }
}

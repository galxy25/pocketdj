package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.applemusic.AmAlbum
import com.levi.pocketdj.data.applemusic.AmSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoverMergeTest {
    private fun hit(id: String, title: String = "t$id", artist: String = "A", url: String? = null, ripped: Boolean? = null) =
        DiscoverHit(appleMusicId = id, title = title, artist = artist, songId = "amrec_$id", url = url, ripped = ripped)

    @Test fun restLeads_serverRowWinsTie_serverOnlyFollows_dedupedByStoreId() {
        val rest = listOf(hit("1"), hit("2"), hit("1", title = "dup"))
        val server = listOf(hit("9"), hit("2", url = "https://r/2.mp3", ripped = true), hit("9", title = "dup9"))
        val out = DiscoverMerge.mergeSongs(rest, server)
        assertEquals(listOf("1", "2", "9"), out.map { it.appleMusicId })
        assertEquals("t1", out[0].title)
        assertEquals("https://r/2.mp3", out[1].url) // server row won the tie
        assertEquals(true, out[1].ripped)
        assertEquals("t9", out[2].title) // first server dup kept
    }

    @Test fun albumsMerge_restWinsTie() {
        fun a(id: String, t: String) = DiscoverAlbumHit(appleMusicId = id, title = t, albumId = "amrec_album_$id")
        val out = DiscoverMerge.mergeAlbums(listOf(a("1", "rest")), listOf(a("1", "srv"), a("2", "srv2")))
        assertEquals(listOf("rest", "srv2"), out.map { it.title })
    }

    @Test fun term_joinsTitleAndArtist_eitherAloneValid_blankIsNull() {
        assertEquals("witchy daft", DiscoverMerge.term(" witchy ", "daft "))
        assertEquals("daft", DiscoverMerge.term("", "daft"))
        assertEquals("witchy", DiscoverMerge.term("witchy", "  "))
        assertNull(DiscoverMerge.term(" ", ""))
    }

    @Test fun refine_isCaseAndDiacriticInsensitiveContainment() {
        val hits = listOf(hit("1", artist = "Daft Punk"), hit("2", artist = "Beyoncé"), hit("3", artist = "Other"))
        assertEquals(listOf("1"), DiscoverMerge.refineSongs(hits, " DAFT ").map { it.appleMusicId })
        assertEquals(listOf("2"), DiscoverMerge.refineSongs(hits, "beyonce").map { it.appleMusicId })
        assertEquals(3, DiscoverMerge.refineSongs(hits, "  ").size)
        assertTrue(DiscoverMerge.refineSongs(hits, "zzz").isEmpty())
    }

    @Test fun addHelp_wording() {
        assertEquals(
            "Save this song to your Apple Music library and prepare your copy",
            DiscoverAddWording.addHelp("song", canAddToLibrary = true, opensInMusic = false),
        )
        assertEquals("Open this album in Music and prepare your copy", DiscoverAddWording.addHelp("album", false, true))
        assertEquals("Prepare your copy", DiscoverAddWording.addHelp("song", false))
    }

    @Test fun amSongMapsToAmrecRow() {
        val h = DiscoverMerge.hit(AmSong("42", "Song", "Art", "Alb", 201.5, explicit = true), ripUrl = "u")
        assertEquals("amrec_42", h.songId)
        assertEquals(201500, h.durationMs)
        assertEquals(true, h.ripped)
        assertEquals(true, h.explicit)
        assertFalse(DiscoverMerge.hit(AmSong("1", "s", "a", null, null)).ripped!!)
    }

    @Test fun amAlbumMapsToProvisionalAlbumId() {
        val h = DiscoverMerge.hit(AmAlbum("77", "LP", "Art", "1999-05-04", 12))
        assertEquals("amrec_album_77", h.albumId)
        assertEquals(1999, h.year)
        assertEquals(12, h.trackCount)
    }
}

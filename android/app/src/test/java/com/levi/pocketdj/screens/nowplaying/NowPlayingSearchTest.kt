package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NowPlayingSearchTest {
    private fun s(id: String, name: String, artist: String = "Art") = IndexSong(id = id, artist = artist, name = name)

    private val songs = listOf(
        s("1", "Neon Lights"),
        s("2", "Bright Neon"),
        s("3", "neon"),
        s("4", "Unrelated", artist = "The Neon Band"),
        s("5", "Nope"),
    )

    @Test fun exactThenPrefixThenContainsThenArtistInCatalogOrder() {
        val ids = NowPlayingSearch.songs("Neon", songs).map { it.id }
        assertEquals(listOf("3", "1", "2", "4"), ids)
    }

    @Test fun emptyOrBlankQueryYieldsNothing() {
        assertTrue(NowPlayingSearch.songs("", songs).isEmpty())
        assertTrue(NowPlayingSearch.songs("   ", songs).isEmpty())
    }

    @Test fun everyTokenMustHitNameOrArtist() {
        assertEquals(listOf("4"), NowPlayingSearch.songs("band neon", songs).map { it.id })
        assertTrue(NowPlayingSearch.songs("neon zzz", songs).isEmpty())
    }

    @Test fun capsPerSection() {
        val many = (0 until 60).map { s("m$it", "love $it") }
        assertEquals(NowPlayingSearch.SONG_CAP, NowPlayingSearch.songs("love", many).size)
        val albums = (0 until 30).map { IndexAlbum(id = "a$it", artist = "x", name = "love $it") }
        assertEquals(NowPlayingSearch.ALBUM_CAP, NowPlayingSearch.albums("love", albums).size)
    }

    @Test fun albumsAndSongsRankedIndependentlyAndAlbumTracklistKeepsOrder() {
        val tracks = listOf(s("t2", "Two"), s("t1", "One"))
        val album = IndexAlbum(id = "al", artist = "A", name = "Love", trackList = listOf("t1", "t2", "ghost"))
        val cat = com.levi.pocketdj.data.catalog.MergedCatalog.EMPTY.copy(
            albums = listOf(album), songs = tracks, albumsById = mapOf("al" to album),
            songsById = tracks.associateBy { it.id },
        )
        val r = NowPlayingSearch.search("love", cat)
        assertEquals(listOf("al"), r.albums.map { it.id })
        assertEquals(listOf("t1", "t2"), NowPlayingSearch.queueItems(album, cat).map { it.id })
    }

    @Test fun queueItemsGetFreshUids() {
        val song = s("x", "X").copy(length = 1234)
        val a = NowPlayingSearch.queueItem(song)
        val b = NowPlayingSearch.queueItem(song)
        assertEquals(1234L, a.lengthMs)
        assertTrue(a.uid != b.uid)
    }
}

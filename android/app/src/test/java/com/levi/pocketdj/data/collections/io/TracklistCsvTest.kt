package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TracklistCsvTest {
    @Test
    fun columns() {
        val text = String(TracklistCsv.data(emptyList()), Charsets.UTF_8)
        assertEquals("#,Title,Artist,Album,Year,Genre,Apple Music,Spotify,YouTube\r\n", text)
    }

    @Test
    fun rowsEscapeAndTerminateWithCrlf() {
        val text = String(
            TracklistCsv.data(listOf(
                TracklistCsv.Row("Hello, World", "The \"Band\"", "Alb", 1999, "Funk", "a", "b", "c"),
                TracklistCsv.Row("Plain", "Solo", "", null, ""),
            )),
            Charsets.UTF_8,
        )
        val lines = text.split("\r\n")
        assertEquals("1,\"Hello, World\",\"The \"\"Band\"\"\",Alb,1999,Funk,a,b,c", lines[1])
        assertEquals("2,Plain,Solo,,,,,,", lines[2])
        assertEquals("", lines[3]) // trailing CRLF
        assertTrue(!text.contains("\n\n"))
    }

    @Test
    fun rowsResolveAlbumYearFallbackAndShareLinks_andDropUnknownIds() {
        val songs = mapOf(
            "s1" to IndexSong(id = "s1", albumId = "a1", artist = "Art", name = "T1", appleMusicId = "42"),
            "s2" to IndexSong(id = "s2", artist = "Art", name = "T2", year = 2010, spotifyUrl = "https://sp/x"),
        )
        val albums = mapOf("a1" to IndexAlbum(id = "a1", artist = "Art", name = "Alb", genre = "Rock", year = 1980))
        val rows = TracklistCsv.rows(listOf("s1", "missing", "s2"), songs, albums)
        assertEquals(2, rows.size)
        assertEquals("Alb", rows[0].album); assertEquals(1980, rows[0].year); assertEquals("Rock", rows[0].genre)
        assertEquals("https://music.apple.com/song/42", rows[0].appleMusicUrl)
        assertTrue(rows[0].spotifyUrl.startsWith("https://open.spotify.com/search/"))   // search link, never blank
        assertEquals(2010, rows[1].year); assertEquals("", rows[1].album)
        assertEquals("https://sp/x", rows[1].spotifyUrl)
        assertTrue(rows[1].youtubeUrl.startsWith("https://music.youtube.com/search"))
    }
}

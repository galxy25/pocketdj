package com.levi.pocketdj.data.share

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Test

class ShareTextTest {
    @Test fun songWithAllLinksUsesCanonical() {
        val s = IndexSong(id = "1", artist = "Daft Punk", name = "Around the World",
            appleMusicUrl = "https://music.apple.com/us/song/x/1", spotifyUrl = "https://open.spotify.com/track/2",
            youtubeUrl = "https://music.youtube.com/watch?v=3", appleMusicId = "999")
        assertEquals(
            "Around the World — Daft Punk\nApple Music: https://music.apple.com/us/song/x/1\n" +
                "Spotify: https://open.spotify.com/track/2\nYouTube: https://music.youtube.com/watch?v=3",
            ShareText.forSong(s),
        )
    }

    @Test fun appleMusicIdDerivedWhenUrlAbsentOrEmpty() {
        val s = IndexSong(id = "1", artist = "A", name = "B", appleMusicId = "123", appleMusicUrl = "")
        assertEquals("Apple Music: https://music.apple.com/song/123", ShareText.forSong(s).lines()[1])
        val a = IndexAlbum(id = "a", artist = "A", name = "B", appleMusicId = "77")
        assertEquals("Apple Music: https://music.apple.com/album/77", ShareText.forAlbum(a).lines()[1])
    }

    @Test fun searchFallbacksPercentEncodeAndCollapseWhitespace() {
        val s = IndexSong(id = "1", artist = "AC/DC", name = "Back  in   Black?")
        assertEquals(
            "Back  in   Black? — AC/DC\n" +
                "Apple Music: https://music.apple.com/search?term=AC%2FDC%20Back%20in%20Black%3F\n" +
                "Spotify: https://open.spotify.com/search/results/AC%2FDC%20Back%20in%20Black%3F\n" +
                "YouTube: https://music.youtube.com/search?q=AC%2FDC%20Back%20in%20Black%3F",
            ShareText.forSong(s),
        )
    }

    @Test fun nonAsciiEncodedAsUtf8AndUnreservedKept() {
        assertEquals("Beyoncé%20a-b_c.d~e", ShareText.query("a-b_c.d~e", "Beyoncé"))
        assertEquals("宇多田ヒカル%20First%20Love%21", ShareText.query("First Love!", "宇多田ヒカル"))
    }

    @Test fun multiSongJoinsWithBlankLine() {
        val a = IndexSong(id = "1", artist = "A", name = "One")
        val b = IndexSong(id = "2", artist = "B", name = "Two")
        val out = ShareText.forSongs(listOf(a, b))
        assertEquals(2, out.split("\n\n").size)
        assertEquals("", ShareText.forSongs(emptyList()))
    }

    @Test fun albumFallbackAndBareTitleArtist() {
        val a = IndexAlbum(id = "a", artist = "X", name = "Y")
        assertEquals("Y — X", ShareText.forAlbum(a).lines()[0])
        assertEquals("Spotify: https://open.spotify.com/search/results/X%20Y", ShareText.forAlbum(a).lines()[2])
        assertEquals(ShareText.forSong(IndexSong(id = "z", artist = "X", name = "Y")), ShareText.forTitleArtist("Y", "X"))
    }
}

package com.levi.pocketdj.mix.store

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.mix.ReplayLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MixSessionCsvTest {
    private val alb = IndexAlbum(id = "a1", artist = "Art", name = "The Album", genre = "Funk", year = 1977)
    private val s1 = IndexSong(id = "s1", albumId = "a1", artist = "Art", name = "Hello, World", spotifyUrl = "https://open.spotify.com/track/x")
    private val s2 = IndexSong(id = "s2", albumId = null, artist = "Solo", name = "Plain", year = 2001)

    @Test
    fun playedTracksInOrderWithIosColumns() {
        val text = String(MixSessionCsv.bytes(listOf("s2", "ghost", "s1"), mapOf("s1" to s1, "s2" to s2), mapOf("a1" to alb)), Charsets.UTF_8)
        val lines = text.split("\r\n")
        assertEquals("#,Title,Artist,Album,Year,Genre,Apple Music,Spotify,YouTube", lines[0])
        assertTrue(lines[1].startsWith("1,Plain,Solo,,2001,,"))
        // ghost (not in catalog) is dropped; numbering stays contiguous; album year/genre fill in.
        assertTrue(lines[2].startsWith("2,\"Hello, World\",Art,The Album,1977,Funk,"))
        assertTrue(lines[2].contains("https://open.spotify.com/track/x"))
        assertEquals("", lines[3])
        assertEquals(4, lines.size)
    }

    @Test
    fun emptySessionIsHeaderOnly() {
        val text = String(MixSessionCsv.bytes(emptyList(), emptyMap(), emptyMap()), Charsets.UTF_8)
        assertEquals("#,Title,Artist,Album,Year,Genre,Apple Music,Spotify,YouTube\r\n", text)
    }

    @Test
    fun filenameStripsReservedAndFallsBack() {
        assertEquals("Session 3.csv", MixSessionCsv.filename("Session 3"))
        assertEquals("ABC.csv", MixSessionCsv.filename("A/B\\C"))
        assertEquals("a b.csv", MixSessionCsv.filename("a:*?\"<>| b"))
        assertEquals("session.csv", MixSessionCsv.filename("  ///  "))
        assertEquals("session.csv", MixSessionCsv.filename(null))
    }

    @Test
    fun wrappedLayoutBreakpoints() {
        assertEquals(1, ReplayLayout.perRow(411))
        assertEquals(1, ReplayLayout.perRow(599))
        assertEquals(3, ReplayLayout.perRow(600))
        assertEquals(3, ReplayLayout.perRow(899))
        assertEquals(5, ReplayLayout.perRow(1280))
        assertFalse(ReplayLayout.isWrapped(500))
        assertTrue(ReplayLayout.isWrapped(600))
        assertEquals(listOf(listOf(1, 2, 3), listOf(4, 5, 6), listOf(7)), ReplayLayout.rows((1..7).toList(), 3))
        assertEquals(listOf(listOf(1), listOf(2)), ReplayLayout.rows(listOf(1, 2), 0))
    }

    private fun ev(kind: MixEventKind, song: String?, t: Int = 1500) = MixSessionEvent(id = "e1", tMs = t, kind = kind, songId = song)

    @Test
    fun loadCardOpensMetadataOthersJump() {
        val inCat = { id: String -> id == "s1" }
        assertEquals(ReplayLayout.Tap.Metadata("s1"), ReplayLayout.tap(ev(MixEventKind.Load, "s1"), inCat))
        // Load whose song left the catalog falls back to a jump (iOS handleTap).
        assertEquals(ReplayLayout.Tap.Jump(1500), ReplayLayout.tap(ev(MixEventKind.Load, "gone"), inCat))
        assertEquals(ReplayLayout.Tap.Jump(1500), ReplayLayout.tap(ev(MixEventKind.Load, null), inCat))
        assertEquals(ReplayLayout.Tap.Jump(900), ReplayLayout.tap(ev(MixEventKind.Play, "s1", 900), inCat))
    }
}

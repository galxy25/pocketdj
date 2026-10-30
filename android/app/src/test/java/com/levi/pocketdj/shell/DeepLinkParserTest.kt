package com.levi.pocketdj.shell

import org.junit.Assert.assertEquals
import org.junit.Test

class DeepLinkParserTest {
    private val base = "https://jukebox.pocket-dj.com"
    private fun p(u: String?, n: String? = null, m: String? = null) = DeepLinkParser.parse(u, n, m)

    @Test fun table() {
        val cases: List<Pair<String?, DeepLink>> = listOf(
            "pocketdj://jukebox/exmkrd5a" to DeepLink.JukeboxJoin("exmkrd5a", null),
            "pocketdj:///jukebox/exmkrd5a" to DeepLink.JukeboxJoin("exmkrd5a", null),
            "POCKETDJ://JUKEBOX/exmkrd5a" to DeepLink.JukeboxJoin("exmkrd5a", null),
            "$base/exmkrd5a/" to DeepLink.JukeboxJoin("exmkrd5a", base),
            "$base/exmkrd5a" to DeepLink.JukeboxJoin("exmkrd5a", base),
            "$base/exmkrd5a/state.json" to DeepLink.JukeboxJoin("exmkrd5a", base),
            "http://jukebox.pocket-dj.com/exmkrd5a/" to DeepLink.JukeboxJoin("exmkrd5a", base),
            "$base/mwf/abcd2345/" to DeepLink.Mwf("abcd2345", base),
            "pocketdj://mwf/abcd2345" to DeepLink.Mwf("abcd2345", null),
            "pocketdj:///mwf/abcd2345" to DeepLink.Mwf("abcd2345", null),
            "$base/mwf/" to DeepLink.None,
            "pocketdj://artist/AC%2FDC" to DeepLink.Navigate(ShellRoute.Artist("AC/DC")),
            "pocketdj://artist/a+b" to DeepLink.Navigate(ShellRoute.Artist("a+b")),
            "pocketdj://jukebox/abc" to DeepLink.None,          // 3 chars
            "pocketdj://jukebox/${"a".repeat(33)}" to DeepLink.None,
            "pocketdj://jukebox/${"a".repeat(32)}" to DeepLink.JukeboxJoin("a".repeat(32), null),
            "pocketdj://jukebox/ABCDEFGH" to DeepLink.None,     // uppercase
            "pocketdj://jukebox/abcd1890" to DeepLink.None,     // digits outside 2-7
            "pocketdj://jukebox" to DeepLink.None,
            "https://example.com/exmkrd5a/" to DeepLink.None,
            "https://jukebox.pocket-dj.com/" to DeepLink.None,
            "musicsdk://com.levi.pocketdj/authenticateresult?token=x" to DeepLink.None,
            "not a url" to DeepLink.None,
            "" to DeepLink.None,
            null to DeepLink.None,
        )
        for ((url, expected) in cases) assertEquals("url=$url", expected, p(url))
    }

    @Test fun playLinks() {
        assertEquals(DeepLink.Play(PlayKind.Playlist, "pl1", true), p("pocketdj://play/playlist/pl1?shuffle=1"))
        assertEquals(DeepLink.Play(PlayKind.Playlist, "pl1", false), p("pocketdj://play/playlist/pl1?shuffle=0"))
        assertEquals(DeepLink.Play(PlayKind.Pocket, "pk", false), p("pocketdj://play/pocket/pk"))
        assertEquals(DeepLink.Play(PlayKind.Setlist, "s", true), p("pocketdj:///play/setlist/s?shuffle=true"))
        assertEquals(DeepLink.Play(PlayKind.Playlist, "my list", false), p("pocketdj://play/playlist/my%20list"))
        assertEquals(DeepLink.None, p("pocketdj://play/bogus/x"))
        assertEquals(DeepLink.None, p("pocketdj://play/playlist"))
    }

    @Test fun navigateLinks() {
        assertEquals(DeepLink.Navigate(ShellRoute.Album("a1")), p("pocketdj://album/a1"))
        assertEquals(DeepLink.Navigate(ShellRoute.Artist("Daft Punk")), p("pocketdj://artist/Daft%20Punk"))
        assertEquals(DeepLink.Navigate(ShellRoute.Playlist("p")), p("pocketdj://playlist/p"))
        assertEquals(DeepLink.Navigate(ShellRoute.Pocket("k")), p("pocketdj://pocket/k"))
        assertEquals(DeepLink.Navigate(ShellRoute.Setlist("s", true)), p("pocketdj://setlist/s?autoplay=1"))
        assertEquals(DeepLink.Navigate(ShellRoute.Setlist("s", false)), p("pocketdj://setlist/s"))
        assertEquals(DeepLink.Navigate(ShellRoute.BrowseSearch("daft punk")), p("pocketdj://search?q=daft%20punk"))
        assertEquals(DeepLink.Navigate(ShellRoute.BrowseSearch("x")), p("pocketdj://search/x"))
        assertEquals(DeepLink.None, p("pocketdj://search"))
        assertEquals(DeepLink.None, p("pocketdj://unknown/x"))
    }

    @Test fun fileOpens() {
        assertEquals(DeepLink.CollectionFile("content://x/1"), p("content://x/1", n = "My Crate.pdjcollection"))
        assertEquals(DeepLink.CollectionFile("content://x/1"), p("content://x/1", n = "pocket.pocketdj.zip"))
        assertEquals(DeepLink.CollectionFile("content://x/1"), p("content://x/1", n = "legacy.ZIP"))
        assertEquals(DeepLink.CollectionFile("content://x/1"), p("content://x/1", m = "application/x-pocketdj-collection"))
        assertEquals(DeepLink.CollectionFile("file:///sdcard/Download/a.pdjcollection"), p("file:///sdcard/Download/a.pdjcollection"))
        assertEquals(DeepLink.DiagKey("content://x/2"), p("content://x/2", n = "diag.pdjdiagkey"))
        assertEquals(DeepLink.None, p("content://x/3", n = "song.mp3"))
        assertEquals(DeepLink.None, p("content://x/4"))
    }

    @Test fun gamesPuzzleLink() {
        assertEquals(DeepLink.Game(GameLink.Puzzle), DeepLinkParser.parse("pocketdj://games/puzzle"))
        assertEquals(DeepLink.Game(GameLink.Puzzle), DeepLinkParser.parse("pocketdj:///games/Puzzle"))
    }

    @Test fun gamesInThePocketLink() {
        assertEquals(DeepLink.Game(GameLink.InThePocket), DeepLinkParser.parse("pocketdj://games/inthepocket"))
        assertEquals(DeepLink.Game(GameLink.InThePocket), DeepLinkParser.parse("pocketdj://games/in-the-pocket"))
    }

    @Test fun gamesBareOpensTabAndUnknownGameIsNone() {
        assertEquals(
            DeepLink.Navigate(ShellRoute.Tab(com.levi.pocketdj.navigation.PocketDjDestination.Games)),
            DeepLinkParser.parse("pocketdj://games"),
        )
        assertEquals(DeepLink.None, DeepLinkParser.parse("pocketdj://games/chess"))
    }
}

package com.levi.pocketdj.shell

import com.levi.pocketdj.navigation.PocketDjDestination
import org.junit.Assert.assertEquals
import org.junit.Test

class ShellRouteResolverTest {
    private class Fake(
        val albums: Set<String> = emptySet(),
        val playlists: Set<String> = emptySet(),
        val pockets: Set<String> = emptySet(),
        val setlists: Set<String> = emptySet(),
        val sources: Set<String> = emptySet(),
        val joined: Set<String> = emptySet(),
    ) : RouteLookup {
        override fun albumExists(id: String) = id in albums
        override fun playlistExists(id: String) = id in playlists
        override fun pocketExists(id: String) = id in pockets
        override fun setlistExists(id: String) = id in setlists
        override fun sourcePlaylistExists(id: String) = id in sources
        override fun jukeboxSessionJoined(id: String) = id in joined
    }

    @Test
    fun unknownAlbum_isRouteMessageWithIosText() {
        val r = ShellRouteResolver.resolve(ShellRoute.Album("nope"), Fake())
        assertEquals(RouteMessage("That album isn't in your library."), r)
    }

    @Test
    fun knownPocket_switchesToCollectionsAndPushes() {
        val r = ShellRouteResolver.resolve(ShellRoute.Pocket("p1"), Fake(pockets = setOf("p1")))
        assertEquals(NavCommand(PocketDjDestination.Playlists, ShellRoute.Pocket("p1")), r)
    }

    @Test
    fun deletedCollections_neverBlank_alwaysAMessage() {
        val lookup = Fake()
        listOf(
            ShellRoute.Playlist("x"), ShellRoute.Pocket("x"), ShellRoute.Setlist("x"),
            ShellRoute.SourcePlaylist("x", "Vinyl"), ShellRoute.JukeboxJoin("x"),
        ).forEach { route ->
            val r = ShellRouteResolver.resolve(route, lookup)
            assert(r is RouteMessage) { "$route resolved to $r" }
        }
    }

    @Test
    fun browseSearch_setsPendingQuery_onBrowseWithoutPush() {
        val r = ShellRouteResolver.resolve(ShellRoute.BrowseSearch("aphex"), Fake())
        assertEquals(NavCommand(PocketDjDestination.Browse, null, "aphex"), r)
    }

    @Test
    fun tabAndArtistRoutes_resolveUnconditionally() {
        assertEquals(
            NavCommand(PocketDjDestination.Games),
            ShellRouteResolver.resolve(ShellRoute.Tab(PocketDjDestination.Games), Fake()),
        )
        assertEquals(
            NavCommand(PocketDjDestination.Browse, ShellRoute.Artist("Boards of Canada")),
            ShellRouteResolver.resolve(ShellRoute.Artist("Boards of Canada"), Fake()),
        )
    }

    @Test
    fun navLayout_barBelow600_railFrom600() {
        assertEquals(ShellNavLayout.Bar, navLayoutFor(360))
        assertEquals(ShellNavLayout.Bar, navLayoutFor(599))
        assertEquals(ShellNavLayout.Rail, navLayoutFor(600))
        assertEquals(ShellNavLayout.Rail, navLayoutFor(1280))
    }
}

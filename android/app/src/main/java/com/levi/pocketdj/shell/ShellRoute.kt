package com.levi.pocketdj.shell

import com.levi.pocketdj.navigation.PocketDjDestination

/**
 * A navigation request from anywhere out of the UI tree (widgets, shortcuts, deep links,
 * the Up Next collection button, Assistant). iOS `IntentRoute` + jukebox/MwF opens.
 */
sealed interface ShellRoute {
    data class Tab(val destination: PocketDjDestination) : ShellRoute
    data class Album(val id: String) : ShellRoute
    data class Artist(val name: String) : ShellRoute
    data class Playlist(val id: String) : ShellRoute
    data class Pocket(val id: String) : ShellRoute
    data class Setlist(val id: String, val autoplay: Boolean = false) : ShellRoute
    data class SourcePlaylist(val id: String, val sourceName: String) : ShellRoute
    data class JukeboxJoin(val id: String) : ShellRoute

    /** Land on Browse and park [query] for its search field (iOS `pendingBrowseQuery`). */
    data class BrowseSearch(val query: String) : ShellRoute
}

/** What the shell must do for a route: the pure output of [ShellRouteResolver]. */
sealed interface RouteResolution

/**
 * Switch to [tab] NOW; stage [push] (a detail route) after the tab-switch frame;
 * [pendingBrowseQuery] is handed to Browse's search field.
 */
data class NavCommand(
    val tab: PocketDjDestination,
    val push: ShellRoute? = null,
    val pendingBrowseQuery: String? = null,
) : RouteResolution

/** The route cannot resolve — show "Can't open that" with [text]; never a blank screen. */
data class RouteMessage(val text: String) : RouteResolution

/** Existence checks the resolver needs (backed by catalog/collections in the shell). */
interface RouteLookup {
    fun albumExists(id: String): Boolean
    fun playlistExists(id: String): Boolean
    fun pocketExists(id: String): Boolean
    fun setlistExists(id: String): Boolean
    fun sourcePlaylistExists(id: String): Boolean
    fun jukeboxSessionJoined(id: String): Boolean
}

object ShellRouteResolver {
    const val ALERT_TITLE = "Can't open that"

    /**
     * Mirrors RootView.consumeIntentRoute: the SECTION always lands (even when the target
     * is gone, the user ends up at the section home) and a missing target yields a message.
     * Missing-album text is the iOS string verbatim; the others follow its voice.
     */
    fun resolve(route: ShellRoute, lookup: RouteLookup): RouteResolution = when (route) {
        is ShellRoute.Tab -> NavCommand(route.destination)
        is ShellRoute.Album ->
            if (lookup.albumExists(route.id)) NavCommand(PocketDjDestination.Browse, route)
            else RouteMessage("That album isn't in your library.")
        // iOS pushes an Artist(name:) unconditionally; the artist screen handles empty.
        is ShellRoute.Artist -> NavCommand(PocketDjDestination.Browse, route)
        is ShellRoute.Playlist ->
            if (lookup.playlistExists(route.id)) NavCommand(PocketDjDestination.Playlists, route)
            else RouteMessage("That playlist no longer exists.")
        is ShellRoute.Pocket ->
            if (lookup.pocketExists(route.id)) NavCommand(PocketDjDestination.Playlists, route)
            else RouteMessage("That pocket no longer exists.")
        is ShellRoute.Setlist ->
            if (lookup.setlistExists(route.id)) NavCommand(PocketDjDestination.Playlists, route)
            else RouteMessage("That set list no longer exists.")
        is ShellRoute.SourcePlaylist ->
            if (lookup.sourcePlaylistExists(route.id)) NavCommand(PocketDjDestination.Playlists, route)
            else RouteMessage("That playlist isn't available any more.")
        is ShellRoute.JukeboxJoin ->
            if (lookup.jukeboxSessionJoined(route.id)) NavCommand(PocketDjDestination.Jukebox, route)
            else RouteMessage("That jukebox session isn't in your joined list.")
        is ShellRoute.BrowseSearch ->
            NavCommand(PocketDjDestination.Browse, pendingBrowseQuery = route.query)
    }
}

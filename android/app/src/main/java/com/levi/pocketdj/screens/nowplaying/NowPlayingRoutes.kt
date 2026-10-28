package com.levi.pocketdj.screens.nowplaying

import androidx.navigation.compose.composable
import com.levi.pocketdj.shell.NavEntry

/** The pushed Now Playing route (the iOS home deck). */
const val NOW_PLAYING_ROUTE = "nowplaying"

/** The Now Playing nav-entry list `PlaybackGraph` consumes. */
object NowPlayingRoutes {
    val entries: List<NavEntry> = listOf(
        NavEntry(NOW_PLAYING_ROUTE) { _ ->
            composable(NOW_PLAYING_ROUTE) { NowPlayingScreen() }
        },
    )
}

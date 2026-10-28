package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.shell.NavEntry

/**
 * The Now Playing nav-entry list `PlaybackGraph` consumes. Empty by design in PB-1: PB-6 adds the
 * `nowplaying` route here (and nowhere else), so it never edits the playback sidecar.
 */
object NowPlayingRoutes {
    val entries: List<NavEntry> = emptyList()
}

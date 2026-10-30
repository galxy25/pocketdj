package com.levi.pocketdj.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.QrCode2
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.Tune
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * The seven top-level destinations (iOS `RootView.Section` parity). [phase] is the
 * product-roadmap phase in which each screen becomes real; placeholders advertise it.
 *
 * [token] is the persisted `lastSection` string. It is the iOS `Section.rawValue` and is
 * PINNED: "Performance" stays the Producer token forever, "Playlists" stays Collections.
 */
enum class PocketDjDestination(
    val route: String,
    val label: String,
    val phase: Int,
    val icon: ImageVector,
    val token: String,
) {
    Browse("browse", "Browse", 1, Icons.Filled.LibraryMusic, "Browser"),
    History("history", "History", 1, Icons.Filled.History, "History"),
    Jukebox("jukebox", "Jukebox", 1, Icons.Filled.QrCode2, "Jukebox Hero"),
    // Tab LABEL is "Collections" (iOS parity); the route/enum id stays "playlists"
    // so navigation and every internal reference are unaffected.
    Playlists("playlists", "Collections", 2, Icons.AutoMirrored.Filled.QueueMusic, "Playlists"),
    Mix("mix", "Mix", 3, Icons.Filled.Tune, "Mix"),
    Producer("producer", "Producer", 4, Icons.Filled.GraphicEq, "Performance"),
    Games("games", "Games", 5, Icons.Filled.SportsEsports, "Games");

    companion object {
        /** Every top-level destination (routes, lastSection tokens), in pinned order. */
        val bottomNav: List<PocketDjDestination> = entries.toList()

        /** Q7 (Levi 2026-10-29): the bar shows these three, then a "More" tab. */
        val barTabs: List<PocketDjDestination> = listOf(Browse, History, Playlists)

        /** Q7: folded into the "More" tab, in this order. */
        val moreTabs: List<PocketDjDestination> = listOf(Jukebox, Games, Mix, Producer)

        /** Cold launch with nothing (valid) persisted lands here — iOS 2026-07-22. */
        val default: PocketDjDestination = History

        /** Token → destination; unknown, blank or the old iOS home-menu "" ⇒ [default]. */
        fun fromToken(token: String?): PocketDjDestination =
            entries.firstOrNull { it.token == token } ?: default
    }
}

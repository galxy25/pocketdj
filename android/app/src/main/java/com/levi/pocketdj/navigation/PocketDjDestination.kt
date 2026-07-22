package com.levi.pocketdj.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.QrCode2
import androidx.compose.material.icons.filled.Tune
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * The six top-level bottom-navigation destinations. [phase] is the product-roadmap
 * phase in which each screen becomes real; placeholders advertise it until then.
 */
enum class PocketDjDestination(
    val route: String,
    val label: String,
    val phase: Int,
    val icon: ImageVector,
) {
    Browse("browse", "Browse", 1, Icons.Filled.LibraryMusic),
    History("history", "History", 1, Icons.Filled.History),
    Jukebox("jukebox", "Jukebox", 1, Icons.Filled.QrCode2),
    // Tab LABEL is "Collections" (iOS parity); the route/enum id stays "playlists"
    // so navigation and every internal reference are unaffected.
    Playlists("playlists", "Collections", 2, Icons.AutoMirrored.Filled.QueueMusic),
    Mix("mix", "Mix", 3, Icons.Filled.Tune),
    Producer("producer", "Producer", 4, Icons.Filled.GraphicEq);

    companion object {
        /** Bottom-nav order, left to right. */
        val bottomNav: List<PocketDjDestination> = entries.toList()
    }
}

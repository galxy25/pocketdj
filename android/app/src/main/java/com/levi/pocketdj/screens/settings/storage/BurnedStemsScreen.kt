package com.levi.pocketdj.screens.settings.storage

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.di.AppGraph

/** Storage > Stems by artist: deletes only the stem files; burned audio and beat grids stay. */
@Composable
fun BurnedStemsScreen() {
    val context = LocalContext.current
    val graph = remember(context) { AppGraph.get(context) }
    BurnedListScreen(
        title = "Stems by artist",
        caption = "Tap an artist to delete their separated stems. The downloaded songs themselves are kept.",
        load = { StorageLists.fromArtists(graph.storageService.stemUsageByArtist(), noun = "songs with stems") },
        delete = { graph.storageService.deleteStems(it.songIds) },
        tag = "storage-burned-stems",
    )
}

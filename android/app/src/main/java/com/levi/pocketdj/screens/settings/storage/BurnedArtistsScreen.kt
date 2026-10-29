package com.levi.pocketdj.screens.settings.storage

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.di.AppGraph

/** Storage > Burned music by artist (iOS StorageView parity): tap an artist to delete their downloads. */
@Composable
fun BurnedArtistsScreen() {
    val context = LocalContext.current
    val graph = remember(context) { AppGraph.get(context) }
    BurnedListScreen(
        title = "Burned music by artist",
        caption = "Tap an artist to delete their downloaded songs. Songs stay in your library and collections.",
        load = { StorageLists.fromArtists(graph.storageService.burnUsageByArtist()) },
        delete = { graph.storageService.deleteBurns(it.songIds) },
        tag = "storage-burned-artists",
    )
}

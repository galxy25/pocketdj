package com.levi.pocketdj.screens.settings.storage

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.levi.pocketdj.di.AppGraph

/** Storage > Burned music by collection (pockets + playlists, A-Z). */
@Composable
fun BurnedCollectionsScreen() {
    val context = LocalContext.current
    val graph = remember(context) { AppGraph.get(context) }
    BurnedListScreen(
        title = "Burned music by collection",
        caption = "Tap a pocket or playlist to delete the downloads of its songs. Collections are kept.",
        load = { loadBurnedCollections(graph) },
        delete = { graph.storageService.deleteBurns(it.songIds) },
        tag = "storage-burned-collections",
    )
}

internal suspend fun loadBurnedCollections(graph: AppGraph): List<UsageRow> {
    val col = graph.collections
    val st = col.state.value
    val named = st.pockets.map { it.name to col.songIdsForPocket(it.id) } +
        st.playlists.map { it.name to col.songIdsForPlaylist(it.id) }
    return StorageLists.fromCollections(
        named,
        readyOf = { graph.servicesGraph.burnStore.readyBurnedIds(it) },
        bytesOf = { graph.storageService.approximateBurnBytes(it) },
    )
}

package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.search.OnlineSearchModel
import com.levi.pocketdj.data.search.OnlineSearchUi
import com.levi.pocketdj.data.search.SearchHit

/**
 * Hit -> row mapping (iOS `OnlineSearchModel.map`): prefer the full catalog item (cover art,
 * lengths, ids) and fall back to a stub built from the hit's own fields, so a hit the local
 * catalog doesn't carry still renders.
 */
internal fun SearchHit.toAlbumRow(catalog: MergedCatalog): AlbumRow {
    val src = catalog.sourceOfAlbum[id] ?: source
    val album = catalog.albumsById[id] ?: IndexAlbum(
        id = id, artist = artist.orEmpty(), name = title.orEmpty(), genre = genre, year = year,
    )
    return AlbumRow(album, src, Genre.category(album.genre ?: genre), searchKey = "")
}

internal fun SearchHit.toSongRow(catalog: MergedCatalog): SongRow {
    val src = catalog.sourceOfSong[id] ?: source
    val song = catalog.songsById[id] ?: IndexSong(
        id = id, albumId = albumId, artist = artist.orEmpty(), name = title.orEmpty(),
        trackNumber = trackNumber, year = year, explicit = explicit, bpm = bpm, key = key, camelot = camelot,
    )
    val albumName = song.albumId?.let { catalog.albumsById[it]?.name } ?: album
    val genreCat = Genre.category(song.albumId?.let { catalog.albumsById[it]?.genre } ?: genre)
    return SongRow(song, albumName, src, genreCat, searchKey = "")
}

/** Header noun/count for the online result set ("1,234 songs"): exact server total. */
internal fun onlineCountLabel(ui: OnlineSearchUi, kind: BrowseKind): String {
    val noun = if (kind == BrowseKind.ALBUMS) "albums" else "songs"
    return "%,d %s".format(ui.total, noun)
}

/** Online results list/grid with infinite scroll (loadMore fires from the last row). */
@Composable
internal fun OnlineResults(
    ui: OnlineSearchUi,
    kind: BrowseKind,
    layout: AlbumLayout,
    catalog: MergedCatalog,
    onLoadMore: () -> Unit,
    onOpenAlbum: (String) -> Unit,
    onOpenSong: (String) -> Unit,
    onAddSong: (String) -> Unit,
    onAddAlbum: (String) -> Unit,
    onPlaySong: (String) -> Unit,
) {
    val failed = ui.state as? OnlineSearchModel.State.Failed
    when {
        failed != null -> EmptyState(failed.message)
        ui.state == OnlineSearchModel.State.Loading || ui.state == OnlineSearchModel.State.Idle -> Box(
            Modifier.fillMaxSize(), contentAlignment = Alignment.Center,
        ) { CircularProgressIndicator() }
        ui.hits.isEmpty() -> EmptyState("No matches — adjust search or filters")
        kind == BrowseKind.ALBUMS && layout == AlbumLayout.GRID -> LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 150.dp),
            contentPadding = PaddingValues(12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(ui.hits, key = { it.id }) { hit ->
                val row = hit.toAlbumRow(catalog)
                AlbumGridCard(row, onClick = { onOpenAlbum(hit.id) }, onLongClick = { onAddAlbum(hit.id) })
            }
            if (ui.hasMore) item(key = "pager", span = { GridItemSpan(maxLineSpan) }) {
                OnlinePager(ui.loadedCount, onLoadMore)
            }
        }
        else -> LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(ui.hits, key = { it.id }) { hit ->
                if (kind == BrowseKind.ALBUMS) {
                    AlbumListRow(
                        hit.toAlbumRow(catalog),
                        onClick = { onOpenAlbum(hit.id) },
                        onLongClick = { onAddAlbum(hit.id) },
                    )
                } else {
                    BrowseSongRow(
                        row = hit.toSongRow(catalog),
                        onClick = { onOpenSong(hit.id) },
                        onPlay = { onPlaySong(hit.id) },
                        onLongClick = { onAddSong(hit.id) },
                    )
                }
            }
            if (ui.hasMore) item(key = "pager") { OnlinePager(ui.loadedCount, onLoadMore) }
        }
    }
}

/** Sentinel: requests the next server page when it composes (keyed by the loaded offset). */
@Composable
private fun OnlinePager(loadedCount: Int, onLoadMore: () -> Unit) {
    LaunchedEffect(loadedCount) { onLoadMore() }
    Box(Modifier.fillMaxWidth().height(48.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
    }
}

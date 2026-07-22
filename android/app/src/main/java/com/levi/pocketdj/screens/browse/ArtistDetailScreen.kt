package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.artists.ArtistCatalog
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlayContext
import kotlinx.coroutines.launch

/**
 * Artist detail (specs/artists.md §6) — one artist's discography (albums list) +
 * ▶ Play all / 🔀 Shuffle all over the whole discography. The discography is
 * re-derived from the live catalog on every render by case-insensitive name
 * match (§6.1), the SAME predicate the Browse grouping uses, so the detail never
 * shows a subset of what the row's counts promised.
 *
 * Play all / Shuffle all route the flat, non-deduped, non-resolved discography
 * ids through the reserved Now Playing setlist attributed to History as
 * `artist` (§6.3, §9) — the identical funnel as source-playlist Shuffle. The
 * integrator navigates here with the artist display name and wires [onOpenAlbum]
 * / [onOpenSetlist] (specs/artists.md §7).
 */
@Composable
fun ArtistDetailScreen(
    artistName: String,
    onOpenAlbum: (albumId: String) -> Unit,
    onOpenSetlist: (setlistId: String, autoplay: Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    val catalogState by graph.catalogRepository.state.collectAsState()
    val catalog = catalogState.catalog

    Box(modifier = modifier.fillMaxSize().testTag("artist-detail")) {
        when {
            catalog == null -> {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            }

            else -> {
                // Re-derive from the live catalog every render (§6.1). Memoized
                // per-catalog by ArtistCatalog, so this is a filter, not a rebuild.
                val artists = remember(catalog) { ArtistCatalog.of(catalog) }
                val albums = artists.albumsOf(artistName)
                val allSongIds = artists.songIdsOf(artistName)

                if (albums.isEmpty()) {
                    // Stale nav after a refresh dropped every album by this name (§8).
                    Text(
                        "Artist not found",
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier.align(Alignment.Center),
                    )
                } else {
                    fun play(shuffle: Boolean) {
                        scope.launch {
                            val set = graph.collections.playNow(
                                songIds = allSongIds, // raw, non-deduped, album/track order
                                name = artistName,
                                shuffle = shuffle,
                                sourceToken = PlayContext.SOURCE_ARTIST,
                                originId = artistName, // iOS uses the artist key as originId
                            )
                            if (set != null) {
                                onOpenSetlist(NOW_PLAYING_SETLIST_ID, true)
                            } else {
                                snackbar.showSnackbar("Catalog isn't ready yet")
                            }
                        }
                    }

                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        item(key = "header") {
                            ArtistHeader(
                                artistName = artistName,
                                albumCount = albums.size,
                                songCount = allSongIds.size,
                                canPlay = allSongIds.isNotEmpty(),
                                onPlayAll = { play(shuffle = false) },
                                onShuffleAll = { play(shuffle = true) },
                            )
                            HorizontalDivider()
                        }

                        items(albums, key = { it.id }) { album ->
                            ArtistAlbumRow(album = album, onClick = { onOpenAlbum(album.id) })
                            HorizontalDivider()
                        }
                    }
                }
            }
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }
}

@Composable
private fun ArtistHeader(
    artistName: String,
    albumCount: Int,
    songCount: Int,
    canPlay: Boolean,
    onPlayAll: () -> Unit,
    onShuffleAll: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text(
            artistName,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            // Header song count = Σ trackList.size (same number as the row's count).
            "${plural(albumCount, "album")} · ${plural(songCount, "song")}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = onPlayAll,
                enabled = canPlay,
                modifier = Modifier.weight(1f).testTag("artist-play-all"),
            ) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Play all")
            }
            OutlinedButton(
                onClick = onShuffleAll,
                enabled = canPlay,
                modifier = Modifier.weight(1f).testTag("artist-shuffle-all"),
            ) {
                Icon(Icons.Filled.Shuffle, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Shuffle all")
            }
        }
    }
}

@Composable
private fun ArtistAlbumRow(album: IndexAlbum, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        AlbumArt(album, modifier = Modifier.size(50.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                album.name,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            MetaTag(
                "${album.trackList.size} tracks" + (album.year?.let { " · $it" } ?: ""),
            )
        }
        Spacer(Modifier.width(8.dp))
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** iOS pluralization: "1 album" / "2 albums" (specs/artists.md §6.2). */
private fun plural(n: Int, noun: String): String = "$n $noun" + if (n == 1) "" else "s"

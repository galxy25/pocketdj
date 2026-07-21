package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlayOutcome
import kotlinx.coroutines.launch

/**
 * Album detail (specs/browse.md §8): header (cover 168dp, name, artist, tags,
 * source, track count) + track table. Track order comes from `trackList`; ids
 * missing from the catalog are silently dropped. Tap a row → song detail sheet;
 * tap ▶ → [com.levi.pocketdj.playback.PlaybackController.play] (album-context
 * queue). Playable vs metadata-only rows are visually distinct.
 *
 * The integrator navigates here with the album id.
 */
@Composable
fun AlbumDetailScreen(
    albumId: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val preparingId by graph.playbackController.preparingSongId.collectAsState()

    var detailSongId by remember { mutableStateOf<String?>(null) }

    // Resolve the latest album by id from the catalog on every render (§8).
    val catalog = catalogState.catalog
    val album = catalog?.albumsById?.get(albumId)

    Box(modifier = modifier.fillMaxSize()) {
        when {
            catalog == null -> {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            }

            album == null -> {
                Text(
                    "Album not found",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            else -> {
                val tracks = catalog.tracks(album)
                val hasServer = settings?.hasRipServer == true
                val anyPlayable = tracks.any {
                    playability(it.id, manifest, hasServer) != Playability.NONE
                }

                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    item(key = "header") {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(16.dp),
                        ) {
                            AlbumArt(album, modifier = Modifier.size(168.dp), cornerRadius = 10)
                            Spacer(Modifier.height(12.dp))
                            Text(
                                album.name,
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                album.artist,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.primary,
                            )
                            Spacer(Modifier.height(6.dp))
                            MetaTag(
                                listOfNotNull(
                                    Genre.category(album.genre),
                                    album.year?.toString(),
                                    album.country,
                                    catalog.sourceOfAlbum[album.id],
                                    "${tracks.size} tracks",
                                ).joinToString(" · "),
                            )
                            if (anyPlayable) {
                                Spacer(Modifier.height(12.dp))
                                Button(
                                    onClick = {
                                        scope.launch {
                                            when (val outcome = graph.playbackController.playAlbum(album.id)) {
                                                is PlayOutcome.Failed ->
                                                    snackbar.showSnackbar(outcome.message)
                                                is PlayOutcome.NotPlayable ->
                                                    snackbar.showSnackbar("No import server configured (Settings)")
                                                else -> Unit
                                            }
                                        }
                                    },
                                ) {
                                    Icon(Icons.Filled.PlayArrow, contentDescription = null)
                                    Spacer(Modifier.width(6.dp))
                                    Text("Play")
                                }
                            }
                        }
                        HorizontalDivider()
                    }

                    itemsIndexed(tracks, key = { _, song -> song.id }) { index, song ->
                        AlbumTrackRow(
                            position = index + 1,
                            song = song,
                            playable = playability(song.id, manifest, hasServer),
                            isPreparing = preparingId == song.id,
                            zebra = index % 2 == 1,
                            onClick = { detailSongId = song.id },
                            onPlay = {
                                scope.launch {
                                    playAndReport(graph.playbackController, song.id, snackbar)
                                }
                            },
                        )
                    }
                }
            }
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

    detailSongId?.let { songId ->
        SongDetailSheet(
            songId = songId,
            onDismiss = { detailSongId = null },
            snackbar = snackbar,
        )
    }
}

/**
 * Track row (§8): # (trackNumber ?? position), title (+E, + up to 3 sentiment
 * keywords caption), BPM, key chip, time, play control. Metadata-only rows are
 * dimmed with no ▶.
 */
@Composable
private fun AlbumTrackRow(
    position: Int,
    song: IndexSong,
    playable: Playability,
    isPreparing: Boolean,
    zebra: Boolean,
    onClick: () -> Unit,
    onPlay: () -> Unit,
) {
    val contentAlpha = if (playable == Playability.NONE) 0.45f else 1f
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .let { base ->
                if (zebra) {
                    base.background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                } else {
                    base
                }
            }
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(
            (song.trackNumber ?: position).toString(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(26.dp),
        )
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    song.name,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = contentAlpha),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (song.explicit == true) {
                    Spacer(Modifier.width(6.dp))
                    ExplicitBadge()
                }
            }
            val sentiments = song.sentimentKeywords.orEmpty().take(3)
            if (sentiments.isNotEmpty()) {
                MetaTag(sentiments.joinToString(" · "))
            }
        }
        Spacer(Modifier.width(8.dp))
        Text(
            Fmt.bpm(song.bpm),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(30.dp),
        )
        KeyChip(song.key?.takeIf { song.camelot == null }, song.camelot)
        Spacer(Modifier.width(6.dp))
        Text(
            Fmt.duration(song.length),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        when {
            isPreparing -> {
                Spacer(Modifier.width(10.dp))
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(10.dp))
            }

            playable != Playability.NONE -> {
                IconButton(onClick = onPlay) {
                    Icon(
                        Icons.Filled.PlayArrow,
                        contentDescription = "Play ${song.name}",
                        tint = if (playable == Playability.STREAM) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
            }

            else -> Spacer(Modifier.width(12.dp))
        }
    }
}

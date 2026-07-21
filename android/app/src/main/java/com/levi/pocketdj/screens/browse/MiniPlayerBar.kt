package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.launch

/**
 * Compact now-playing bar for the integrator to dock globally (above the bottom
 * nav). Renders NOTHING when idle. Shows the current track's art/title/artist
 * with a play-pause toggle, or a "Preparing…" row while a rip-on-demand runs.
 *
 * Deliberately position-free: no scrubber, no hot position flow
 * (specs/playback.md §5.5) — [onTap] can open a fuller now-playing surface later.
 */
@Composable
fun MiniPlayerBar(
    modifier: Modifier = Modifier,
    onTap: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()

    val nowPlaying by graph.playbackController.nowPlaying.collectAsState()
    val preparingId by graph.playbackController.preparingSongId.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()

    val np = nowPlaying
    val preparing = preparingId
    if (np == null && preparing == null) return

    val catalog = catalogState.catalog

    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        tonalElevation = 3.dp,
        modifier = modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .let { base -> if (onTap != null) base.clickable(onClick = onTap) else base }
                .padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            when {
                np != null -> {
                    val album = np.albumId?.let { catalog?.albumsById?.get(it) }
                    AlbumArt(album, modifier = Modifier.size(40.dp))
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            np.title ?: np.songId,
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        val subtitle = listOfNotNull(
                            np.artist,
                            if (np.isLive) "LIVE" else null,
                        ).joinToString(" · ")
                        if (subtitle.isNotEmpty()) {
                            Text(
                                subtitle,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    IconButton(
                        onClick = {
                            scope.launch {
                                if (np.isPlaying) {
                                    graph.playbackController.pause()
                                } else {
                                    graph.playbackController.resume()
                                }
                            }
                        },
                    ) {
                        Icon(
                            if (np.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (np.isPlaying) "Pause" else "Play",
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                }

                preparing != null -> {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    val song = catalog?.songsById?.get(preparing)
                    Text(
                        "Preparing ${song?.name ?: "song"}…",
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

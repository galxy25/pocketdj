package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.playback.sequencer.RepeatMode

/** Title + artist above the record (testTags np-title / np-artist). */
@Composable
fun NowPlayingTitleBlock(state: NowPlayingUiState, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            state.title,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            textAlign = TextAlign.Center,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.testTag("np-title"),
        )
        Text(
            state.artist,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            textAlign = TextAlign.Center,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.testTag("np-artist"),
        )
    }
}

/** The record with long-press -> song detail. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NowPlayingRecord(
    state: NowPlayingUiState,
    progress: Double?,
    onLongPress: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = Color.Transparent,
        modifier = modifier.combinedClickable(onClick = {}, onLongClick = onLongPress),
    ) {
        val ctx = androidx.compose.ui.platform.LocalContext.current
        val album = androidx.compose.runtime.remember(state.albumId) {
            state.albumId?.let { com.levi.pocketdj.di.AppGraph.get(ctx).catalogRepository.state.value.catalog?.albumsById?.get(it) }
        }
        RecordPlayer(
            spinning = state.spinning, bpm = state.bpm, progress = progress,
            album = album, hasTrack = state.hasTrack,
        )
    }
}

/** Seekless elapsed/length bar (1 Hz) with elapsed / -remaining labels. Hidden when the length is unknown. */
@Composable
fun NowPlayingProgress(
    progress: Double?,
    modifier: Modifier = Modifier,
    elapsedMs: Long? = null,
    lengthMs: Long? = null,
) {
    if (progress == null) return
    Column(modifier.fillMaxWidth()) {
        LinearProgressIndicator(
            progress = { progress.toFloat() },
            gapSize = 0.dp,
            drawStopIndicator = {},
            modifier = Modifier.fillMaxWidth().testTag("np-progress"),
        )
        if (elapsedMs != null && lengthMs != null && lengthMs > 0) {
            val el = elapsedMs.coerceIn(0L, lengthMs)
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    NowPlayingTime.format(el),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("np-elapsed"),
                )
                Text(
                    "-" + NowPlayingTime.format(lengthMs - el),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("np-remaining"),
                )
            }
        }
    }
}

/** BPM · key line under the title (iOS NP shows tempo + key chips). Renders nothing without data. */
@Composable
fun NowPlayingFactsLine(bpm: Double?, key: String?, camelot: String?, modifier: Modifier = Modifier) {
    if ((bpm == null || bpm <= 0) && key.isNullOrBlank() && camelot.isNullOrBlank()) return
    Row(
        modifier.fillMaxWidth().padding(top = 4.dp).testTag("np-facts"),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (bpm != null && bpm > 0) {
            Text(
                "${Math.round(bpm)} BPM",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            androidx.compose.foundation.layout.Spacer(Modifier.size(8.dp))
        }
        com.levi.pocketdj.screens.browse.KeyChip(key, camelot)
    }
}

/** m:ss (h:mm:ss past an hour). */
object NowPlayingTime {
    fun format(ms: Long): String {
        val total = (ms.coerceAtLeast(0L) + 500) / 1000
        val h = total / 3600; val m = (total % 3600) / 60; val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }
}

/** ⏮ ⏯ ⏭ + (while a set runs) shuffle / repeat / ⟲ and the ♥ / rating seams. */
@Composable
fun NowPlayingTransportRow(
    state: NowPlayingUiState,
    showPlayedActive: Boolean,
    onPrevious: () -> Unit,
    onPlayPause: () -> Unit,
    onNext: () -> Unit,
    onShuffle: () -> Unit,
    onRepeat: () -> Unit,
    onTogglePlayed: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = MaterialTheme.colorScheme.primary
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // iOS: ⟲ on the leading edge, ♥ on the trailing edge, ⏮⏯⏭ centred between them,
            // for ANY current track (a Browse single included), not only while a set runs.
            IconButton(onClick = onTogglePlayed, modifier = Modifier.testTag("np-played")) {
                Icon(
                    Icons.Filled.History,
                    "Previously played",
                    tint = if (showPlayedActive) accent else dim,
                )
            }
            IconButton(onClick = onPrevious, modifier = Modifier.testTag("np-previous")) {
                Icon(Icons.Filled.SkipPrevious, "Previous", Modifier.size(32.dp))
            }
            IconButton(onClick = onPlayPause, modifier = Modifier.size(64.dp).testTag("np-playpause")) {
                Icon(
                    if (state.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    if (state.isPlaying) "Pause" else "Play",
                    Modifier.size(44.dp),
                    tint = accent,
                )
            }
            IconButton(onClick = onNext, modifier = Modifier.testTag("np-next")) {
                Icon(Icons.Filled.SkipNext, "Next", Modifier.size(32.dp))
            }
            val id = state.songId
            if (id != null && NowPlayingSeams.heart != null) {
                Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    NowPlayingSeams.heart?.invoke(id, state.appleMusicId)
                }
            } else {
                androidx.compose.foundation.layout.Spacer(Modifier.size(48.dp))
            }
        }
        if (state.showModeRow) {
            Row(
                Modifier.fillMaxWidth().padding(top = 4.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onShuffle, modifier = Modifier.testTag("np-shuffle")) {
                    Icon(
                        Icons.Filled.Shuffle,
                        if (state.shuffleEnabled) "Shuffle on" else "Shuffle off",
                        tint = if (state.shuffleEnabled) accent else dim,
                    )
                }
                IconButton(onClick = onRepeat, modifier = Modifier.testTag("np-repeat")) {
                    Icon(
                        if (state.repeatMode == RepeatMode.ONE) Icons.Filled.RepeatOne else Icons.Filled.Repeat,
                        state.repeatHelp,
                        modifier = Modifier.semantics { contentDescription = state.repeatHelp },
                        tint = if (state.repeatMode == RepeatMode.OFF) dim else accent,
                    )
                }
                state.songId?.let { id -> NowPlayingSeams.rating?.invoke(id) }
            }
        }
    }
}

/** Banner for sequencer.playbackNotice. */
@Composable
fun NowPlayingNotice(text: String?, modifier: Modifier = Modifier) {
    if (text == null) return
    Surface(
        color = Color.Transparent,
        shape = MaterialTheme.shapes.small,
        modifier = modifier.fillMaxWidth().testTag("np-playback-notice"),
    ) {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(4.dp),
        )
    }
}

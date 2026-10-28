package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
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
            maxLines = 2,
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
        RecordPlayer(spinning = state.spinning, bpm = state.bpm, progress = progress)
    }
}

/** Seekless elapsed/length bar (1 Hz). Hidden when the length is unknown. */
@Composable
fun NowPlayingProgress(progress: Double?, modifier: Modifier = Modifier) {
    if (progress == null) return
    LinearProgressIndicator(
        progress = { progress.toFloat() },
        modifier = modifier.fillMaxWidth().testTag("np-progress"),
    )
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
                IconButton(onClick = onTogglePlayed, modifier = Modifier.testTag("np-played")) {
                    Icon(
                        Icons.Filled.History,
                        "Played",
                        tint = if (showPlayedActive) accent else dim,
                    )
                }
                state.songId?.let { id ->
                    NowPlayingSeams.heart?.invoke(id)
                    NowPlayingSeams.rating?.invoke(id)
                }
            }
        }
    }
}

/** Banner for sequencer.playbackNotice. */
@Composable
fun NowPlayingNotice(text: String?, modifier: Modifier = Modifier) {
    if (text == null) return
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        shape = MaterialTheme.shapes.small,
        modifier = modifier.fillMaxWidth().testTag("np-playback-notice"),
    ) {
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onErrorContainer,
            modifier = Modifier.padding(12.dp),
        )
    }
}

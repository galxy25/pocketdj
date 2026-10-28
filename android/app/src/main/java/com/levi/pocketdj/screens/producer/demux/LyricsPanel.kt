package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.demux.DemuxLine
import com.levi.pocketdj.studio.demux.LyricsPanelState
import com.levi.pocketdj.studio.demux.StemPlayer
import kotlinx.coroutines.delay

/** Pure karaoke fill: one entry per word, true once the playhead passed its start (only the current line fills). */
object LyricsMath {
    fun sungFlags(line: DemuxLine, nowMs: Int): List<Boolean> {
        val current = DemuxLine.isCurrent(line, nowMs)
        return line.words.map { current && it.startMs <= nowMs }
    }
}

/**
 * Time-synced lyrics from the cloud sidecar: the transcript's words grouped into lines, the CURRENT line auto-centred
 * while playing, already-sung words of that line highlighted karaoke-style, tap-a-line seeks. Renders nothing while the
 * gate is off ([LyricsPanelState.Hidden]).
 */
@Composable
fun LyricsPanel(state: LyricsPanelState, player: StemPlayer, onSeek: (Int) -> Unit, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    when (state) {
        LyricsPanelState.Hidden -> Unit
        LyricsPanelState.Fetching -> Row(modifier.testTag("demux-lyrics-fetching"), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Text("Fetching lyrics…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        LyricsPanelState.Instrumental -> Text("No lyrics found — this looks like an instrumental.", modifier.testTag("demux-lyrics-instrumental"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        LyricsPanelState.Retry -> Row(modifier.testTag("demux-lyrics-retry-row"), verticalAlignment = Alignment.CenterVertically) {
            Text("Couldn’t load the lyrics.", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = onRetry, modifier = Modifier.testTag("demux-lyrics-retry")) { Text("Retry") }
        }
        is LyricsPanelState.Lyrics -> Column(modifier.fillMaxWidth().testTag("demux-lyrics"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Lyrics", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                TextButton(onClick = onRetry, modifier = Modifier.testTag("demux-transcript-regenerate")) { Text("Refresh") }
            }
            state.diag?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("demux-transcript-diag")) }
            Karaoke(state.lines, player, onSeek)
        }
    }
}

@Composable
private fun Karaoke(lines: List<DemuxLine>, player: StemPlayer, onSeek: (Int) -> Unit) {
    var nowMs by remember(lines) { mutableIntStateOf(0) }
    val list = rememberLazyListState()
    LaunchedEffect(lines) {
        var lastCentered = -1
        while (true) {
            nowMs = (player.currentTimeSec * 1000).toInt()
            if (player.isPlaying) {
                val idx = DemuxLine.currentIndex(lines, nowMs)
                if (idx >= 0 && idx != lastCentered) { lastCentered = idx; list.animateScrollToItem(idx) }
            }
            delay(250)
        }
    }
    val fg = MaterialTheme.colorScheme.onSurface
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val accent = MaterialTheme.colorScheme.primary
    LazyColumn(state = list, modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        itemsIndexed(lines, key = { i, l -> "$i-${l.startMs}" }) { _, line ->
            val current = DemuxLine.isCurrent(line, nowMs)
            Text(
                karaoke(line, nowMs, fg, dim, accent),
                style = if (current) MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold) else MaterialTheme.typography.bodyLarge,
                modifier = Modifier.fillMaxWidth().clickable { onSeek(line.startMs) }.padding(vertical = 2.dp),
            )
        }
    }
}

internal fun karaoke(line: DemuxLine, nowMs: Int, fg: Color, dim: Color, accent: Color): AnnotatedString {
    val current = DemuxLine.isCurrent(line, nowMs)
    val sung = LyricsMath.sungFlags(line, nowMs)
    return buildAnnotatedString {
        line.words.forEachIndexed { i, w ->
            val c = if (current) (if (sung[i]) accent else fg) else dim
            withStyle(SpanStyle(color = c)) { append(w.text + " ") }
        }
    }
}

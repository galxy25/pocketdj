package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationSearching
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.producer.instruments.ScoreEditor
import com.levi.pocketdj.studio.demux.DemuxInstrumental
import com.levi.pocketdj.studio.demux.DemuxInstrumentalContent
import com.levi.pocketdj.studio.demux.DemuxSource
import com.levi.pocketdj.studio.demux.DrumPatternDetector
import com.levi.pocketdj.studio.demux.ExportOutcome
import com.levi.pocketdj.studio.demux.StemPlayer
import com.levi.pocketdj.studio.model.InstrumentKey
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Pure sync math for the instrumental's follow score (JVM-tested). */
object InstrumentalMath {
    /** Take-clock position (0 = beat 1) for a song-clock playhead, or null before the count-in ends. */
    fun scoreMs(songMs: Int, firstDownbeatMs: Int): Int? = (songMs - firstDownbeatMs).takeIf { it >= 0 }

    /** Song-clock time for a score-clock seek. */
    fun songMs(scoreMs: Int, firstDownbeatMs: Int): Int = scoreMs + firstDownbeatMs

    /** Where in a vertically scrolling score the playhead sits, 0..1 (proportional to elapsed take time). */
    fun scrollFraction(scoreMs: Int?, endMs: Int): Float = if (scoreMs == null || endMs <= 0) 0f else (scoreMs.toFloat() / endMs).coerceIn(0f, 1f)

    /** Rebuild identity: the content, grid and duration (a change rebuilds the events). */
    fun rebuildKey(content: DemuxInstrumentalContent, grid: DemuxInstrumental.Grid, durationMs: Int): String =
        "${content.mode}#${content.hashCode()}#${grid.bpm}#${grid.firstDownbeatMs}#${grid.beatsMs.size}#$durationMs"
}

/**
 * Demuxer > INSTRUMENTAL (chord comping) / MELODY: builds the beat-quantized events from the ALREADY-detected chords (or
 * tracked melody), shows them as a synced score that follows the shared player, and hands them to Instruments as a
 * plain StudioTake via [onExtract]. The score repaints through the shared ScoreEditor (read-only) with the host clock.
 */
@Composable
fun InstrumentalPanel(
    source: DemuxSource,
    content: DemuxInstrumentalContent,
    grid: DemuxInstrumental.Grid,
    durationMs: Int,
    player: StemPlayer,
    follow: Boolean,
    onFollowChange: (Boolean) -> Unit,
    onSeek: (Int) -> Unit,
    onExtract: suspend () -> ExportOutcome,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val key = InstrumentalMath.rebuildKey(content, grid, durationMs)
    val built = remember(source.key, key) { content.build(grid) }
    val bars = remember(source.key, key) { DrumPatternDetector.bars(emptyList(), built.bpm, grid.firstDownbeatMs, durationMs) }
    val endMs = remember(built) { built.events.maxOfOrNull { it.offMs } ?: 0 }
    var notice by remember(source.key, content.mode) { mutableStateOf<String?>(null) }
    var busy by remember(source.key, content.mode) { mutableStateOf(false) }
    var selectedBar by remember(source.key) { mutableIntStateOf(0) }
    val scroll = rememberScrollState()
    val tag = if (content.isMelody) "melody" else "instrumental"

    // ONE shared follow poll (playing OR a paused scrub): bar chip + proportional score scroll.
    LaunchedEffect(source.key, follow, bars, endMs) {
        while (follow) {
            val ms = (player.currentTimeSec * 1000).toInt()
            DrumPatternDetector.barIndex(ms, bars)?.let { if (it != selectedBar) selectedBar = it }
            val frac = InstrumentalMath.scrollFraction(InstrumentalMath.scoreMs(ms, grid.firstDownbeatMs), endMs)
            val target = (frac * scroll.maxValue).toInt()
            if (kotlin.math.abs(target - scroll.value) > 4) scroll.animateScrollTo(target)
            delay(200)
        }
    }

    Column(modifier.fillMaxWidth().testTag("demux-$tag-panel"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            IconButton(onClick = { onFollowChange(!follow) }, modifier = Modifier.size(34.dp).testTag("demux-sync-follow")) {
                Icon(if (follow) Icons.Filled.MyLocation else Icons.Filled.LocationSearching, if (follow) "Following playback" else "Follow playback",
                    tint = if (follow) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("Synced playback — the score follows the playhead", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        com.levi.pocketdj.studio.demux.KeyDetector.detect(built.events)?.let {
            Text("Key ${it.camelot}", style = MaterialTheme.typography.labelMedium, modifier = Modifier.testTag("demux-$tag-key"))
        }
        notice?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("demux-instrumental-notice")) }
        FilledTonalButton(
            onClick = {
                busy = true; notice = null
                scope.launch { notice = try { onExtract().notice } finally { busy = false } }
            },
            enabled = built.events.isNotEmpty() && !busy,
            modifier = Modifier.fillMaxWidth().testTag(if (content.isMelody) "demux-melody-extract" else "demux-instrumental-extract"),
        ) { Text(if (busy) "Saving…" else if (content.isMelody) "Extract melody" else "Extract instrumental") }
        Text(
            if (content.isMelody) "A single-voice melody line → Instruments ▸ Instrumentals, where you can edit it, play it with a different sound pack, or switch it to chord comping."
            else "A chord-comping instrumental (full triads) → Instruments ▸ Instrumentals, where you can edit it or play it with a different sound pack.",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (bars.isNotEmpty()) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                for (b in bars) FilterChip(b.index == selectedBar, { selectedBar = b.index; onSeek(b.startMs) }, { Text("${b.index + 1}") }, Modifier.testTag("demux-$tag-bar-${b.index}"))
            }
        }
        // The score is a plain vertical stack of pages; a bounded box lets the follow scroll bring the playhead into view.
        Column(Modifier.fillMaxWidth().heightIn(max = 360.dp).verticalScroll(scroll).testTag("demux-$tag-score")) {
            ScoreEditor(
                events = built.events, bpm = built.bpm, instrument = InstrumentKey.PIANO, title = source.displayName, editing = false, onEdit = {},
                positionMs = { InstrumentalMath.scoreMs((player.currentTimeSec * 1000).toInt(), grid.firstDownbeatMs) },
                onSeek = { onSeek(InstrumentalMath.songMs(it, grid.firstDownbeatMs)) },
                tagPrefix = "demux-score",
            )
        }
    }
}

package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.LocationSearching
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.studio.demux.DemuxDrumHit
import com.levi.pocketdj.studio.demux.DemuxDrumKind
import com.levi.pocketdj.studio.demux.DemuxSource
import com.levi.pocketdj.studio.demux.DrumLanes
import com.levi.pocketdj.studio.demux.DrumPatternDetector
import com.levi.pocketdj.studio.demux.DrumPatternExport
import com.levi.pocketdj.studio.demux.ExportOutcome
import com.levi.pocketdj.studio.demux.StemPlayer
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Pure geometry for the drum grid (JVM-tested): the playing step, a step's seek time, the lane colour. */
object DrumPanelMath {
    /** The 0..15 step the playhead is in within [bar], or null outside it. */
    fun currentStep(ms: Int, bar: DrumPatternDetector.Bar?): Int? {
        bar ?: return null
        if (ms < bar.startMs || ms >= bar.endMs) return null
        val len = maxOf(1, bar.endMs - bar.startMs)
        return minOf(15, (ms - bar.startMs) * 16 / len)
    }

    /** Song-clock time of step [col] (16th-note boundary) in [bar]. */
    fun stepMs(bar: DrumPatternDetector.Bar, col: Int): Int = bar.startMs + col * (bar.endMs - bar.startMs) / 16

    fun laneColor(kind: DemuxDrumKind): Color = when (kind) {
        DemuxDrumKind.KICK -> Color(0xFFE5484D)
        DemuxDrumKind.SNARE -> Color(0xFFE0A526)
        DemuxDrumKind.PERCUSSIVE -> Color(0xFF22B8CF)
        DemuxDrumKind.OTHER -> Color(0xFF9B59D0)
        DemuxDrumKind.BASS -> Color(0xFF3B82F6)
    }

    /** The bars an export covers: the selected bar, or every detected bar for "send all". */
    fun exportRange(wholeSong: Boolean, selectedBar: Int, barCount: Int): List<Int> =
        if (wholeSong) (0 until barCount).toList() else listOf(selectedBar).filter { it in 0 until barCount }
}

/**
 * Demuxer > DRUM PATTERN: the classified hits on a bar-by-bar 16-step grid (one coloured lane per class), bar chips for
 * time division, steps lit where hits landed. The grid FOLLOWS the shared player (a paused scrub too) and taps seek back
 * (two-way sync). "Send bar N / Send all N bars" exports through [export] into a real Sequencer pattern.
 */
@Composable
fun DrumPatternPanel(
    source: DemuxSource,
    hits: List<DemuxDrumHit>,
    bars: List<DrumPatternDetector.Bar>,
    durationMs: Int,
    player: StemPlayer,
    follow: Boolean,
    onFollowChange: (Boolean) -> Unit,
    onSeek: (Int) -> Unit,
    export: suspend (plan: DrumPatternExport.Plan, wholeSong: Boolean, selectedBar: Int) -> ExportOutcome,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    // Everything derived is keyed by the SOURCE so flipping sources can never show or export another source's bars.
    val grid = remember(source.key, hits, bars) { DrumPatternDetector.stepGrid(hits, bars) }
    val lanes = remember(source.key, hits) { DrumLanes.present(hits) }
    var selected by remember(source.key) { mutableIntStateOf(0) }
    var exporting by remember(source.key) { mutableStateOf(false) }
    var notice by remember(source.key) { mutableStateOf<String?>(null) }
    var step by remember(source.key) { mutableStateOf<Int?>(null) }

    // Land on the first bar that actually has hits (intros are often empty).
    LaunchedEffect(source.key, grid) { grid.indexOfFirst { it.isNotEmpty() }.takeIf { it >= 0 }?.let { selected = it } }
    // FOLLOW: advance the displayed bar with the playhead (no isPlaying gate: a paused scrub moves the grid too).
    LaunchedEffect(source.key, follow, bars) {
        while (true) {
            val ms = (player.currentTimeSec * 1000).toInt()
            if (follow) DrumPatternDetector.barIndex(ms, bars)?.let { if (it != selected) selected = it }
            val s = DrumPanelMath.currentStep(ms, bars.getOrNull(selected))
            if (s != step) step = s
            delay(100)
        }
    }

    Column(modifier.fillMaxWidth().testTag("demux-drum-panel"), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (bars.isEmpty()) {
            Text("No beat grid for this audio — hits were found, but bars can’t be drawn.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            return@Column
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            IconButton(onClick = { onFollowChange(!follow) }, modifier = Modifier.size(34.dp).testTag("demux-drum-follow")) {
                Icon(if (follow) Icons.Filled.MyLocation else Icons.Filled.LocationSearching, if (follow) "Following playback" else "Follow playback",
                    tint = if (follow) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                for (bar in bars) BarChip(bar.index, bar.index == selected, grid.getOrNull(bar.index)?.isNotEmpty() == true) {
                    // Two-way sync: selecting a bar SNAPS playback to it.
                    selected = bar.index
                    onSeek(bar.startMs)
                }
            }
        }
        val barLanes = grid.getOrNull(selected).orEmpty()
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            for (kind in lanes) {
                val steps = barLanes[kind] ?: List(16) { false }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag("demux-drum-lane-${kind.name.lowercase()}")) {
                    Row(Modifier.widthIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Box(Modifier.size(7.dp).background(DrumPanelMath.laneColor(kind), RoundedCornerShape(50)))
                        Text(DrumLanes.label(kind), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    for (group in 0 until 4) {
                        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                            for (i in 0 until 4) {
                                val col = group * 4 + i
                                StepCell(kind, col, steps[col], playing = step == col) {
                                    bars.getOrNull(selected)?.let { onSeek(DrumPanelMath.stepMs(it, col)) }
                                }
                            }
                        }
                    }
                }
            }
        }
        notice?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("demux-drum-export-notice")) }
        val barHasHits = grid.getOrNull(selected)?.isNotEmpty() == true
        fun run(whole: Boolean) {
            val plan = DrumPatternExport.plan(grid, bars, DrumPanelMath.exportRange(whole, selected, minOf(bars.size, grid.size)))
            if (plan == null) { notice = if (whole) "No hits detected." else "No hits in this bar."; return }
            val bar = selected
            exporting = true; notice = null
            scope.launch {
                val r = try { export(plan, whole, bar) } finally { exporting = false }
                notice = r.notice
            }
        }
        ExportButton("Send bar ${selected + 1} to Sequencer", enabled = !exporting && barHasHits, busy = exporting, tag = "demux-drum-export") { run(false) }
        ExportButton("Send all ${bars.size} bars to Sequencer", enabled = !exporting && bars.size >= 2 && grid.any { it.isNotEmpty() }, busy = exporting, tag = "demux-drum-export-whole") { run(true) }
    }
}

@Composable
private fun BarChip(index: Int, selected: Boolean, hasHits: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(6.dp)
    val accent = MaterialTheme.colorScheme.primary
    Box(
        Modifier.widthIn(min = 28.dp).height(30.dp)
            .background(if (selected) accent.copy(alpha = 0.25f) else MaterialTheme.colorScheme.surfaceVariant, shape)
            .border(BorderStroke(1.dp, if (selected) accent else MaterialTheme.colorScheme.outlineVariant), shape)
            .clickable(onClick = onClick)
            .semantics { contentDescription = "Bar ${index + 1}" }
            .testTag("demux-drum-bar-$index"),
        contentAlignment = Alignment.Center,
    ) {
        Text("${index + 1}", fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
            color = if (hasHits) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
    }
}

@Composable
private fun RowScope.StepCell(kind: DemuxDrumKind, col: Int, on: Boolean, playing: Boolean, onTap: () -> Unit) {
    val shape = RoundedCornerShape(3.dp)
    val color = DrumPanelMath.laneColor(kind)
    Box(
        Modifier.weight(1f).height(26.dp)
            .background(if (on) color else MaterialTheme.colorScheme.surfaceVariant, shape)
            .border(BorderStroke(if (playing) 1.5.dp else 0.5.dp, if (playing) MaterialTheme.colorScheme.tertiary else if (col % 4 == 0) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.outlineVariant), shape)
            .clickable(onClick = onTap)
            .semantics { contentDescription = "${DrumLanes.label(kind)} step ${col + 1}"; stateDescription = if (on) "hit" else "empty" },
    )
}

@Composable
private fun ExportButton(label: String, enabled: Boolean, busy: Boolean, tag: String, onClick: () -> Unit) {
    FilledTonalButton(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().testTag(tag)) {
        if (busy) CircularProgressIndicator(Modifier.size(16.dp).padding(end = 0.dp), strokeWidth = 2.dp)
        Text(if (busy) "  Building sequence…" else label)
    }
}

package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import com.levi.pocketdj.screens.producer.common.EditSlider
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.screens.producer.common.WaveformView
import com.levi.pocketdj.studio.demux.DemuxCutMath
import com.levi.pocketdj.studio.demux.DemuxSource
import com.levi.pocketdj.studio.demux.DemuxStore
import com.levi.pocketdj.studio.demux.ExportOutcome
import com.levi.pocketdj.studio.demux.StemPlayer
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Demuxer > "Cut sample": the region editor over the demux-resolved audio. Mark in/out at the playhead, drag the
 * waveform handles or nudge the In/Out sliders, and (when the four stems are on the device) carve a MIX of the selected
 * stems — "what you hear is what you cut": the chips live-mute the Demuxer's own synced player, which auditions the sheet.
 *
 * [stemModeOn] / [onStemMode] bind to the session's stem mode; [carve] gets the enabled stem names (null = full mix).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CutSampleSheet(
    source: DemuxSource,
    durationMs: Int,
    peaks: FloatArray,
    player: StemPlayer,
    hasStems: Boolean,
    stemModeOn: Boolean,
    onStemMode: (Boolean) -> Unit,
    carve: suspend (enabledStems: Set<String>?, name: String, startMs: Int, endMs: Int) -> ExportOutcome,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val len = maxOf(DemuxCutMath.MIN_WINDOW_MS + 1, durationMs)
    var startMs by remember(source.key) { mutableIntStateOf(0) }
    var endMs by remember(source.key) { mutableIntStateOf(len) }
    var enabled by remember(source.key) { mutableStateOf(DemuxStore.STEM_NAMES.toSet()) }
    var carving by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var playhead by remember { mutableIntStateOf(0) }

    LaunchedEffect(player) { while (true) { playhead = (player.currentTimeSec * 1000).toInt(); delay(100) } }
    // The chips drive the player's mutes so the audition IS the mix that gets carved.
    LaunchedEffect(stemModeOn, enabled) {
        if (stemModeOn) for (name in DemuxStore.STEM_NAMES) if (player.isAudible(name) != (name in enabled)) player.toggleMute(name)
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp).testTag("demux-cut-sheet"), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Cut sample", style = MaterialTheme.typography.titleMedium)
                    Text(source.displayName, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
                TextButton(onClick = onDismiss, modifier = Modifier.testTag("demux-cut-cancel")) { Text("Cancel") }
            }
            WaveformView(
                peaks = peaks, regionStart = startMs.toFloat() / len, regionEnd = endMs.toFloat() / len, playhead = (playhead.toFloat() / len).coerceIn(0f, 1f),
                onSeek = { player.seek(it * len / 1000.0) },
                onRegionChange = { s, e ->
                    startMs = DemuxCutMath.setIn((s * len).toInt(), endMs)
                    endMs = DemuxCutMath.setOut((e * len).toInt(), startMs, len)
                },
                description = "Cut region",
            )
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceEvenly) {
                TextButton(onClick = { startMs = DemuxCutMath.setIn(playhead, endMs) }, modifier = Modifier.testTag("demux-cut-mark-in")) { Text("Mark in") }
                IconButton(onClick = { player.togglePlayPause() }, modifier = Modifier.size(46.dp).testTag("demux-cut-play")) {
                    Icon(if (player.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (player.isPlaying) "Pause" else "Play")
                }
                Text(StudioFmt.mmssTenths(playhead), style = MaterialTheme.typography.labelMedium)
                TextButton(onClick = { endMs = DemuxCutMath.setOut(playhead, startMs, len) }, modifier = Modifier.testTag("demux-cut-mark-out")) { Text("Mark out") }
            }
            EditSlider("In", 0.0..len.toDouble(), startMs.toDouble(), { StudioFmt.mmssTenths(it.toInt()) }, "demux-cut-region-start", step = 10.0) {
                startMs = DemuxCutMath.setIn(it.toInt(), endMs)
            }
            EditSlider("Out", 0.0..len.toDouble(), endMs.toDouble(), { StudioFmt.mmssTenths(it.toInt()) }, "demux-cut-region-end", step = 10.0) {
                endMs = DemuxCutMath.setOut(it.toInt(), startMs, len)
            }
            Text("Length ${StudioFmt.mmssTenths(endMs - startMs)} · no grid — set one in the editor", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (hasStems) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Stem source", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    Switch(checked = stemModeOn, onCheckedChange = onStemMode, modifier = Modifier.testTag("demux-cut-stem-mode"))
                }
                if (stemModeOn) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (name in listOf("drums", "bass", "other", "vocals")) {
                            FilterChip(name in enabled, { enabled = DemuxCutMath.toggleStem(enabled, name) }, { Text(name.replaceFirstChar { it.uppercase() }) }, Modifier.testTag("demux-cut-stem-$name"))
                        }
                    }
                    Text("The audition plays exactly this mix — what you hear is what gets cut.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            notice?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("demux-cut-notice")) }
            FilledTonalButton(
                onClick = {
                    carving = true; notice = null
                    val stems = if (stemModeOn && hasStems) enabled else null
                    scope.launch {
                        val r = try { carve(stems, DemuxCutMath.sampleName(source, stems != null, enabled), startMs, endMs) } finally { carving = false }
                        notice = r.notice
                        if (r.ok) onDismiss()
                    }
                },
                enabled = !carving && endMs - startMs >= DemuxCutMath.MIN_WINDOW_MS,
                modifier = Modifier.fillMaxWidth().testTag("demux-cut-create"),
            ) { Text(if (carving) "Carving…" else "Create sample") }
        }
    }
}

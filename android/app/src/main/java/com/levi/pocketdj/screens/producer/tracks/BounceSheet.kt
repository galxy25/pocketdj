package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioTrack

/** Pure selection rules for the Bounce sheet (tested). */
object BounceSelection {
    /** Tracks that can be bounced at all (a track with no clips is skipped, never selectable). */
    fun bounceable(arr: StudioArrangement): List<StudioTrack> = arr.tracks.filter { it.clips.isNotEmpty() }

    /** The tracks to mix for a "Bounce selected" request, in arrangement order, empties dropped. */
    fun resolve(arr: StudioArrangement, selectedIds: Set<String>): List<StudioTrack> =
        arr.tracks.filter { it.id in selectedIds && it.clips.isNotEmpty() }

    fun confirmLabel(count: Int) = "Bounce selected ($count)"
}

/**
 * Bounce (artifact-only): "Bounce all" mixes every track with clips; or pick a subset. Mute/solo do not
 * affect a bounce, gain does. The result is a dated `bounce-<ts>.m4a` under the arrangement's Bounces group.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BounceSheet(arr: StudioArrangement, onBounce: (List<StudioTrack>) -> Unit, onDismiss: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selected by remember { mutableStateOf(emptySet<String>()) }
    val bounceable = BounceSelection.bounceable(arr)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state, modifier = Modifier.testTag("tracks-bounce-sheet")) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Bounce", style = MaterialTheme.typography.titleMedium)
            Text(
                "Mixes tracks to one master file with master FX and each track’s strip baked in. Mute and solo are ignored; gain is applied.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(
                onClick = { onBounce(bounceable) }, enabled = bounceable.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().testTag("tracks-bounce-all"),
            ) { Text("Bounce all tracks (${bounceable.size})") }
            HorizontalDivider()
            Text("Or choose tracks to mix into one master", style = MaterialTheme.typography.labelLarge)
            arr.tracks.forEachIndexed { i, t ->
                val has = t.clips.isNotEmpty()
                Row(
                    Modifier.fillMaxWidth().clickable(enabled = has) { selected = if (t.id in selected) selected - t.id else selected + t.id }
                        .semantics { contentDescription = "Bounce ${t.name.ifBlank { "Track" }}" }.testTag("tracks-bounce-select-$i"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = t.id in selected, onCheckedChange = null, enabled = has)
                    Text(t.name.ifBlank { "Track" }, Modifier.weight(1f).padding(start = 8.dp))
                    Text("${t.clips.size} clip${if (t.clips.size == 1) "" else "s"}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            val chosen = BounceSelection.resolve(arr, selected)
            OutlinedButton(
                onClick = { onBounce(chosen) }, enabled = chosen.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().testTag("tracks-bounce-confirm"),
            ) { Text(BounceSelection.confirmLabel(chosen.size)) }
        }
    }
}

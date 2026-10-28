package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * Tracks transport row: Play / Stop (a Play while playing restarts from the cursor; the player's
 * generation token makes a double-tap safe), Loop toggle (region handles live on the timeline) and the
 * master-FX panel toggle. Stateless: the host owns the player.
 */
@Composable
fun TransportBar(
    playing: Boolean, loopEnabled: Boolean, fxOpen: Boolean, canPlay: Boolean,
    onPlay: () -> Unit, onStop: () -> Unit, onToggleLoop: () -> Unit, onToggleFx: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        if (playing) {
            FilledIconButton(onClick = onStop, modifier = Modifier.testTag("tracks-stop").semantics { contentDescription = "Stop" }) { Icon(Icons.Filled.Stop, null) }
        } else {
            FilledIconButton(onClick = onPlay, enabled = canPlay, modifier = Modifier.testTag("tracks-play").semantics { contentDescription = "Play" }) { Icon(Icons.Filled.PlayArrow, null) }
        }
        FilledIconToggleButton(checked = loopEnabled, onCheckedChange = { onToggleLoop() }, modifier = Modifier.testTag("tracks-loop").semantics { contentDescription = "Loop ${if (loopEnabled) "on" else "off"}" }) {
            Icon(Icons.Filled.Repeat, null)
        }
        FilledIconToggleButton(checked = fxOpen, onCheckedChange = { onToggleFx() }, modifier = Modifier.testTag("tracks-master-fx-toggle").semantics { contentDescription = "Master FX ${if (fxOpen) "shown" else "hidden"}" }) {
            Icon(Icons.Filled.GraphicEq, null)
        }
    }
}

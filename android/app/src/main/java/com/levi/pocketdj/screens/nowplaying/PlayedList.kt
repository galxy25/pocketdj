package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SetlistSequencer

/**
 * The ⟲ played head of the queue, NEWEST first. Rows are read-only; the menu offers Rewind to here
 * (needle back to that row, everything after replays in order) and Play now (a FRESH copy - reusing
 * the row would duplicate its per-instance uid and confuse every uid-keyed edit).
 */
@Composable
fun PlayedList(
    played: List<QueueItem>,
    sequencer: SetlistSequencer,
    onSongDetail: (QueueItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth()) {
        Text(
            QueueReorder.playedHeader(played.size),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 8.dp).testTag("np-played-header"),
        )
        played.asReversed().forEachIndexed { offset, item ->
            var menu by remember(item.uid) { mutableStateOf(false) }
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { menu = true }.testTag("np-played-$offset"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(item.title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    item.artist?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Row actions") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Rewind to here") }, onClick = { menu = false; sequencer.jumpToPlayed(item.uid) })
                    DropdownMenuItem(text = { Text("Play now") }, onClick = { menu = false; sequencer.playNow(item.freshInstance()) })
                    DropdownMenuItem(text = { Text("Song detail") }, onClick = { menu = false; onSongDetail(item) })
                }
            }
        }
    }
}

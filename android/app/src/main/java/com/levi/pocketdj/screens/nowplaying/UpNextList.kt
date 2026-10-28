package com.levi.pocketdj.screens.nowplaying

import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SetlistSequencer

private val ROW_HEIGHT = 56.dp

/**
 * Up Next: the sequencer's upcoming tail, windowed to [QueueReorder.WINDOW] rows (offsets stay 1:1 with
 * the full tail). Every edit is uid-addressed and re-resolved against the LIVE queue at gesture time:
 * the queue can advance underneath a finger, and a stale position would act on whatever shifted into the slot.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UpNextList(
    upcoming: List<QueueItem>,
    sequencer: SetlistSequencer,
    onSongDetail: (QueueItem) -> Unit,
    onOpenSetlist: () -> Unit,
    onOpenOrigin: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val rows = QueueReorder.window(upcoming)
    val rowPx = with(LocalDensity.current) { ROW_HEIGHT.toPx() }
    var dragUid by remember { mutableStateOf<String?>(null) }
    var dragDy by remember { mutableFloatStateOf(0f) }
    fun liveUids() = sequencer.state.value.upcoming.map { it.uid }

    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                QueueReorder.countHeader(upcoming.size),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f).testTag("np-upnext-header"),
            )
            if (onOpenOrigin != null) TextButton(onClick = onOpenOrigin, modifier = Modifier.testTag("np-open-origin")) { Text("Origin") }
            TextButton(onClick = onOpenSetlist, modifier = Modifier.testTag("np-open-setlist")) { Text("Open set list") }
        }
        rows.forEachIndexed { offset, item ->
            key(item.uid) {
                var menu by remember { mutableStateOf(false) }
                val dismiss = rememberSwipeToDismissBoxState(
                    confirmValueChange = { v ->
                        if (v == SwipeToDismissBoxValue.EndToStart) {
                            // Identity, not position: a row that already left is a no-op.
                            sequencer.removeUpcoming(setOf(item.uid))
                            true
                        } else false
                    },
                )
                SwipeToDismissBox(
                    state = dismiss,
                    enableDismissFromStartToEnd = false,
                    backgroundContent = {
                        Box(Modifier.fillMaxWidth().height(ROW_HEIGHT).background(MaterialTheme.colorScheme.errorContainer), contentAlignment = Alignment.CenterEnd) {
                            Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.padding(end = 16.dp))
                        }
                    },
                    modifier = Modifier
                        .graphicsLayer { translationY = if (dragUid == item.uid) dragDy else 0f }
                        .testTag("np-queue-$offset"),
                ) {
                    Row(
                        Modifier.fillMaxWidth().height(ROW_HEIGHT).background(MaterialTheme.colorScheme.surface)
                            .clickable { sequencer.jumpToUpcoming(item.uid) },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Icon(
                            Icons.Filled.DragHandle,
                            contentDescription = "Reorder",
                            modifier = Modifier.size(40.dp).padding(8.dp).pointerInput(item.uid) {
                                detectVerticalDragGestures(
                                    onDragStart = { dragUid = item.uid; dragDy = 0f },
                                    onVerticalDrag = { _, dy -> dragDy += dy },
                                    onDragEnd = {
                                        QueueReorder.resolveMove(liveUids(), item.uid, QueueReorder.rowsForDrag(dragDy, rowPx))
                                            ?.let { sequencer.moveUpcoming(listOf(it.fromOffset), it.toOffset) }
                                        dragUid = null; dragDy = 0f
                                    },
                                    onDragCancel = { dragUid = null; dragDy = 0f },
                                )
                            },
                        )
                        Column(Modifier.weight(1f)) {
                            Text(item.title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            item.artist?.let {
                                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        IconButton(onClick = { sequencer.removeUpcoming(setOf(item.uid)) }, modifier = Modifier.testTag("np-remove-$offset")) {
                            Icon(Icons.Filled.Close, contentDescription = "Remove")
                        }
                        Box {
                            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Row actions") }
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(text = { Text("Play now") }, onClick = { menu = false; sequencer.jumpToUpcoming(item.uid) })
                                DropdownMenuItem(text = { Text("Play next") }, onClick = { menu = false; sequencer.moveUpcomingNext(item.uid) })
                                DropdownMenuItem(text = { Text("Move to end") }, onClick = { menu = false; sequencer.moveUpcomingToEnd(item.uid) })
                                DropdownMenuItem(text = { Text("Remove") }, onClick = { menu = false; sequencer.removeUpcoming(setOf(item.uid)) })
                                DropdownMenuItem(text = { Text("Song detail") }, onClick = { menu = false; onSongDetail(item) })
                            }
                        }
                    }
                }
            }
        }
        if (upcoming.size > rows.size) {
            Text(
                "+ ${upcoming.size - rows.size} more",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 8.dp),
            )
        }
    }
}

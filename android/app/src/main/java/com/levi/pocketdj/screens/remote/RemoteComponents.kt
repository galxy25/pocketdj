package com.levi.pocketdj.screens.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.remote.RemoteDeviceRole
import com.levi.pocketdj.remote.RemoteRow
import com.levi.pocketdj.remote.RemoteSessionController
import com.levi.pocketdj.remote.RemoteSessionMode
import kotlin.math.roundToInt

private val Warn = Color(0xFFFF9800)

@Composable
fun RemoteSectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = modifier.fillMaxWidth().padding(top = 18.dp, bottom = 6.dp),
    )
}

@Composable
fun RemoteBadge(text: String, tint: Color, modifier: Modifier = Modifier) {
    Text(
        text, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = tint,
        modifier = modifier.background(tint.copy(alpha = 0.15f), CircleShape).padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

@Composable
fun RemoteWarning(text: String, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Warning, null, tint = Warn, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(4.dp))
        Text(text, style = MaterialTheme.typography.bodySmall, color = Warn)
    }
}

/** One participant: name, Host / role badges and the "N songs can't play here" warning. Tag `remote-peer-<id>`. */
@Composable
fun RemotePeerRow(peer: RemoteSessionController.Peer, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().padding(vertical = 6.dp).testTag("remote-peer-${peer.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(if (peer.isLocal) "${peer.name} (this device)" else peer.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
            RemoteQueueUi.songsCantPlayText(peer.unavailableCount)?.let { RemoteWarning(it) }
        }
        if (peer.isHost) { RemoteBadge("Host", MaterialTheme.colorScheme.primary); Spacer(Modifier.width(6.dp)) }
        RemoteBadge(
            if (peer.role == RemoteDeviceRole.SPEAKER) "Speaker" else "Controller",
            MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** ⏮ ▶/⏸ ⏭ for the SESSION: commands to the host, never the local player. */
@Composable
fun RemoteTransportRow(
    isPlaying: Boolean, onPrevious: () -> Unit, onPlayPause: () -> Unit, onNext: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onPrevious, Modifier.size(52.dp).testTag("remote-prev")) {
            Icon(Icons.Filled.SkipPrevious, "Previous", Modifier.size(32.dp), tint = MaterialTheme.colorScheme.primary)
        }
        Spacer(Modifier.width(20.dp))
        IconButton(onPlayPause, Modifier.size(64.dp).testTag("remote-playpause")) {
            Icon(
                if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (isPlaying) "Pause" else "Play",
                Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary,
            )
        }
        Spacer(Modifier.width(20.dp))
        IconButton(onNext, Modifier.size(52.dp).testTag("remote-next")) {
            Icon(Icons.Filled.SkipNext, "Next", Modifier.size(32.dp), tint = MaterialTheme.colorScheme.primary)
        }
    }
}

/** The scrubber: shows the live position, sends ONE seek when the drag ends. */
@Composable
fun RemoteScrubber(positionMs: Long, lengthMs: Long?, onSeek: (Long) -> Unit, modifier: Modifier = Modifier) {
    val total = (lengthMs ?: 0L).coerceAtLeast(1L).toFloat()
    var drag by remember { mutableStateOf<Float?>(null) }
    val shown = (drag ?: positionMs.toFloat()).coerceIn(0f, total)
    Column(modifier.fillMaxWidth()) {
        Slider(
            value = shown, onValueChange = { drag = it },
            onValueChangeFinished = { drag?.let { onSeek(it.toLong()) }; drag = null },
            valueRange = 0f..total, enabled = lengthMs != null,
            modifier = Modifier.testTag("remote-scrubber"),
        )
        Row(Modifier.fillMaxWidth()) {
            Text(RemoteQueueUi.clock(shown.toLong()), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            Text(
                if (lengthMs == null) "–:––" else RemoteQueueUi.clock(lengthMs),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A start card (iOS copy): title, blurb, spinner while starting. Tag `remote-start-<mode>`. */
@Composable
fun RemoteStartCard(
    mode: RemoteSessionMode, blurb: String, icon: ImageVector, starting: Boolean, enabled: Boolean,
    modifier: Modifier = Modifier, onClick: () -> Unit,
) {
    Surface(
        modifier.fillMaxWidth().padding(vertical = 4.dp).testTag("remote-start-${if (mode == RemoteSessionMode.BACKSEAT) "backseat" else "listenTogether"}"),
        shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Row(
            Modifier.clickable(enabled = enabled, onClick = onClick).padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(30.dp))
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(mode.title, style = MaterialTheme.typography.titleMedium)
                Text(blurb, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (starting) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
        }
    }
}

/** A Play Now / Play Next / Remove overflow menu for one Up Next row. */
@Composable
private fun RowMenu(onPlayNow: () -> Unit, onPlayNext: () -> Unit, onRemove: () -> Unit, tag: String) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton({ open = true }, Modifier.testTag(tag)) { Icon(Icons.Filled.MoreVert, "Row actions") }
        DropdownMenu(open, { open = false }) {
            DropdownMenuItem({ Text("Play Now") }, { open = false; onPlayNow() })
            DropdownMenuItem({ Text("Play Next") }, { open = false; onPlayNext() })
            DropdownMenuItem({ Text("Remove") }, { open = false; onRemove() })
        }
    }
}

/**
 * The Up Next list: per-row menu (Play Now / Play Next / Remove), an "Unavailable on …" note, and a drag handle that
 * reports ONE reorder (from, to) when released. Rows are a plain Column (the session window is short), so the drag target
 * is the measured row height.
 */
@Composable
fun RemoteUpNextList(
    rows: List<RemoteRow>,
    unavailableOn: (rid: String) -> List<String>,
    onPlayNow: (String) -> Unit, onPlayNext: (String) -> Unit, onRemove: (String) -> Unit,
    onReorder: (from: Int, to: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    var dragIdx by remember { mutableIntStateOf(-1) }
    var dragDy by remember { mutableFloatStateOf(0f) }
    var rowPx by remember { mutableFloatStateOf(0f) }
    Column(modifier.fillMaxWidth().testTag("remote-upnext")) {
        rows.forEachIndexed { i, row ->
            val dragging = dragIdx == i
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp)
                    .onSizeChanged { if (rowPx == 0f) rowPx = it.height.toFloat() }
                    .offset { IntOffset(0, if (dragging) dragDy.roundToInt() else 0) }
                    .then(if (dragging) Modifier.background(MaterialTheme.colorScheme.surfaceVariant) else Modifier)
                    .testTag("remote-upnext-${row.rid}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(row.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(row.artist, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    RemoteQueueUi.unavailableText(unavailableOn(row.rid))?.let { RemoteWarning(it) }
                }
                RowMenu({ onPlayNow(row.rid) }, { onPlayNext(row.rid) }, { onRemove(row.rid) }, "remote-upnext-menu-${row.rid}")
                Icon(
                    Icons.Filled.DragHandle, "Drag to reorder",
                    Modifier.size(32.dp).padding(4.dp).testTag("remote-drag-${row.rid}").pointerInput(rows.map { it.rid }) {
                        detectDragGestures(
                            onDragStart = { dragIdx = i; dragDy = 0f },
                            onDrag = { change, amount -> change.consume(); dragDy += amount.y },
                            onDragEnd = {
                                val to = RemoteQueueUi.dragTarget(i, dragDy, rowPx, rows.size)
                                dragIdx = -1; dragDy = 0f
                                if (to != i) onReorder(i, to)
                            },
                            onDragCancel = { dragIdx = -1; dragDy = 0f },
                        )
                    },
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** A search hit with a Play Now / Play Next / Add to Queue menu. Tag `remote-add-<songId>`. */
@Composable
fun RemoteSearchRow(
    song: IndexSong, onNow: () -> Unit, onNext: () -> Unit, onEnd: () -> Unit, modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    Row(modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(song.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(song.artist, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box {
            IconButton({ open = true }, Modifier.testTag("remote-add-${song.id}")) {
                Icon(Icons.Filled.Add, "Add ${song.name}", tint = MaterialTheme.colorScheme.primary)
            }
            DropdownMenu(open, { open = false }) {
                DropdownMenuItem({ Text("Play Now") }, { open = false; onNow() })
                DropdownMenuItem({ Text("Play Next") }, { open = false; onNext() })
                DropdownMenuItem({ Text("Add to Queue") }, { open = false; onEnd() })
            }
        }
    }
}

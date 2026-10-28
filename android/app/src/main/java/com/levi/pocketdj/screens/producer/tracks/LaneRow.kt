package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioTrack
import com.levi.pocketdj.studio.store.ArrangerMath
import kotlin.math.max
import kotlin.math.roundToInt

const val LANE_HEIGHT = 66
const val LANE_GAP = 8
const val HEADER_WIDTH = 172

/** The fixed left header of one lane: colour chip + name (-> edit sheet), add clip, menu, M / S, gain. */
@Composable
fun TrackHeader(
    track: StudioTrack,
    index: Int,
    onEdit: () -> Unit,
    onAddClip: () -> Unit,
    onDuplicate: () -> Unit,
    onDelete: () -> Unit,
    onMute: (Boolean) -> Unit,
    onSolo: (Boolean) -> Unit,
    onGain: (Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val color = trackColor(track.colorIndex)
    var menu by remember { mutableStateOf(false) }
    Column(
        modifier.width(HEADER_WIDTH.dp).height(LANE_HEIGHT.dp).clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 8.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(width = 16.dp, height = 22.dp).clip(RoundedCornerShape(3.dp)).background(color)
                    .clickable(onClick = onEdit).semantics { contentDescription = "Edit track colour" }.testTag("tracks-track-color-$index"),
            )
            Text(
                track.name.ifEmpty { "Track" }, Modifier.weight(1f).padding(start = 6.dp).clickable(onClick = onEdit).testTag("tracks-track-name-$index"),
                style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            IconButton(onClick = onAddClip, modifier = Modifier.size(28.dp).testTag("tracks-add-clip-$index")) {
                Icon(Icons.Filled.AddCircle, "Add clip to ${track.name}", tint = color, modifier = Modifier.size(20.dp))
            }
            Box {
                IconButton(onClick = { menu = true }, modifier = Modifier.size(28.dp).testTag("tracks-track-menu-$index")) {
                    Icon(Icons.Filled.MoreVert, "Track actions", modifier = Modifier.size(18.dp))
                }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("Edit track…") }, onClick = { menu = false; onEdit() })
                    DropdownMenuItem(text = { Text("Add clip…") }, onClick = { menu = false; onAddClip() })
                    DropdownMenuItem(text = { Text("Duplicate") }, onClick = { menu = false; onDuplicate() }, modifier = Modifier.testTag("tracks-track-duplicate-$index"))
                    DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete() }, modifier = Modifier.testTag("tracks-track-delete-$index"))
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            MsButton("M", track.muted, MaterialTheme.colorScheme.error, "Mute", "tracks-track-mute-$index") { onMute(!track.muted) }
            MsButton("S", track.soloed, MaterialTheme.colorScheme.tertiary, "Solo", "tracks-track-solo-$index") { onSolo(!track.soloed) }
            Slider(
                value = track.gainDb.toFloat().coerceIn(-24f, 6f), onValueChange = { onGain(it.toDouble()) }, valueRange = -24f..6f,
                modifier = Modifier.weight(1f).height(24.dp).semantics { contentDescription = "Gain ${"%.1f".format(java.util.Locale.US, track.gainDb)} dB" }.testTag("tracks-track-gain-$index"),
            )
            if (kotlin.math.abs(track.pan) > 0.02) Text(if (track.pan < 0) "L" else "R", fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, color = MaterialTheme.colorScheme.tertiary)
        }
    }
}

@Composable
private fun MsButton(label: String, on: Boolean, onColor: androidx.compose.ui.graphics.Color, desc: String, tag: String, onClick: () -> Unit) {
    Box(
        Modifier.size(width = 22.dp, height = 20.dp).clip(RoundedCornerShape(4.dp))
            .background(if (on) onColor else MaterialTheme.colorScheme.surface)
            .clickable(onClick = onClick).semantics { contentDescription = "$desc${if (on) ", on" else ""}" }.testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = if (on) androidx.compose.ui.graphics.Color.White else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** One lane's clip strip, [width] dp wide: a rounded well with its clips at their timeline x. */
@Composable
fun LaneStrip(
    track: StudioTrack,
    index: Int,
    pxPerSec: Float,
    width: Float,
    peaks: Map<String, FloatArray>,
    beatMatch: Boolean,
    bpm: Double,
    onMoveClip: (clipId: String, toStartMs: Int) -> Unit,
    onRemoveClip: (clipId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val color = trackColor(track.colorIndex)
    Box(modifier.width(width.dp).height(LANE_HEIGHT.dp).clip(RoundedCornerShape(6.dp)).background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)).testTag("tracks-lane-$index")) {
        if (track.clips.isEmpty()) {
            Text("Tap + to add a clip", Modifier.padding(start = 10.dp, top = 8.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
        }
        track.clips.forEachIndexed { ci, clip ->
            ClipBlock(clip, index, ci, color, pxPerSec, peaks[clip.id], beatMatch, bpm, onMove = { onMoveClip(clip.id, it) }, onRemove = { onRemoveClip(clip.id) })
        }
    }
}

@Composable
private fun ClipBlock(
    clip: StudioClip, trackIndex: Int, clipIndex: Int, color: androidx.compose.ui.graphics.Color, pxPerSec: Float,
    peaks: FloatArray?, beatMatch: Boolean, bpm: Double, onMove: (Int) -> Unit, onRemove: () -> Unit,
) {
    var dragDx by remember(clip.id, clip.startMs) { mutableFloatStateOf(0f) }
    var menu by remember { mutableStateOf(false) }
    val move by rememberUpdatedState(onMove)
    val w = ArrangerMath.clipWidth(clip.durationMs, pxPerSec)
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    Box(
        Modifier
            .offset { IntOffset((ArrangerMath.clipX(clip.startMs, pxPerSec, dragDx) * density).roundToInt(), (4 * density).roundToInt()) }
            .size(width = w.dp, height = (LANE_HEIGHT - 8).dp)
            .clip(RoundedCornerShape(5.dp)).background(color.copy(alpha = 0.30f))
            .border(1.dp, color.copy(alpha = 0.9f), RoundedCornerShape(5.dp))
            .semantics { contentDescription = clip.name }
            .testTag("tracks-clip-$trackIndex-$clipIndex")
            .clickable { menu = true }
            .pointerInput(clip.id, clip.startMs, pxPerSec, beatMatch, bpm) {
                var total = 0f
                detectDragGestures(
                    onDragStart = { total = 0f },
                    onDragEnd = { move(ArrangerMath.dropMs(clip.startMs, total / density, pxPerSec, beatMatch, bpm)); dragDx = 0f },
                    onDragCancel = { dragDx = 0f },
                ) { c, d -> total += d.x; dragDx = total / density; c.consume() }
            },
    ) {
        Canvas(Modifier.fillMaxSize().padding(start = 3.dp, end = 3.dp, top = 12.dp, bottom = 3.dp)) {
            val p = peaks ?: return@Canvas
            if (p.isEmpty()) return@Canvas
            val mid = size.height / 2; val bar = size.width / p.size
            for (i in p.indices) {
                val x = (i + 0.5f) * bar; val amp = max(1f, p[i] * size.height * 0.5f)
                drawLine(color, Offset(x, mid - amp), Offset(x, mid + amp), strokeWidth = max(1f, bar * 0.7f))
            }
        }
        Text(clip.name, Modifier.padding(horizontal = 4.dp, vertical = 2.dp), fontSize = 9.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(text = { Text("Remove clip") }, onClick = { menu = false; onRemove() }, modifier = Modifier.testTag("tracks-clip-remove-$trackIndex-$clipIndex"))
        }
    }
}

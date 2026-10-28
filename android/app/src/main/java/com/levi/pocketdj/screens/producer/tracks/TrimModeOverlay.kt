package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.store.TrimSession

/** The scissor tool toggle: accent while trimming; disabled on an empty arrangement (nothing to cut). */
@Composable
fun ScissorButton(trimming: Boolean, enabled: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    FilledIconToggleButton(
        checked = trimming, onCheckedChange = { onToggle() }, enabled = enabled || trimming,
        modifier = modifier.semantics { contentDescription = "Scissor trim ${if (trimming) "on" else "off"}" }.testTag("tracks-scissor-toggle"),
    ) { Icon(Icons.Filled.ContentCut, null) }
}

/** Lane dimming rule: a non-selected track is faded while trimming. */
fun trimLaneAlpha(trimming: Boolean, selected: Boolean) = if (trimming && !selected) 0.45f else 1f

/**
 * The trim toolbar (only while trimming): choose which tracks to cut (multi-select, ALL by default, LOCKED once
 * a cut is staged), Delete the region, Undo the last cut, Cancel / Save the whole session. [rev] is the host's
 * mutation counter so this recomposes when the (mutable) [session] changes.
 */
@Composable
fun TrimToolbar(
    arr: StudioArrangement, session: TrimSession, rev: Int,
    onChanged: () -> Unit, onCancel: () -> Unit, onSave: () -> Unit, modifier: Modifier = Modifier,
) {
    @Suppress("UNUSED_VARIABLE") val observe = rev
    var menu by remember { mutableStateOf(false) }
    val names = arr.tracks.associate { it.id to it.name }
    Row(
        modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box {
            OutlinedButton(onClick = { menu = true }, modifier = Modifier.testTag("tracks-trim-track")) {
                Text(session.selectionLabel { names[it].orEmpty() })
            }
            DropdownMenu(menu, { menu = false }) {
                if (session.selectionLocked) Text("Save or Cancel before changing tracks", Modifier.padding(horizontal = 12.dp, vertical = 4.dp), style = MaterialTheme.typography.labelSmall)
                DropdownMenuItem(
                    text = { Text((if (session.allSelected()) "✓ " else "    ") + "All tracks") },
                    enabled = !session.selectionLocked,
                    onClick = { session.selectAll(); onChanged() }, modifier = Modifier.testTag("tracks-trim-all"),
                )
                arr.tracks.forEachIndexed { i, t ->
                    DropdownMenuItem(
                        text = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(checked = t.id in session.selected, onCheckedChange = null, enabled = !session.selectionLocked)
                                Text(t.name.ifBlank { "Track" }, Modifier.padding(start = 8.dp))
                            }
                        },
                        enabled = !session.selectionLocked,
                        onClick = { session.setSelected(t.id, t.id !in session.selected); onChanged() },
                        modifier = Modifier.testTag("tracks-trim-track-$i"),
                    )
                }
            }
        }
        FilledTonalButton(onClick = { session.cut(); onChanged() }, enabled = session.canCut, modifier = Modifier.testTag("tracks-trim-delete")) {
            Icon(Icons.Filled.DeleteSweep, null, Modifier.size(18.dp)); Text("Delete", Modifier.padding(start = 4.dp))
        }
        IconButton(onClick = { session.undo(); onChanged() }, enabled = session.canUndo, modifier = Modifier.semantics { contentDescription = "Undo cut" }.testTag("tracks-trim-undo")) {
            Icon(Icons.AutoMirrored.Filled.Undo, null)
        }
        TextButton(onClick = onCancel, modifier = Modifier.testTag("tracks-trim-cancel")) { Text("Cancel") }
        Button(onClick = onSave, enabled = session.canSave, modifier = Modifier.testTag("tracks-trim-save")) { Text("Save") }
    }
}

/**
 * The cut-region band + two draggable handles, laid over the LANES (a child of the scrolling timeline, so dp x =
 * ms * pxPerSec). It also absorbs taps so the staged clips underneath can't be moved/removed mid-trim (add-clip
 * affordances are disabled during trimming; Save would clobber them). Handles always snap to the beat grid.
 */
@Composable
fun TrimRegionLayer(
    session: TrimSession, rev: Int, pxPerSec: Float, bpm: Double, lengthMs: Int,
    onChanged: () -> Unit, modifier: Modifier = Modifier,
) {
    @Suppress("UNUSED_VARIABLE") val observe = rev
    val density = LocalDensity.current.density
    val startMs = session.regionStartMs; val endMs = session.regionEndMs
    val x0 = LoopRegionMath.msToDp(startMs, pxPerSec); val x1 = LoopRegionMath.msToDp(endMs, pxPerSec)
    val curPx by rememberUpdatedState(pxPerSec); val curBpm by rememberUpdatedState(bpm); val curLen by rememberUpdatedState(lengthMs)
    var originStart by remember { mutableIntStateOf(startMs) }
    var originEnd by remember { mutableIntStateOf(endMs) }
    val danger = MaterialTheme.colorScheme.error
    Box(modifier.pointerInput(Unit) { detectTapGestures { } }.testTag("tracks-trim-layer")) {
        Box(
            Modifier.offset(x = x0.dp).width((x1 - x0).coerceAtLeast(1f).dp).fillMaxHeight().background(danger).alpha(0.18f).testTag("tracks-trim-band"),
        )
        TrimHandle(x0 - 10f, danger, "Trim start", "tracks-trim-start", onBegin = { originStart = session.regionStartMs }) { totalPx ->
            val s = TrimMath.dragStart(originStart, session.regionEndMs, totalPx / density, curPx, curBpm)
            session.setRegion(s, session.regionEndMs); onChanged()
        }
        TrimHandle(x1 - 10f, danger, "Trim end", "tracks-trim-end", onBegin = { originEnd = session.regionEndMs }) { totalPx ->
            val e = TrimMath.dragEnd(session.regionStartMs, originEnd, totalPx / density, curPx, curBpm, curLen)
            session.setRegion(session.regionStartMs, e); onChanged()
        }
    }
}

/** Region-drag math (pure, tested): beat-snapped, never inverted, end clamped to the timeline. */
object TrimMath {
    const val MIN_MS = 1

    fun dragStart(originStartMs: Int, endMs: Int, dxDp: Float, pxPerSec: Float, bpm: Double): Int {
        val raw = LoopRegionMath.snap(originStartMs + LoopRegionMath.dpToMs(dxDp, pxPerSec), bpm, true)
        return raw.coerceIn(0, maxOf(0, endMs - MIN_MS))
    }

    fun dragEnd(startMs: Int, originEndMs: Int, dxDp: Float, pxPerSec: Float, bpm: Double, lengthMs: Int): Int {
        val raw = LoopRegionMath.snap(originEndMs + LoopRegionMath.dpToMs(dxDp, pxPerSec), bpm, true)
        val upper = if (lengthMs > 0) maxOf(lengthMs, startMs + MIN_MS) else Int.MAX_VALUE
        return raw.coerceIn(startMs + MIN_MS, upper)
    }
}

@Composable
private fun TrimHandle(xDp: Float, color: androidx.compose.ui.graphics.Color, label: String, tag: String, onBegin: () -> Unit, onDrag: (Float) -> Unit) {
    Box(
        Modifier.offset(x = xDp.coerceAtLeast(0f).dp).width(20.dp).fillMaxHeight()
            .pointerInput(tag) {
                var total = 0f
                detectHorizontalDragGestures(onDragStart = { total = 0f; onBegin() }) { change, dx -> change.consume(); total += dx; onDrag(total) }
            }
            .semantics { contentDescription = label }.testTag(tag),
        contentAlignment = Alignment.TopCenter,
    ) { Box(Modifier.width(4.dp).fillMaxHeight().background(color)) }
}

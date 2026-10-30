package com.levi.pocketdj.screens.producer.samples

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.screens.producer.common.WaveformMath
import com.levi.pocketdj.studio.demux.BeatDetect
import com.levi.pocketdj.studio.engine.SliceMath
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSlice
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max

/**
 * Slice a sample into up to 8 performance PADS (iOS StudioSliceEditorView). Each pad is a start-marker
 * ([StudioSlice]) that plays from its start to the next pad's start (or the sample's end) as a ONE-SHOT through
 * `StudioEngine.playSlice` on the already-loaded RAW sample, so tapping pads never touches the editor's trim window.
 *
 * Auto-slice partitions the sample into N pads: beat-snapped when the sample has a grid (coincident snaps merge),
 * an even time chop otherwise. Manual: drag a marker on the waveform, nudge/rename/delete a pad. "Make sample" bakes
 * a pad into a normal `smp_` sample; "Send pads to sequencer" bakes every pad into a new pattern.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun SliceEditorSheet(graph: AppGraph, sampleId: String, pcm: PcmBuffer? = null, onDismiss: () -> Unit) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val engine = studio.studioEngine
    val doc by store.state.collectAsState()
    val sample: StudioSample? = doc.samples.firstOrNull { it.id == sampleId }
    val pads = remember(doc, sampleId) { store.slices(sampleId) }
    val scope = rememberCoroutineScope()

    var buffer by remember { mutableStateOf(pcm) }
    var peaks by remember { mutableStateOf(FloatArray(0)) }
    var sliceCount by remember { mutableStateOf(4) }
    var detecting by remember { mutableStateOf(false) }
    var detectFailed by remember { mutableStateOf(false) }
    var baking by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    var renameSlot by remember { mutableStateOf<Int?>(null) }

    // The editor owns the loaded RAW sample; load it here only when we were opened standalone.
    LaunchedEffect(sampleId) {
        val s = store.sample(sampleId) ?: return@LaunchedEffect
        val buf = buffer ?: withContext(Dispatchers.IO) { studio.sampleRenderCache.withSource(s) { f -> runCatching { studio.studioRender.decodeBuffer(f.path) }.getOrNull() } } ?: return@LaunchedEffect
        buffer = buf
        peaks = withContext(Dispatchers.Default) { WaveformMath.peaks(buf, 160) }
        if (engine.loadedSampleId.value != sampleId) engine.loadSample(s, buf)
    }
    // Stop any pad audition; the sample stays loaded for the editor beneath.
    DisposableEffect(sampleId) { onDispose { engine.stopSample() } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        if (sample == null) {
            Text("This sample is no longer available.", Modifier.padding(24.dp)); return@ModalBottomSheet
        }
        val dur = max(1, sample.durationMs)
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).testTag("slice-editor"),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Slice into pads", style = MaterialTheme.typography.titleLarge)
                    Text(sample.name, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Button(onClick = onDismiss, modifier = Modifier.testTag("slice-done")) { Text("Done") }
            }

            SliceWaveform(
                peaks = peaks, pads = pads, durationMs = dur,
                onCommit = { slot, ms -> store.setSlice(sampleId, slot, ms) },
            )

            // Auto-slice
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                IconButton(onClick = { if (sliceCount > 2) sliceCount-- }, enabled = sliceCount > 2, modifier = Modifier.testTag("slice-count-dec")) { Icon(Icons.Filled.Remove, "Fewer slices") }
                Text("$sliceCount slices", Modifier.testTag("slice-count"), style = MaterialTheme.typography.bodyLarge)
                IconButton(onClick = { if (sliceCount < StudioSlice.MAX_SLOTS) sliceCount++ }, enabled = sliceCount < StudioSlice.MAX_SLOTS, modifier = Modifier.testTag("slice-count-inc")) { Icon(Icons.Filled.Add, "More slices") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                FilledTonalButton(
                    onClick = {
                        engine.stopSample()
                        store.setSlices(sampleId, SliceMath.autoStarts(sliceCount, sample.grid, sample.durationMs))
                    },
                    modifier = Modifier.testTag("slice-auto"),
                ) { Icon(Icons.Filled.GridView, null); Text("Auto-slice", Modifier.padding(start = 6.dp)) }
                if (pads.isNotEmpty()) {
                    OutlinedButton(onClick = { engine.stopSample(); store.clearSlices(sampleId) }, modifier = Modifier.testTag("slice-clear")) {
                        Icon(Icons.Filled.Delete, null); Text("Clear", Modifier.padding(start = 6.dp))
                    }
                }
            }
            val g = sample.grid
            if (g != null) {
                Text("Auto-slice snaps to the ${StudioFmt.trim(g.bpm)} BPM grid.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedButton(
                        enabled = !detecting && buffer != null,
                        onClick = {
                            val b = buffer ?: return@OutlinedButton
                            detecting = true; detectFailed = false
                            scope.launch {
                                val grid = withContext(Dispatchers.Default) { BeatDetect.detectGrid(b) }
                                detecting = false
                                if (grid != null) store.setSampleGrid(sampleId, grid) else detectFailed = true
                            }
                        },
                        modifier = Modifier.testTag("slice-detect-bpm"),
                    ) {
                        if (detecting) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                        Text(if (detecting) "Detecting…" else "Detect BPM", Modifier.padding(start = if (detecting) 6.dp else 0.dp))
                    }
                    Text(
                        if (detectFailed) "No tempo found — even chop it is." else "No grid: auto-slice does an even chop.",
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // Pad grid: 2 x 4
            for (row in 0 until 2) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    for (col in 0 until 4) {
                        val slot = row * 4 + col
                        Box(Modifier.weight(1f)) {
                            PadCell(
                                slot = slot, pad = pads.firstOrNull { it.slot == slot },
                                onTap = {
                                    SliceMath.window(pads, slot, sample.durationMs)?.let { (a, b) -> engine.playSlice(a, b) }
                                },
                                onAdd = { store.setSlice(sampleId, slot, SliceMath.defaultAddStart(sample.durationMs, slot)) },
                                onRename = { renameSlot = slot },
                                onNudge = { d -> store.nudgeSlice(sampleId, slot, d) },
                                onMakeSample = {
                                    scope.launch {
                                        val id = studio.sliceBaker.bakePad(sampleId, slot)
                                        notice = if (id != null) "Baked pad ${slot + 1} → a new sample." else "Couldn’t bake pad ${slot + 1} — check the samples folder."
                                    }
                                },
                                onDelete = { engine.stopSample(); store.removeSlice(sampleId, slot) },
                            )
                        }
                    }
                }
            }
            Text("Tap a pad to hear it. Long-press for rename, nudge, make sample, delete.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            // Bake
            Button(
                onClick = {
                    baking = true
                    scope.launch {
                        try {
                            val r = studio.sliceBaker.sendToSequencer(sampleId)
                            notice = if (r != null) "Baked ${r.baked} pads → a new sequencer pattern." else "Couldn’t bake the pads — check the samples folder."
                        } catch (e: kotlinx.coroutines.CancellationException) { throw e
                        } catch (e: Exception) { notice = "Couldn’t bake the pads — check the samples folder."
                        } finally { baking = false }
                    }
                },
                enabled = !baking && pads.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().testTag("slice-send-sequencer"),
            ) {
                if (baking) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Text(if (baking) "Baking pads…" else "Send pads to sequencer", Modifier.padding(start = if (baking) 8.dp else 0.dp))
            }
            notice?.let { Text(it, Modifier.testTag("slice-notice"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Box(Modifier.height(16.dp))
        }
        renameSlot?.let { slot ->
            NameDialog("Rename pad", store.slice(sampleId, slot)?.name ?: "", "Save", { renameSlot = null }) { store.renameSlice(sampleId, slot, it); renameSlot = null }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PadCell(
    slot: Int, pad: StudioSlice?, onTap: () -> Unit, onAdd: () -> Unit, onRename: () -> Unit,
    onNudge: (Int) -> Unit, onMakeSample: () -> Unit, onDelete: () -> Unit,
) {
    val color = Color(SliceMath.slotColor(slot))
    var menu by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(8.dp)
    if (pad == null) {
        Column(
            Modifier.fillMaxWidth().heightIn(min = 56.dp).combinedClickable(onClick = onAdd).testTag("slice-pad-$slot")
                .semantics { contentDescription = "Add pad ${slot + 1}" },
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
        ) {
            Icon(Icons.Filled.Add, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("Add", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    Box {
        Column(
            Modifier.fillMaxWidth().heightIn(min = 56.dp).background(color.copy(alpha = 0.22f), shape)
                .combinedClickable(onClick = onTap, onLongClick = { menu = true })
                .testTag("slice-pad-$slot").semantics { contentDescription = "${SliceMath.padLabel(pad)} at ${StudioFmt.mmssTenths(pad.startMs)}" },
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
        ) {
            Text(SliceMath.padLabel(pad), style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(StudioFmt.mmssTenths(pad.startMs), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; onRename() })
            DropdownMenuItem(text = { Text("Nudge −50 ms") }, onClick = { onNudge(-50) }, modifier = Modifier.testTag("slice-nudge-minus-$slot"))
            DropdownMenuItem(text = { Text("Nudge +50 ms") }, onClick = { onNudge(50) }, modifier = Modifier.testTag("slice-nudge-plus-$slot"))
            DropdownMenuItem(text = { Text("Make sample") }, onClick = { menu = false; onMakeSample() }, modifier = Modifier.testTag("slice-make-sample-$slot"))
            DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete() })
        }
    }
}

/**
 * Waveform with up to 8 draggable pad markers. A drag only moves a LOCAL position per frame and commits to the
 * store once, on release (no store write per frame).
 */
@Composable
private fun SliceWaveform(peaks: FloatArray, pads: List<StudioSlice>, durationMs: Int, onCommit: (slot: Int, ms: Int) -> Unit) {
    val wave = MaterialTheme.colorScheme.primary
    val dim = MaterialTheme.colorScheme.outline
    val padsNow by rememberUpdatedState(pads)
    val commit by rememberUpdatedState(onCommit)
    var dragSlot by remember { mutableStateOf<Int?>(null) }
    var dragMs by remember { mutableStateOf(0) }
    Canvas(
        Modifier.fillMaxWidth().height(96.dp).semantics { contentDescription = "Sample waveform with pad markers" }.testTag("slice-waveform")
            .pointerInput(durationMs) {
                detectDragGestures(
                    onDragStart = { o ->
                        dragSlot = SliceMath.nearestSlot(padsNow, durationMs, size.width.toFloat(), o.x, 28.dp.toPx())
                        dragSlot?.let { s -> dragMs = padsNow.firstOrNull { it.slot == s }?.startMs ?: 0 }
                    },
                    onDragEnd = { dragSlot?.let { commit(it, dragMs) }; dragSlot = null },
                    onDragCancel = { dragSlot = null },
                ) { change, _ ->
                    if (dragSlot != null) {
                        dragMs = SliceMath.msAt(change.position.x / size.width, durationMs)
                        change.consume()
                    }
                }
            },
    ) {
        val w = size.width; val h = size.height; val mid = h / 2
        val n = peaks.size
        if (n > 0) {
            val bar = w / n
            for (i in 0 until n) {
                val x = (i + 0.5f) * bar
                val amp = max(1f, peaks[i] * (h * 0.46f))
                drawLine(wave, Offset(x, mid - amp), Offset(x, mid + amp), strokeWidth = max(1f, bar * 0.7f), cap = StrokeCap.Round)
            }
        } else drawLine(dim, Offset(0f, mid), Offset(w, mid), strokeWidth = 2f)
        for (p in padsNow) {
            val ms = if (dragSlot == p.slot) dragMs else p.startMs
            val x = w * ms.coerceIn(0, durationMs) / durationMs
            val c = Color(SliceMath.slotColor(p.slot))
            drawLine(c, Offset(x, 0f), Offset(x, h), strokeWidth = 2.dp.toPx())
            drawCircle(c, 8.dp.toPx(), Offset(x, 8.dp.toPx()))
        }
    }
}

package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.producer.common.EditSlider
import com.levi.pocketdj.studio.model.StudioChannelStrip
import com.levi.pocketdj.studio.store.ArrangerMath
import com.levi.pocketdj.studio.store.StudioStore
import com.levi.pocketdj.studio.store.TrackPalette
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

fun trackColor(index: Int): Color = Color(0xFF000000.toInt() or TrackPalette.rgb(index))

/**
 * One sheet for a lane's NAME, COLOUR (big swatches), PAN (rotary dial) and channel strip (pitch / tempo /
 * EQ / reverb / delay / chorus). Colour, pan and strip write live through the store's clamped setters; the
 * name commits on Done or dismissal.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrackEditSheet(store: StudioStore, arrangementId: String, trackId: String, onDismiss: () -> Unit) {
    val doc by store.state.let { flow -> androidx.compose.runtime.produceState(flow.value, flow) { flow.collect { value = it } } }
    val track = doc.arrangements.firstOrNull { it.id == arrangementId }?.tracks?.firstOrNull { it.id == trackId }
    var name by remember { mutableStateOf(track?.name ?: "") }
    fun commit() { val n = name.trim(); if (n.isNotEmpty()) store.renameTrack(arrangementId, trackId, n) }
    val strip = track?.strip ?: StudioChannelStrip()
    fun setStrip(f: (StudioChannelStrip) -> StudioChannelStrip) = store.setTrackStrip(arrangementId, trackId, f(strip))

    ModalBottomSheet(
        onDismissRequest = { commit(); onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        modifier = Modifier.testTag("track-edit-sheet"),
    ) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Edit track", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = { commit(); onDismiss() }, modifier = Modifier.testTag("track-edit-done")) { Text("Done") }
            }
            OutlinedTextField(name, { name = it }, label = { Text("Track name") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("track-edit-name"))

            Text("Colour", style = MaterialTheme.typography.labelLarge)
            for (rowStart in 0 until TrackPalette.size step 4) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    for (ci in rowStart until min(rowStart + 4, TrackPalette.size)) {
                        val selected = track?.colorIndex == ci
                        Box(
                            Modifier.weight(1f).height(40.dp).clip(RoundedCornerShape(8.dp)).background(trackColor(ci))
                                .border(2.dp, if (selected) MaterialTheme.colorScheme.onSurface else Color.Transparent, RoundedCornerShape(8.dp))
                                .clickable { store.setTrackColor(arrangementId, trackId, ci) }
                                .semantics { contentDescription = "${TrackPalette.name(ci)}${if (selected) ", selected" else ""}" }
                                .testTag("track-edit-color-$ci"),
                            contentAlignment = Alignment.Center,
                        ) { if (selected) Icon(Icons.Filled.Check, null, tint = Color.Black) }
                    }
                }
            }

            Text("Pan", style = MaterialTheme.typography.labelLarge)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceEvenly) {
                Text("L", color = MaterialTheme.colorScheme.onSurfaceVariant)
                PanDial(track?.pan ?: 0.0) { store.setTrackPan(arrangementId, trackId, it) }
                Text("R", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(ArrangerMath.panText(track?.pan ?: 0.0), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = { store.setTrackPan(arrangementId, trackId, 0.0) }, modifier = Modifier.testTag("track-edit-pan-center")) { Text("Center") }
            }

            Text("Pitch & tempo", style = MaterialTheme.typography.labelLarge)
            EditSlider("Pitch", -12.0..12.0, strip.pitchSemitones, { "${if (it > 0) "+" else ""}${it.toInt()} st" }, "track-edit-pitch", step = 1.0) { v -> setStrip { it.copy(pitchSemitones = v) } }
            EditSlider("Tempo", 0.1..10.0, strip.tempoRatio, { "%.2fx".format(java.util.Locale.US, it) }, "track-edit-tempo", step = 0.05) { v -> setStrip { it.copy(tempoRatio = v) } }
            Text("Pitch shifts without changing speed; tempo changes speed. Applied on release.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("EQ", style = MaterialTheme.typography.labelLarge)
            val db = { v: Double -> "${if (v > 0) "+" else ""}${"%.1f".format(java.util.Locale.US, v)} dB" }
            EditSlider("Low", -18.0..18.0, strip.eqLowDb, db, "track-edit-eq-low", step = 0.5) { v -> setStrip { it.copy(eqLowDb = v) } }
            EditSlider("Mid", -18.0..18.0, strip.eqMidDb, db, "track-edit-eq-mid", step = 0.5) { v -> setStrip { it.copy(eqMidDb = v) } }
            EditSlider("High", -18.0..18.0, strip.eqHighDb, db, "track-edit-eq-high", step = 0.5) { v -> setStrip { it.copy(eqHighDb = v) } }
            Text("Effects", style = MaterialTheme.typography.labelLarge)
            val pct = { v: Double -> "${(v * 100).toInt()}%" }
            EditSlider("Reverb", 0.0..1.0, strip.reverb, pct, "track-edit-reverb", step = 0.01) { v -> setStrip { it.copy(reverb = v) } }
            EditSlider("Delay", 0.0..1.0, strip.delay, pct, "track-edit-delay", step = 0.01) { v -> setStrip { it.copy(delay = v) } }
            EditSlider("Chorus", 0.0..1.0, strip.chorus, pct, "track-edit-chorus", step = 0.01) { v -> setStrip { it.copy(chorus = v) } }
            TextButton(onClick = { store.setTrackStrip(arrangementId, trackId, StudioChannelStrip()) }, modifier = Modifier.testTag("track-edit-strip-reset")) { Text("Reset channel strip") }
        }
    }
}

/** A rotary pan dial: the indicator sweeps +-135 degrees over pan -1..+1; drag or tap anywhere to set it. */
@Composable
fun PanDial(value: Double, modifier: Modifier = Modifier, onChange: (Double) -> Unit) {
    val ring = MaterialTheme.colorScheme.outline
    val hub = MaterialTheme.colorScheme.surfaceVariant
    val accent = MaterialTheme.colorScheme.tertiary
    val change by rememberUpdatedState(onChange)
    Canvas(
        modifier.size(96.dp)
            .semantics { contentDescription = "Pan ${ArrangerMath.panText(value)}" }
            .testTag("track-edit-pan-dial")
            .pointerInput(Unit) {
                detectTapGestures { o -> ArrangerMath.panForPoint(o.x - size.width / 2f, o.y - size.height / 2f)?.let(change) }
            }
            .pointerInput(Unit) {
                detectDragGestures { c, _ ->
                    ArrangerMath.panForPoint(c.position.x - size.width / 2f, c.position.y - size.height / 2f)?.let(change)
                    c.consume()
                }
            },
    ) {
        val d = min(size.width, size.height)
        val c = Offset(size.width / 2, size.height / 2)
        drawCircle(ring.copy(alpha = 0.5f), radius = d / 2, center = c, style = androidx.compose.ui.graphics.drawscope.Stroke(3.dp.toPx()))
        drawCircle(hub, radius = d * 0.41f, center = c)
        drawLine(ring, Offset(c.x, c.y - d * 0.5f), Offset(c.x, c.y - d * 0.38f), strokeWidth = 2.dp.toPx())
        val a = value * (135.0 * Math.PI / 180)
        val tip = Offset(c.x + (sin(a) * d * 0.40f).toFloat(), c.y - (cos(a) * d * 0.40f).toFloat())
        drawLine(accent, c, tip, strokeWidth = 4.dp.toPx(), cap = StrokeCap.Round)
        drawCircle(accent, radius = d * 0.08f, center = c)
    }
}

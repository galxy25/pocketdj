package com.levi.pocketdj.screens.producer.loops

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Stop
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.studio.engine.LoopException
import com.levi.pocketdj.studio.engine.LoopFailure
import com.levi.pocketdj.studio.engine.LoopMath
import com.levi.pocketdj.studio.model.LoopBeats
import com.levi.pocketdj.studio.model.StudioSample
import kotlinx.coroutines.launch

/** "0.5", "1" ... "32": the literal tag shape the emulator steps and iOS ids use (`loop-slice-0.5` / `-8`). */
internal fun beatsToken(b: LoopBeats): String = if (b == LoopBeats.HALF) "0.5" else b.beatCount.toInt().toString()

/**
 * The new-loop builder (iOS "New loop" section as a sheet): pick a SAMPLE (grid-less ones are disabled with the
 * set-BPM CTA), choose a beat window (1/2 ... 32), step an anchor beat-by-beat, see the exact computed window
 * (the SAME [LoopMath.window] the renderer uses), preview, save.
 *
 * PREVIEW renders a TEMP loop through the REAL renderer and auditions it looped: preview and Save can never drift,
 * and a looped preview exposes a bad seam (a one-shot would not). Every input change kills a stale preview.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoopSliceSheet(graph: AppGraph, onDismiss: () -> Unit) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val audition = studio.loopAudition
    val doc by store.state.collectAsState()
    val playingId by audition.playingId.collectAsState()
    val scope = rememberCoroutineScope()

    val samples = remember(doc) { doc.samples.sortedByDescending { it.createdAt } }
    var selectedId by remember { mutableStateOf<String?>(null) }
    var beats by remember { mutableStateOf(LoopBeats.FOUR) }
    var customAnchor by remember { mutableStateOf<Int?>(null) }
    var name by remember { mutableStateOf("") }
    var rendering by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf<String?>(null) }
    var pickerOpen by remember { mutableStateOf(false) }

    // Preselect the first sliceable sample so the builder isn't a dead "Choose a sample".
    LaunchedEffect(Unit) { if (selectedId == null) selectedId = store.samples(null).firstOrNull { it.grid != null }?.id ?: samples.firstOrNull { it.grid != null }?.id }
    val sample: StudioSample? = selectedId?.let { id -> doc.samples.firstOrNull { it.id == id } }
    val previewing = playingId == LoopMath.PREVIEW_ID

    fun stopPreview() { if (audition.playingId.value == LoopMath.PREVIEW_ID) audition.stop() }
    DisposableEffect(Unit) { onDispose { stopPreview() } }

    fun togglePreview(s: StudioSample) {
        if (previewing) { audition.stop(); return }
        if (rendering) return
        val anchor = LoopMath.effectiveAnchor(customAnchor, s.grid ?: return)
        val b = beats
        rendering = true; error = null; saved = null
        scope.launch {
            try {
                val (syn, file) = studio.loopFactory.renderPreview(s, anchor, b)
                if (!audition.play(syn.id, file, syn.frames)) error = "Couldn’t play the preview."
            } catch (e: LoopException) { error = e.failure.message } catch (e: Exception) { error = LoopFailure.Other.message }
            rendering = false
        }
    }

    fun save(s: StudioSample) {
        if (rendering) return
        val anchor = LoopMath.effectiveAnchor(customAnchor, s.grid ?: return)
        val b = beats; val typed = name
        rendering = true; error = null; saved = null
        scope.launch {
            try {
                val loop = studio.loopFactory.save(s, anchor, b, typed)
                name = ""      // inputs stay put: saving beat-window variants back-to-back is the flow
                saved = "Saved “${loop.name}” — ${loop.frames} frames"
            } catch (e: LoopException) { error = e.failure.message } catch (e: Exception) { error = LoopFailure.Other.message }
            rendering = false
        }
    }

    ModalBottomSheet(onDismissRequest = { stopPreview(); onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).testTag("loop-builder"),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("New loop", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                Button(onClick = { stopPreview(); onDismiss() }, modifier = Modifier.testTag("loop-builder-done")) { Text("Done") }
            }
            if (samples.isEmpty()) {
                Text(
                    "No samples yet — record or carve one on the Samples tab. Loops are beat-grid slices of samples.",
                    Modifier.testTag("loop-no-samples"), color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                // Sample picker
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Sample", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Box {
                        OutlinedButton(onClick = { pickerOpen = true }, modifier = Modifier.testTag("loop-sample-picker")) {
                            Text(sample?.name?.ifEmpty { "Sample" } ?: "Choose a sample", maxLines = 1)
                            Icon(Icons.Filled.ArrowDropDown, null)
                        }
                        DropdownMenu(pickerOpen, { pickerOpen = false }) {
                            samples.forEach { s ->
                                val label = s.name.ifEmpty { "Sample" }
                                DropdownMenuItem(
                                    text = { Text(if (s.grid == null) "$label — no BPM" else if (s.id == selectedId) "✓ $label" else label) },
                                    enabled = s.grid != null,
                                    onClick = {
                                        pickerOpen = false
                                        if (s.id != selectedId) { stopPreview(); selectedId = s.id; customAnchor = null; error = null; saved = null }
                                    },
                                    modifier = Modifier.testTag("loop-sample-${s.id}"),
                                )
                            }
                        }
                    }
                }
                if (samples.any { it.grid == null }) {
                    Text(LoopMath.GRIDLESS_CTA, Modifier.testTag("loop-gridless-cta"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.tertiary)
                }
                val grid = sample?.grid
                if (sample != null && grid != null) {
                    // Beat chips: 7 of them fit a phone-portrait row.
                    Text("Beats", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                        LoopBeats.entries.forEach { b ->
                            val on = beats == b
                            Surface(
                                onClick = { if (b != beats) { stopPreview(); beats = b; error = null; saved = null } },
                                modifier = Modifier.weight(1f).testTag("loop-slice-${beatsToken(b)}").semantics { contentDescription = "${b.label} ${LoopMath.beatsWord(b)}" },
                                shape = MaterialTheme.shapes.small,
                                color = if (on) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                                border = BorderStroke(1.dp, if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant),
                            ) {
                                Box(Modifier.padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
                                    Text(b.label, fontWeight = FontWeight.SemiBold, color = if (on) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                    // Anchor: +/- 1 beat and "From start"; always shows the SNAPPED beat position.
                    val snapped = LoopMath.snappedAnchor(customAnchor, grid)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Anchor", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        IconButton(
                            onClick = { stopPreview(); customAnchor = LoopMath.stepAnchor(customAnchor, -1, grid); error = null },
                            enabled = !rendering && LoopMath.canStepBack(customAnchor, grid), modifier = Modifier.testTag("loop-anchor-dec"),
                        ) { Icon(Icons.Filled.Remove, "Move the anchor one beat earlier") }
                        Text(
                            if (customAnchor == null) "start · $snapped ms" else "$snapped ms",
                            Modifier.testTag("loop-anchor-label"), style = MaterialTheme.typography.bodyLarge,
                        )
                        IconButton(
                            onClick = { stopPreview(); customAnchor = LoopMath.stepAnchor(customAnchor, +1, grid); error = null },
                            enabled = !rendering && LoopMath.canStepForward(customAnchor, grid, sample.durationMs), modifier = Modifier.testTag("loop-anchor-inc"),
                        ) { Icon(Icons.Filled.Add, "Move the anchor one beat later") }
                        TextButton(
                            onClick = { stopPreview(); customAnchor = null; error = null },
                            enabled = customAnchor != null && !rendering, modifier = Modifier.testTag("loop-anchor-reset"),
                        ) { Text("From start") }
                    }
                    // The exact window the renderer will slice.
                    val w = LoopMath.window(LoopMath.effectiveAnchor(customAnchor, grid), beats, grid)
                    if (w != null) {
                        Text("Window ${w.startMs}–${w.endMs} ms · ${w.lengthMs} ms · ${LoopMath.frames(w.lengthMs)} frames", Modifier.testTag("loop-window-label"), style = MaterialTheme.typography.bodySmall)
                        if (LoopMath.overhangs(w, sample.durationMs)) {
                            Text("Extends past the sample’s end — the overhang renders as silence.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary)
                        }
                    } else {
                        Text("No usable beat grid at this anchor.", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    }
                    OutlinedTextField(
                        name, { name = it }, label = { Text("Loop name (optional)") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("loop-name-field"),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        FilledTonalButton(onClick = { togglePreview(sample) }, enabled = !rendering && w != null, modifier = Modifier.testTag("loop-preview")) {
                            if (rendering) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            else Icon(if (previewing) Icons.Filled.Stop else Icons.Filled.PlayCircle, null)
                            Text(if (previewing) "Stop preview" else "Preview", Modifier.padding(start = 6.dp))
                        }
                        Button(onClick = { save(sample) }, enabled = !rendering && w != null, modifier = Modifier.testTag("loop-save")) {
                            Icon(Icons.Filled.Save, null); Text("Save loop", Modifier.padding(start = 6.dp))
                        }
                    }
                }
                error?.let { Text(it, Modifier.testTag("loop-error"), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                saved?.let { Text(it, Modifier.testTag("loop-saved"), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall) }
                Text(
                    "Loops render to a seamless audio file with the sample’s edits baked in — they keep playing even if the sample is later deleted.",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Box(Modifier.height(16.dp))
        }
    }
}

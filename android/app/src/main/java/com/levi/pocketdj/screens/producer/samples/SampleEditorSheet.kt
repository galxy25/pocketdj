package com.levi.pocketdj.screens.producer.samples

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.EditSlider
import com.levi.pocketdj.screens.producer.common.MixerDeck
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.screens.producer.common.WaveformMath
import com.levi.pocketdj.screens.producer.common.WaveformView
import com.levi.pocketdj.studio.demux.BeatDetect
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pure editor rules (JVM-tested). */
object SampleEditMath {
    /** Keep >= 50 ms of window - a zero-frame window is refused by the engine and renderer anyway. */
    const val MIN_WINDOW_MS = 50
    const val TAP_RESET_SECONDS = 2.5

    fun setTrimStart(e: StudioSampleEdit, v: Int, durationMs: Int): StudioSampleEdit {
        val end = if (e.trimEndMs == 0) durationMs else e.trimEndMs
        return e.copy(trimStartMs = minOf(v, maxOf(0, end - MIN_WINDOW_MS)))
    }

    /** At (or past) the file's end store the neutral 0 ("to the end" without freezing the file length into the edit). */
    fun setTrimEnd(e: StudioSampleEdit, ms: Int, durationMs: Int): StudioSampleEdit =
        e.copy(trimEndMs = if (ms >= durationMs) 0 else maxOf(ms, e.trimStartMs + MIN_WINDOW_MS))

    /** `trimEndMs == 0` shows as the file's end. */
    fun endDisplayMs(e: StudioSampleEdit, durationMs: Int) = if (e.trimEndMs == 0) durationMs else e.trimEndMs

    data class Tap(val taps: List<Double>, val bpm: Double?)

    /** >= 4 taps -> median inter-tap interval -> BPM (one flubbed tap must not skew it); a > 2.5 s gap starts a new run. */
    fun tap(taps: List<Double>, nowSec: Double): Tap {
        val run = if (taps.isNotEmpty() && nowSec - taps.last() > TAP_RESET_SECONDS) emptyList() else taps
        val next = run + nowSec
        if (next.size < 4) return Tap(next, null)
        val intervals = next.zipWithNext { a, b -> b - a }.sorted()
        val median = intervals[intervals.size / 2]
        if (median <= 0.2 || median >= 2.5) return Tap(next, null)   // 24-300 BPM sanity window
        return Tap(next, Math.round(60.0 / median * 10) / 10.0)
    }

    /** Manual BPM entry: comma-tolerant, 20..300 only. */
    fun parseBpm(text: String): Double? = text.trim().replace(',', '.').toDoubleOrNull()?.takeIf { it in 20.0..300.0 }

    /** A grid with measured per-beat timestamps is read-only (overwriting it would destroy data). */
    fun isMeasured(g: StudioGrid?) = g != null && g.beatsMs.isNotEmpty()
}

/** The sample editor: waveform trim, non-destructive mixer deck, beat grid. Save bakes nothing. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SampleEditorSheet(graph: AppGraph, sampleId: String, onDismiss: () -> Unit) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val engine = studio.studioEngine
    val doc by store.state.collectAsState()
    val sample: StudioSample? = doc.samples.firstOrNull { it.id == sampleId }
    val scope = rememberCoroutineScope()
    val playing by engine.isPlayingSample.collectAsState()
    val looping by engine.sampleLooping.collectAsState()

    var pcm by remember { mutableStateOf<PcmBuffer?>(null) }
    var loadError by remember { mutableStateOf(false) }
    var peaks by remember { mutableStateOf(FloatArray(0)) }
    var playhead by remember { mutableStateOf(0.0) }
    var renaming by remember { mutableStateOf(false) }
    var rendering by remember { mutableStateOf(false) }
    var detecting by remember { mutableStateOf(false) }
    var detectFailed by remember { mutableStateOf(false) }
    var taps by remember { mutableStateOf(emptyList<Double>()) }
    var bpmText by remember(sampleId) { mutableStateOf(sample?.grid?.bpm?.let { StudioFmt.trim(it) } ?: "") }

    // Load the RAW file once; the edit stays on the chain, never in the file.
    LaunchedEffect(sampleId) {
        val s = store.sample(sampleId) ?: return@LaunchedEffect
        val file = studio.sampleRenderCache.sourceFile(s)
        val buf = if (file == null) null else runCatching { studio.studioRender.decodeBuffer(file.path) }.getOrNull()
        if (buf == null) { loadError = true; return@LaunchedEffect }
        pcm = buf
        peaks = withContext(Dispatchers.Default) { WaveformMath.peaks(buf, 160) }
        engine.loadSample(s, buf)
    }
    DisposableEffect(sampleId) { onDispose { engine.unloadSample() } }

    // Playhead poll while open (sampled, deliberately not state-driven by the engine).
    LaunchedEffect(sampleId, playing) {
        while (true) { playhead = engine.samplePlayheadSeconds(); delay(if (playing) 40 else 250) }
    }

    // Implicit render: the cache catches up ~1.2 s after the last edit; nothing to "save".
    val revision = sample?.renderRevision
    LaunchedEffect(sampleId, revision) {
        if (revision == null) return@LaunchedEffect
        delay(1200)
        val s = store.sample(sampleId) ?: return@LaunchedEffect
        if (studio.sampleRenderCache.needsRender(s)) {
            rendering = true
            runCatching { studio.sampleRenderCache.playableFile(sampleId) }
            rendering = false
        }
    }

    fun apply(e: StudioSampleEdit) {
        val c = e.clamped()
        engine.applyEdit(c)
        store.updateSampleEdit(sampleId, c)
    }

    ModalBottomSheet(onDismissRequest = { store.flush(); onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        if (sample == null) {
            Text("This sample is gone.", Modifier.padding(24.dp)); return@ModalBottomSheet
        }
        val dur = maxOf(1, sample.durationMs)
        val edit = sample.edit
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).testTag("sample-editor"),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(sample.name, style = MaterialTheme.typography.titleLarge)
                    Text(StudioFmt.mmssTenths(sample.durationMs) + "  ·  " + sourceLabel(sample), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(onClick = { renaming = true }) { Text("Rename") }
                Button(onClick = { store.flush(); onDismiss() }, modifier = Modifier.testTag("sample-done")) { Text("Done") }
            }
            if (loadError) {
                Text("Couldn’t open this sample’s audio file.", color = MaterialTheme.colorScheme.error)
            } else {
                val total = (pcm?.frames ?: 0).toDouble() / 44100.0
                val frac = { sec: Double -> if (total <= 0) 0f else (sec / total).toFloat().coerceIn(0f, 1f) }
                WaveformView(
                    peaks = peaks,
                    regionStart = frac(edit.trimStartMs / 1000.0),
                    regionEnd = frac(SampleEditMath.endDisplayMs(edit, dur) / 1000.0),
                    playhead = frac(playhead),
                    onSeek = { f -> engine.seekSample(f * total) },
                    onRegionChange = { s, e ->
                        var n = SampleEditMath.setTrimStart(edit, Math.round(s * dur).toInt(), dur)
                        n = SampleEditMath.setTrimEnd(n, Math.round(e * dur).toInt(), dur)
                        apply(n)
                    },
                    description = "Sample waveform with trim handles",
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    FilledTonalButton(onClick = { if (playing) engine.pauseSample() else engine.playSample() }, modifier = Modifier.testTag("sample-play")) {
                        Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, contentDescription = if (playing) "Pause" else "Play")
                    }
                    OutlinedButton(onClick = { engine.stopSample() }, modifier = Modifier.testTag("sample-stop")) { Icon(Icons.Filled.Stop, contentDescription = "Stop") }
                    Spacer(Modifier.weight(1f))
                    Text(StudioFmt.mmssTenths((playhead * 1000).toInt()), style = MaterialTheme.typography.labelLarge)
                }
                engine.lastRefusal?.let {
                    if (it == "mic-capture-active") Text("Playback is paused while the microphone is recording.", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.labelMedium)
                }
            }
            SectionLabel("TRIM")
            EditSlider("Start", 0.0..dur.toDouble(), edit.trimStartMs.toDouble(), { StudioFmt.mmssTenths(it.toInt()) }, "sample-trim-start", step = 10.0) {
                apply(SampleEditMath.setTrimStart(edit, it.toInt(), dur))
            }
            EditSlider("End", 0.0..dur.toDouble(), SampleEditMath.endDisplayMs(edit, dur).toDouble(), { StudioFmt.mmssTenths(it.toInt()) }, "sample-trim-end", step = 10.0) {
                apply(SampleEditMath.setTrimEnd(edit, it.toInt(), dur))
            }
            HorizontalDivider()
            SectionLabel("MIXER DECK")
            MixerDeck(
                edit = edit, onEdit = ::apply, loopOn = looping,
                onLoop = { engine.setSampleLoopAudition(it) }, idPrefix = "sample-deck",
            )
            HorizontalDivider()
            SectionLabel("BEAT GRID")
            val grid = sample.grid
            if (SampleEditMath.isMeasured(grid)) {
                Text("${StudioFmt.trim(grid!!.bpm)} BPM · measured grid", style = MaterialTheme.typography.bodyMedium)
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    FilledTonalButton(
                        enabled = !detecting && pcm != null,
                        onClick = {
                            val buf = pcm ?: return@FilledTonalButton
                            detecting = true; detectFailed = false
                            scope.launch {
                                val g = withContext(Dispatchers.Default) { BeatDetect.detectGrid(buf) }
                                detecting = false
                                if (g != null) { store.setSampleGrid(sampleId, g); bpmText = StudioFmt.trim(g.bpm) } else detectFailed = true
                            }
                        },
                        modifier = Modifier.testTag("sample-detect-bpm"),
                    ) {
                        if (detecting) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Text(if (detecting) "Detecting tempo…" else "Auto-detect tempo", Modifier.padding(start = if (detecting) 8.dp else 0.dp))
                    }
                    OutlinedButton(
                        onClick = {
                            val r = SampleEditMath.tap(taps, System.nanoTime() / 1e9)
                            taps = r.taps
                            r.bpm?.let { b -> bpmText = StudioFmt.trim(b); store.setSampleGrid(sampleId, StudioGrid(b)) }
                        },
                        modifier = Modifier.testTag("sample-tap-tempo"),
                    ) { Text(if (taps.isEmpty() || taps.size >= 4) "Tap tempo" else "Tap (${taps.size})") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        bpmText, { bpmText = it }, label = { Text("BPM") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.width(120.dp).testTag("sample-bpm-field"),
                    )
                    TextButton(onClick = { SampleEditMath.parseBpm(bpmText)?.let { store.setSampleGrid(sampleId, StudioGrid(it)) } }, modifier = Modifier.testTag("sample-bpm-set")) { Text("Set") }
                }
                Text(
                    when {
                        detectFailed -> "Couldn’t detect a tempo — tap at least 4 beats or type a BPM."
                        grid != null -> "${StudioFmt.trim(grid.bpm)} BPM constant grid"
                        else -> "No grid yet — auto-detect, tap at least 4 beats, or type a BPM."
                    },
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            HorizontalDivider()
            Text(
                if (rendering) "Updating the rendered copy…" else "Edits are non-destructive and apply automatically — nothing to save.",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.size(16.dp))
        }
        if (renaming) NameDialog("Rename sample", sample.name, "Rename", { renaming = false }) { store.renameSample(sampleId, it); renaming = false }
    }
}

@Composable
private fun SectionLabel(t: String) =
    Text(t, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

internal fun sourceLabel(s: StudioSample): String = when (val src = s.source) {
    is com.levi.pocketdj.studio.model.StudioSource.Track -> "from track"
    com.levi.pocketdj.studio.model.StudioSource.Mic -> "recorded"
    is com.levi.pocketdj.studio.model.StudioSource.Take -> "from take"
    is com.levi.pocketdj.studio.model.StudioSource.File -> "from ${src.originalName}"
    is com.levi.pocketdj.studio.model.StudioSource.LineIn -> "line in" + (src.inputName?.let { " ($it)" } ?: "")
}

package com.levi.pocketdj.screens.producer.samples

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.EditSlider
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.screens.producer.common.WaveformMath
import com.levi.pocketdj.screens.producer.common.WaveformView
import com.levi.pocketdj.studio.audio.LocalAudioCache
import com.levi.pocketdj.studio.audio.LocalSource
import com.levi.pocketdj.studio.audio.SourcePhase
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.demux.BeatMath
import com.levi.pocketdj.studio.engine.SampleFileException
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSample
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pure rules for the carve sheet (JVM-tested). */
object NewSampleLogic {
    const val MIN_WINDOW_MS = 50
    const val NUDGE_MS = 10

    /** Substring token search over title + artist; burned tracks sort first; an empty query browses only the burned subset. */
    fun search(songs: List<IndexSong>, query: String, isBurned: (String) -> Boolean, limit: Int = 60): List<IndexSong> {
        val toks = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (toks.isEmpty()) return songs.filter { isBurned(it.id) }.take(limit)
        val hits = songs.filter { s ->
            val hay = (s.name + " " + s.artist).lowercase()
            toks.all { hay.contains(it) }
        }
        val (burned, rest) = hits.partition { isBurned(it.id) }
        return (burned + rest).take(limit)
    }

    /** Song length: catalog first (stable), then the manifest duration; at least 1. */
    fun songLengthMs(catalogLength: Long?, manifestDuration: Long?): Int =
        ((catalogLength?.takeIf { it > 0 } ?: manifestDuration?.takeIf { it > 0 } ?: 1L)).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

    fun markIn(playheadMs: Int, endMs: Int) = maxOf(0, minOf(playheadMs, endMs - MIN_WINDOW_MS))
    fun markOut(playheadMs: Int, startMs: Int, lenMs: Int) = minOf(lenMs, maxOf(playheadMs, startMs + MIN_WINDOW_MS))

    /** Nudge one edge by [deltaMs]; the window never drops below [MIN_WINDOW_MS] nor leaves [0, lenMs]. */
    fun nudge(isStart: Boolean, deltaMs: Int, startMs: Int, endMs: Int, lenMs: Int): Pair<Int, Int> =
        if (isStart) maxOf(0, minOf(startMs + deltaMs, endMs - MIN_WINDOW_MS)) to endMs
        else startMs to minOf(lenMs, maxOf(endMs + deltaMs, startMs + MIN_WINDOW_MS))

    /** One beat in ms at [bpm]; null when no usable tempo (the beat nudge row hides). */
    fun beatMs(bpm: Double?): Int? = bpm?.takeIf { it > 0 }?.let { Math.round(60_000.0 / it).toInt() }

    /** Default region: the first ~8 s (or the whole song when shorter). */
    fun defaultRegion(lenMs: Int): Pair<Int, Int> = 0 to minOf(lenMs, 8_000).let { if (it < MIN_WINDOW_MS) lenMs else it }

    fun canCarve(startMs: Int, endMs: Int) = endMs - startMs >= MIN_WINDOW_MS
}

/** Pick an indexed track, audition it, mark in/out, carve a sample (the burn rung runs on demand). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewSampleFromTrackSheet(graph: AppGraph, onDismiss: () -> Unit, onFiled: (String) -> Unit) {
    val studio = graph.studioGraph
    val cache = studio.localAudioCache
    val engine = studio.studioEngine
    val burns = graph.servicesGraph.burnStore
    val catalog by graph.catalogRepository.state.collectAsState()
    val scope = rememberCoroutineScope()

    var query by remember { mutableStateOf("") }
    var song by remember { mutableStateOf<IndexSong?>(null) }
    var phase by remember { mutableStateOf<SourcePhase?>(null) }
    var startMs by remember { mutableStateOf(0) }
    var endMs by remember { mutableStateOf(0) }
    var lenMs by remember { mutableStateOf(1) }
    var peaks by remember { mutableStateOf(FloatArray(0)) }
    var window by remember { mutableStateOf<PcmBuffer?>(null) }
    var gridBpm by remember { mutableStateOf<Double?>(null) }
    var carving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var playhead by remember { mutableStateOf(0.0) }
    val playing by engine.isPlayingSample.collectAsState()

    DisposableEffect(Unit) { onDispose { engine.unloadSample() } }
    LaunchedEffect(Unit) { while (true) { playhead = engine.samplePlayheadSeconds(); delay(if (playing) 40 else 250) } }

    val results = remember(query, catalog.catalog, phase) {
        NewSampleLogic.search(catalog.catalog?.songs.orEmpty(), query, { burns.hasLocalFile(it) })
    }

    /** Selection generation: bumped by pick()/Back so a stale decode/burn can never land on a newer selection. */
    var selection by remember { mutableStateOf(0) }

    /** Resolve the burned file, load its song window into the audition chain, compute the inherited grid. */
    suspend fun enterReady(s: IndexSong, src: LocalSource, token: Int) {
        val entry = graph.ripsRepository.entry(s.id)
        val len = NewSampleLogic.songLengthMs(s.length, entry?.durationMs)
        val off = if (src.isCut) 0 else src.offsetMs
        // Ranged decode: only the song window, never the whole album side.
        val win = runCatching { studio.studioRender.decodeRangeBuffer(src.file.path, off, len) }.getOrNull()
        if (token != selection) return
        if (win == null) { error = "Couldn’t open this track’s audio."; phase = SourcePhase.NeedsBurn; return }
        lenMs = len
        window = win
        val pk = withContext(Dispatchers.Default) { WaveformMath.peaks(win, 160) }
        if (token != selection) return
        peaks = pk
        val (a, b) = NewSampleLogic.defaultRegion(len)
        startMs = a; endMs = b
        val sc = burns.localBeatGrid(s.id) ?: runCatching { burns.burnBeatGrid(s.id) }.getOrNull()
        if (token != selection) return
        gridBpm = sc?.beatGridBpm ?: burns.beatGrid(s.id)?.bpm ?: s.bpm
        engine.loadSample(StudioSample("preview_${s.id}", s.name, "", durationMs = len), win)
        phase = SourcePhase.Ready(src)
    }

    fun pick(s: IndexSong) {
        selection++
        val token = selection
        song = s; error = null; window = null; peaks = FloatArray(0)
        val p = cache.phaseFor(s.id)
        phase = p
        if (p is SourcePhase.Ready) scope.launch { enterReady(s, p.source, token) }
    }

    fun burn() {
        val s = song ?: return
        val token = selection
        phase = SourcePhase.Burning
        scope.launch {
            val r = cache.prepare(s.id, s.name, s.artist)
            if (token != selection) return@launch
            if (r is SourcePhase.Ready) enterReady(s, r.source, token) else phase = r
        }
    }

    fun carve() {
        val s = song ?: return
        val src = (phase as? SourcePhase.Ready)?.source ?: run { error = "This track isn’t on the device anymore. Burn it again, then carve."; return }
        carving = true; error = null
        scope.launch {
            val sidecar = burns.localBeatGrid(s.id)
            val bg = BeatMath.inheritedGrid(
                beatsMs = sidecar?.beatsMs.orEmpty(), downbeatsMs = sidecar?.downbeatsMs.orEmpty(), sidecarBpm = sidecar?.beatGridBpm,
                regionStartMs = startMs, regionEndMs = endMs, fallbackBpm = gridBpm,
                scalarBpm = burns.beatGrid(s.id)?.bpm ?: s.bpm,
            )
            val grid = bg?.let { StudioGrid(it.bpm, it.firstDownbeatMs, it.beatsMs) }
            try {
                val made = studio.sampleFactory.carveTrack(s.id, s.name, src, startMs, endMs, grid)
                engine.unloadSample()
                onFiled(made.id)
                onDismiss()
            } catch (e: SampleFileException) {
                error = e.failure.message
            } finally { carving = false }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f).navigationBarsPadding().padding(horizontal = 16.dp).testTag("from-track-sheet")) {
            val s = song
            if (s == null) {
                Text("New sample from track", style = MaterialTheme.typography.titleLarge)
                OutlinedTextField(query, { query = it }, label = { Text("Search songs") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("song-search"))
                if (query.isBlank() && results.isEmpty()) {
                    Text("Burn a track first (or search the whole catalog) to carve a sample from it.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                LazyColumn(Modifier.weight(1f)) {
                    items(results, key = { it.id }) { r ->
                        Column(Modifier.fillMaxWidth().clickable { pick(r) }.padding(vertical = 8.dp).testTag("song-${r.id}")) {
                            Text(r.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
                            Text(r.artist + if (burns.hasLocalFile(r.id)) "  ·  on device" else "", maxLines = 1, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { selection++; engine.unloadSample(); song = null; phase = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                    Column(Modifier.weight(1f)) {
                        Text(s.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(s.artist, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                when (val p = phase) {
                    is SourcePhase.Ready -> ReadyBody(
                        peaks = peaks, lenMs = lenMs, startMs = startMs, endMs = endMs, playheadMs = (playhead * 1000).toInt(),
                        playing = playing, gridBpm = gridBpm, carving = carving, error = error,
                        onRegion = { a, b -> startMs = a; endMs = b },
                        onSeek = { f -> engine.seekSample(f * lenMs / 1000.0) },
                        onPlay = { if (playing) engine.pauseSample() else engine.playSample() },
                        onCarve = ::carve,
                    )
                    SourcePhase.NeedsBurn -> {
                        Text("This track isn’t on the device yet. Burn it to carve a sample offline.", Modifier.padding(vertical = 12.dp))
                        Button(onClick = ::burn, modifier = Modifier.testTag("sample-burn")) { Text("Burn for carving") }
                        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                    SourcePhase.Burning -> Row(Modifier.padding(vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text("Burning this track for offline carving…", Modifier.padding(start = 12.dp).testTag("sample-burning"))
                    }
                    is SourcePhase.Failed -> Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(p.message, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("sample-burn-failed"))
                        OutlinedButton(onClick = ::burn, modifier = Modifier.testTag("sample-burn-retry")) { Text("Retry") }
                    }
                    SourcePhase.RipFirst -> Text(
                        "Nothing is prepared for this track yet. Rip it first (from the track’s menu), then come back to carve a sample.",
                        Modifier.padding(vertical = 12.dp).testTag("sample-rip-first"),
                    )
                    null -> {}
                }
            }
        }
    }
}

@Composable
private fun ReadyBody(
    peaks: FloatArray, lenMs: Int, startMs: Int, endMs: Int, playheadMs: Int, playing: Boolean, gridBpm: Double?,
    carving: Boolean, error: String?, onRegion: (Int, Int) -> Unit, onSeek: (Float) -> Unit, onPlay: () -> Unit, onCarve: () -> Unit,
) {
    val beat = NewSampleLogic.beatMs(gridBpm)
    val f = { ms: Int -> (ms.toFloat() / lenMs).coerceIn(0f, 1f) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
        WaveformView(
            peaks, regionStart = f(startMs), regionEnd = f(endMs), playhead = f(playheadMs), onSeek = onSeek,
            onRegionChange = { a, b -> onRegion(Math.round(a * lenMs), Math.round(b * lenMs)) }, description = "Track waveform with in and out marks",
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            FilledTonalButton(onClick = onPlay, modifier = Modifier.testTag("region-play")) {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "Pause" else "Play")
            }
            OutlinedButton(onClick = { onRegion(NewSampleLogic.markIn(playheadMs, endMs), endMs) }, modifier = Modifier.testTag("mark-in")) { Text("Mark in") }
            OutlinedButton(onClick = { onRegion(startMs, NewSampleLogic.markOut(playheadMs, startMs, lenMs)) }, modifier = Modifier.testTag("mark-out")) { Text("Mark out") }
        }
        EdgeRow("In", startMs, true, beat) { d -> NewSampleLogic.nudge(true, d, startMs, endMs, lenMs).let { onRegion(it.first, it.second) } }
        EdgeRow("Out", endMs, false, beat) { d -> NewSampleLogic.nudge(false, d, startMs, endMs, lenMs).let { onRegion(it.first, it.second) } }
        Text(
            "Region ${StudioFmt.mmssTenths(endMs - startMs)}" + (gridBpm?.let { " · grid ${StudioFmt.trim(it)} BPM (inherited)" } ?: " · no grid — set one in the editor"),
            style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("carve-error")) }
        Button(onClick = onCarve, enabled = !carving && NewSampleLogic.canCarve(startMs, endMs), modifier = Modifier.fillMaxWidth().testTag("carve")) {
            if (carving) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Text(if (carving) "Carving…" else "Make sample", Modifier.padding(start = if (carving) 8.dp else 0.dp))
        }
    }
}

@Composable
private fun EdgeRow(label: String, ms: Int, isStart: Boolean, beatMs: Int?, nudge: (Int) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("$label ${StudioFmt.mmssTenths(ms)}", Modifier.padding(end = 4.dp), style = MaterialTheme.typography.labelLarge)
        val tag = if (isStart) "sample-region-start" else "sample-region-end"
        TextButton(onClick = { nudge(-NewSampleLogic.NUDGE_MS) }, modifier = Modifier.testTag("$tag-minus10")) { Text("−10 ms") }
        TextButton(onClick = { nudge(NewSampleLogic.NUDGE_MS) }, modifier = Modifier.testTag("$tag-plus10")) { Text("+10 ms") }
        if (beatMs != null) {
            TextButton(onClick = { nudge(-beatMs) }, modifier = Modifier.testTag("$tag-beat-minus")) { Text("−1 beat") }
            TextButton(onClick = { nudge(beatMs) }, modifier = Modifier.testTag("$tag-beat-plus")) { Text("+1 beat") }
        }
    }
}

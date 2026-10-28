package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.demux.ArrangementTarget
import com.levi.pocketdj.studio.demux.DemuxArtifactStatus
import com.levi.pocketdj.studio.demux.DemuxFeatures
import com.levi.pocketdj.studio.demux.DemuxGridResolver
import com.levi.pocketdj.studio.demux.DemuxInstrumental
import com.levi.pocketdj.studio.demux.DemuxInstrumentalContent
import com.levi.pocketdj.studio.demux.DemuxSession
import com.levi.pocketdj.studio.demux.DemuxSource
import com.levi.pocketdj.studio.demux.DemuxStemState
import com.levi.pocketdj.studio.demux.DemuxSwitchException
import com.levi.pocketdj.studio.demux.DemuxTakeSwitch
import com.levi.pocketdj.studio.demux.DrumPatternDetector
import com.levi.pocketdj.studio.demux.DrumPatternExport
import com.levi.pocketdj.studio.demux.LyricsPanelState
import com.levi.pocketdj.studio.demux.DemuxCutMath
import com.levi.pocketdj.studio.demux.melodyStem
import com.levi.pocketdj.studio.model.StudioTake
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request

/** The stem files on the device for a source key: a catalog song's burned set, else the demux cache's custom set. */
internal fun demuxStemsFor(graph: AppGraph, key: String): Map<String, File>? =
    if (com.levi.pocketdj.studio.demux.DemuxSource.isSongKey(key)) graph.servicesGraph.burnStore.localStemFiles(key)
    else graph.studioGraph.demuxStore.localStemFiles(key)

/** Re-extract the OTHER mode (comping <-> melody) of a demux-made take in place. Returns an error message or null on success. */
suspend fun switchDemuxTakeMode(graph: AppGraph, take: StudioTake): String? {
    val sg = graph.studioGraph
    val store = sg.studioStore
    val burns = graph.servicesGraph.burnStore
    return try {
        val (mode, events) = DemuxTakeSwitch.switchEvents(
            sourceKey = take.demuxSourceKey, currentMode = take.demuxMode,
            document = { sg.demuxStore.document(it) },
            grid = { key -> DemuxTakeSwitch.resolveGrid(key) { id -> burns.localBeatGrid(id) ?: burns.burnBeatGrid(id) } },
            trackMelody = { key -> withContext(Dispatchers.IO) { sg.demuxAnalyzers.trackMelodyNow(key, melodyStem(demuxStemsFor(graph, key))) } },
            cacheMelody = { key, notes -> sg.demuxAnalyzers.cacheMelody(key, notes) },
        )
        store.setTakeEvents(take.id, events)
        store.setTakeDemuxMode(take.id, mode)
        // Best effort: re-render so the new line is audible everywhere; a missing pack surfaces at replay.
        store.take(take.id)?.let { t -> runCatching { sg.takeRenderer.render(t) { sg.instrumentPacks.localBankFile(it) } } }
        null
    } catch (e: DemuxSwitchException) {
        e.error.message
    } catch (e: CancellationException) {
        throw e
    } catch (_: Throwable) {
        "Couldn’t switch this instrumental."
    }
}

/**
 * Everything the Demuxer derives beyond chords, rendered under the timeline: drum pattern, chord-comping instrumental,
 * melody, cut sample, stems -> arrangement, cloud lyrics. Each section is keyed by the source so nothing computed for a
 * previous source is ever shown or exported for the current one.
 */
@Composable
fun DemuxPanels(graph: AppGraph, session: DemuxSession, source: DemuxSource, follow: Boolean, onFollowChange: (Boolean) -> Unit) {
    val sg = graph.studioGraph
    val store = sg.demuxStore
    val analyzers = sg.demuxAnalyzers
    val exporter = sg.demuxExporter
    val scope = rememberCoroutineScope()
    val revision by store.revision.collectAsState()
    val doc = remember(revision, source.key) { store.document(source.key) }
    val audio by session.audioFile.collectAsState()
    val duration by session.durationMs.collectAsState()
    val peaks by session.peaks.collectAsState()
    val stemState by session.stemState.collectAsState()
    val stemMode by session.stemMode.collectAsState()
    val drumRuns by analyzers.drumRuns.collectAsState()
    val melodyRuns by analyzers.melodyRuns.collectAsState()
    val lyricsFetching by analyzers.lyricsFetching.collectAsState()
    val player = session.player
    val burns = graph.servicesGraph.burnStore

    // The stem set on the device (re-read when stem state changes).
    val stems by produceState<Map<String, File>?>(null, source.key, stemState) { value = withContext(Dispatchers.IO) { demuxStemsFor(graph, source.key) } }

    // Bars + instrumental grid, keyed by source (a stale result for another source is dropped by forSource).
    val gridResult by produceState<com.levi.pocketdj.studio.demux.DemuxGridResult?>(null, source.key, audio, duration) {
        val file = audio
        value = if (file == null || duration <= 0) null else withContext(Dispatchers.IO) {
            val sidecar = source.songId?.let { burns.localBeatGrid(it) ?: runCatching { burns.burnBeatGrid(it) }.getOrNull() }
            DemuxGridResolver.resolve(source.key, duration, sidecar) { DrumPatternDetector.gridEstimate(file.path) }
        }
    }
    val grid = gridResult?.forSource(source.key)

    var cutOpen by remember(source.key) { mutableStateOf(false) }
    var sendOpen by remember(source.key) { mutableStateOf(false) }
    var sendNotice by remember(source.key) { mutableStateOf<String?>(null) }

    // ---- cloud lyrics (songs with a manifest sidecar), fetched-once ----
    val songId = source.songId
    val lyricsUrl = songId?.let { graph.ripsRepository.entry(it)?.lyricsUrl() }
    suspend fun fetchLyrics(force: Boolean) {
        val url = lyricsUrl ?: return
        analyzers.fetchCloudLyrics(source, force) {
            withContext(Dispatchers.IO) {
                runCatching { graph.httpClient.newCall(Request.Builder().url(url).build()).execute().use { r -> if (r.isSuccessful) r.body?.string() else null } }.getOrNull()
            }
        }
    }
    LaunchedEffect(source.key, lyricsUrl) { if (lyricsUrl != null) fetchLyrics(false) }
    val lyricsState = LyricsPanelState.of(
        visible = DemuxFeatures.lyricsPanelVisible(lyricsUrl != null, doc), fetching = source.key in lyricsFetching, doc = doc, hasCloudSidecar = lyricsUrl != null,
    )

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        // ---- drum pattern ----
        Section("Drum pattern", "demux-drum") {
            val hits = doc?.drumHits.orEmpty()
            when {
                source.key in drumRuns -> Busy("Listening for drum hits…", "demux-drum-running")
                doc?.drumStatus == DemuxArtifactStatus.DONE && hits.isNotEmpty() -> DrumPatternPanel(
                    source = source, hits = hits, bars = grid?.bars.orEmpty(), durationMs = duration, player = player,
                    follow = follow, onFollowChange = onFollowChange, onSeek = { session.seekMs(it) },
                    export = { plan, whole, bar ->
                        val s = withContext(Dispatchers.IO) { demuxStemsFor(graph, source.key) }
                        exporter.sendDrumPattern(source, hits, duration, plan, whole, bar, s?.get("drums")?.path, s?.get("bass")?.path)
                    },
                )
                else -> {
                    val drums = stems?.get("drums")
                    if (doc?.drumStatus == DemuxArtifactStatus.FAILED) Muted("No clear drum hits were found.", "demux-drum-failed")
                    if (drums == null) Muted("Needs the stems on this device — download or create them below.", "demux-drum-needs-stems")
                    else OutlinedButton(onClick = { analyzers.analyzeDrums(source, drums.path, stems?.get("bass")?.path, duration, force = true) }, modifier = Modifier.testTag("demux-drum-extract")) {
                        Text(if (doc?.drumStatus == DemuxArtifactStatus.FAILED) "Retry" else "Extract drum pattern")
                    }
                }
            }
        }

        // ---- chord-comping instrumental ----
        val chords = doc?.chords.orEmpty()
        if (chords.isNotEmpty()) Section("Instrumental", "demux-instrumental") {
            InstrumentalPanel(
                source = source, content = DemuxInstrumentalContent.Comping(chords), grid = grid?.grid ?: DemuxInstrumental.Grid(120.0, 0), durationMs = duration,
                player = player, follow = follow, onFollowChange = onFollowChange, onSeek = { session.seekMs(it) },
                onExtract = { exporter.saveInstrumental(source, DemuxInstrumentalContent.Comping(chords), grid?.grid ?: DemuxInstrumental.Grid(120.0, 0)) },
            )
        }

        // ---- melody ----
        Section("Melody", "demux-melody") {
            val notes = doc?.melodyNotes.orEmpty()
            val stem = melodyStem(stems)
            when {
                source.key in melodyRuns -> Busy("Tracking the melody…", "demux-melody-running")
                doc?.melodyStatus == DemuxArtifactStatus.DONE && notes.isNotEmpty() -> InstrumentalPanel(
                    source = source, content = DemuxInstrumentalContent.Melody(notes), grid = grid?.grid ?: DemuxInstrumental.Grid(120.0, 0), durationMs = duration,
                    player = player, follow = follow, onFollowChange = onFollowChange, onSeek = { session.seekMs(it) },
                    onExtract = { exporter.saveInstrumental(source, DemuxInstrumentalContent.Melody(notes), grid?.grid ?: DemuxInstrumental.Grid(120.0, 0)) },
                )
                else -> {
                    if (doc?.melodyStatus == DemuxArtifactStatus.FAILED) Muted("No clear melody was found.", "demux-melody-failed")
                    if (stem == null) Muted("Needs the stems on this device — download or create them below.", "demux-melody-needs-stems")
                    else OutlinedButton(onClick = { analyzers.analyzeMelody(source, stem.path, force = true) }, modifier = Modifier.testTag("demux-melody-track")) {
                        Text(if (doc?.melodyStatus == DemuxArtifactStatus.FAILED) "Retry" else "Track melody")
                    }
                }
            }
        }

        // ---- cut sample + send stems ----
        Section("Samples", "demux-samples") {
            OutlinedButton(onClick = { session.player.let { if (it.isPlaying) it.togglePlayPause() }; cutOpen = true }, enabled = audio != null, modifier = Modifier.testTag("demux-cut-row")) { Text("Cut sample…") }
            if (stems != null) OutlinedButton(onClick = { sendOpen = true }, modifier = Modifier.testTag("demux-send-stems")) { Text("Send stems to arrangement…") }
            sendNotice?.let { Muted(it, "demux-send-notice") }
        }

        // ---- lyrics (cloud sidecar) ----
        LyricsPanel(lyricsState, player, onSeek = { session.seekMs(it) }, onRetry = { scope.launch { fetchLyrics(true) } })
    }

    if (cutOpen) CutSampleSheet(
        source = source, durationMs = duration, peaks = peaks, player = player,
        hasStems = stems != null && stemState == DemuxStemState.Burned, stemModeOn = stemMode, onStemMode = { session.setStemMode(it) },
        carve = { enabled, name, s, e ->
            val file = audio
            if (file == null) com.levi.pocketdj.studio.demux.ExportOutcome(false, "The audio isn’t available.")
            else exporter.cutSample(source, file.path, enabled?.let { en -> stems?.let { DemuxCutMath.stemPaths(it, en) } }, name, s, e)
        },
        onDismiss = { cutOpen = false },
    )
    if (sendOpen) SendStemsDialog(graph, source.displayName, onDismiss = { sendOpen = false }) { target ->
        sendOpen = false
        scope.launch { sendNotice = stems?.let { exporter.sendStemsToArrangement(target, source.displayName, it).notice } }
    }
}

@Composable
private fun Section(title: String, tag: String, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().testTag(tag), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall)
        content()
    }
}

@Composable
private fun Muted(text: String, tag: String? = null) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = if (tag != null) Modifier.testTag(tag) else Modifier)
}

@Composable
private fun Busy(text: String, tag: String) {
    Row(Modifier.testTag(tag), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Pick a new or existing arrangement for the four stems. */
@Composable
private fun SendStemsDialog(graph: AppGraph, label: String, onDismiss: () -> Unit, onPick: (ArrangementTarget) -> Unit) {
    val doc by graph.studioGraph.studioStore.state.collectAsState()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Send stems to arrangement") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { onPick(ArrangementTarget.New(label)) }, modifier = Modifier.testTag("demux-send-new")) { Text("New arrangement “$label”") }
                for (a in doc.arrangements) TextButton(onClick = { onPick(ArrangementTarget.Existing(a.id)) }, modifier = Modifier.testTag("demux-send-${a.id}")) { Text(a.name.ifBlank { "Untitled" }) }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

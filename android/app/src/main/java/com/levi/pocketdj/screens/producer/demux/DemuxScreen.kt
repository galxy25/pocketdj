package com.levi.pocketdj.screens.producer.demux

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.studio.demux.DemuxArtifactStatus
import com.levi.pocketdj.studio.demux.DemuxChordSegment
import com.levi.pocketdj.studio.demux.DemuxPhase
import com.levi.pocketdj.studio.demux.DemuxSession
import com.levi.pocketdj.studio.demux.DemuxSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val PREFS = "pocketdj-demux"
private const val KEY_EXPANDED = "pdj.demuxExpandedGroups"

/**
 * Producer > Demuxer: pick ANY audio (a catalog track, a Studio sample/loop/take, or an imported file) and
 * see its chord timeline + stems. The screen is a renderer of [DemuxSession] (selection, resolve ladder,
 * stems) and [com.levi.pocketdj.studio.demux.DemuxStore] (documents); leaving the tab stops the audio.
 */
@Composable
fun DemuxScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    val studioGraph = graph.studioGraph
    val session = studioGraph.demuxSession
    val store = studioGraph.demuxStore
    val ctx = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val source by session.source.collectAsState()
    val doc by studioGraph.studioStore.state.collectAsState()
    val catalog by graph.catalogRepository.state.collectAsState()
    // The catalog is otherwise only loaded when Browse is first shown; the track picker needs it too.
    androidx.compose.runtime.LaunchedEffect(Unit) { graph.catalogRepository.loadIfNeeded() }
    val revision by store.revision.collectAsState()
    var expanded by remember { mutableStateOf(runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_EXPANDED, "") }.getOrNull().orEmpty()) }
    var importError by remember { mutableStateOf<String?>(null) }

    // One audio owner: leaving the tab parks the player and cancels an in-flight resolve. An Activity
    // recreation (rotation, dark mode) also disposes the composition but must NOT tear the session down.
    val activity = remember(ctx) { generateSequence(ctx) { (it as? android.content.ContextWrapper)?.baseContext }.filterIsInstance<android.app.Activity>().firstOrNull() }
    DisposableEffect(session) { onDispose { if (DemuxScreenRules.shouldClearOnDispose(activity?.isChangingConfigurations == true)) session.clearSource() } }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val src = withContext(Dispatchers.IO) {
                runCatching {
                    val name = displayName(ctx, uri)
                    ctx.contentResolver.openInputStream(uri)?.use { store.importStream(name, it) }
                }.getOrNull()
            }
            if (src != null) session.select(src) else importError = "Couldn’t import that file."
        }
    }

    Column(modifier.fillMaxSize().testTag("demux-screen")) {
        if (source == null) {
            importError?.let { Text(it, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
            val burnItems by graph.servicesGraph.burnStore.items.collectAsState()
            // Disk walks (document JSON decode, file-exists heals) stay off the main thread.
            val burned by produceState(emptySet<String>(), catalog, burnItems) {
                value = withContext(Dispatchers.IO) {
                    val ids = catalog.catalog?.songsById?.keys.orEmpty()
                    ids.filter { graph.servicesGraph.burnStore.localUrlPreferringCut(it) != null }.toSet()
                }
            }
            val importedFiles by produceState(emptyList<Pair<String, String>>(), revision) {
                value = withContext(Dispatchers.IO) { store.importedSources() }
            }
            val studio = remember(doc) {
                val s = studioGraph.studioStore
                s.samples.map { DemuxPickerRules.StudioRow(it.id, it.name, "sample") } +
                    s.loops.map { DemuxPickerRules.StudioRow(it.id, it.name, "loop") } +
                    s.takes.map { DemuxPickerRules.StudioRow(it.id, it.name, "take") }
            }
            DemuxSourcePicker(
                data = DemuxPickerData(
                    files = importedFiles, studio = studio,
                    songs = catalog.catalog?.songsById?.values.orEmpty(), burned = burned,
                ),
                expandedRaw = expanded,
                onExpandedChange = {
                    expanded = it
                    runCatching { ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_EXPANDED, it).apply() }
                },
                onImport = { picker.launch(arrayOf("audio/*")) },
                onPick = { session.select(it) },
            )
        } else {
            LoadedView(graph, session, store, source!!)
        }
    }
}

private fun displayName(ctx: Context, uri: Uri): String =
    ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) c.getString(0) else null
    } ?: uri.lastPathSegment ?: "Imported audio"

@Composable
private fun LoadedView(graph: AppGraph, session: DemuxSession, store: com.levi.pocketdj.studio.demux.DemuxStore, source: DemuxSource) {
    val phase by session.phase.collectAsState()
    val stemState by session.stemState.collectAsState()
    val revision by store.revision.collectAsState()
    var chordDetail by remember { mutableStateOf<DemuxChordSegment?>(null) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(source.displayName, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.testTag("demux-title"))
                Text(
                    "Demuxed: chord timeline" + if (stemState == com.levi.pocketdj.studio.demux.DemuxStemState.Burned) " + stems" else "",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            TextButton(onClick = { session.clearSource() }, modifier = Modifier.testTag("demux-change")) { Text("Change") }
        }
        when (val p = phase) {
            DemuxPhase.Resolving, DemuxPhase.Idle -> Status(true, "Preparing audio…", "demux-resolving")
            DemuxPhase.Burning -> Status(true, "Burning for offline demuxing…", "demux-burning")
            DemuxPhase.NeedsBurn -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("This track’s audio is prepared but not on the device yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { session.burnThenReady() }, modifier = Modifier.testTag("demux-burn")) { Text("Burn + demux") }
            }
            DemuxPhase.RipFirst -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Nothing to demux here", style = MaterialTheme.typography.titleSmall)
                Text(
                    "There’s no prepared audio for this track yet, so there’s nothing to demux. Pick a track that’s already on the device, or Import an audio file.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("demux-rip-first"),
                )
            }
            is DemuxPhase.Failed -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.message, Modifier.weight(1f).testTag("demux-failed"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { session.select(source) }, modifier = Modifier.testTag("demux-retry")) { Text("Retry") }
            }
            DemuxPhase.Ready -> ReadyBody(graph, session, store, source, revision) { chordDetail = it }
        }
    }
    chordDetail?.let { ChordDetailSheet(it) { chordDetail = null } }
}

@Composable
private fun ReadyBody(graph: AppGraph, session: DemuxSession, store: com.levi.pocketdj.studio.demux.DemuxStore, source: DemuxSource, revision: Long, onChord: (DemuxChordSegment) -> Unit) {
    val duration by session.durationMs.collectAsState()
    val peaks by session.peaks.collectAsState()
    val player = session.player
    val version by player.version.collectAsState()
    val runs by store.chordRuns.collectAsState()
    var follow by remember { mutableStateOf(true) }
    var clockMs by remember { mutableIntStateOf(0) }
    LaunchedEffect(player) { while (true) { clockMs = (player.currentTimeSec * 1000).toInt(); delay(250) } }
    val doc = remember(revision, source.key) { store.document(source.key) }

    // Transport.
    @Suppress("UNUSED_EXPRESSION") version
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        FilledIconButton(onClick = { player.togglePlayPause() }, modifier = Modifier.size(44.dp).testTag("demux-play")) {
            Icon(if (player.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (player.isPlaying) "Pause" else "Play")
        }
        Text("${clock(clockMs)} / ${clock(duration)}", fontFamily = FontFamily.Monospace, modifier = Modifier.testTag("demux-clock"))
    }
    DemuxTimeline(
        durationMs = duration, peaks = peaks, chords = doc?.chords.orEmpty(), player = player,
        follow = follow, onFollowChange = { follow = it }, onSeek = { session.seekMs(it) }, onChordTap = onChord,
    )
    // Chord status row.
    val chordRunning = source.key in runs
    when {
        chordRunning -> Status(true, "Detecting chords…", "demux-chords-running")
        doc?.chordStatus == DemuxArtifactStatus.FAILED -> Row(verticalAlignment = Alignment.CenterVertically) {
            Text("No clear chords found (try a more tonal section or stems).", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = { session.reanalyzeChords() }, modifier = Modifier.testTag("demux-chords-retry")) { Text("Retry") }
        }
        doc?.chordStatus == DemuxArtifactStatus.DONE ->
            Text("${doc.chords.size} chord segments", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("demux-chords-done"))
    }
    StemsSection(session, isSong = source.songId != null)
    DemuxPanels(graph, session, source, follow, onFollowChange = { follow = it })
}

@Composable
private fun Status(spinner: Boolean, text: String, tag: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag(tag)) {
        if (spinner) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Pure lifecycle rules for the Demuxer screen (JVM-tested). */
object DemuxScreenRules {
    /** Composition disposal during an Activity recreation keeps the app-scoped session; a real exit clears it. */
    fun shouldClearOnDispose(isChangingConfigurations: Boolean): Boolean = !isChangingConfigurations
}

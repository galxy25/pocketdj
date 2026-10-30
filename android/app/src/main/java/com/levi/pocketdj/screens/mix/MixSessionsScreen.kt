package com.levi.pocketdj.screens.mix

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.mix.recording.RecordingPlayer
import com.levi.pocketdj.mix.recording.SessionFolders
import com.levi.pocketdj.mix.store.MixRecording
import com.levi.pocketdj.mix.store.MixSession
import com.levi.pocketdj.mix.store.MixSessionStore
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.SnackbarHostState
import com.levi.pocketdj.mix.store.MixSessionCsv
import com.levi.pocketdj.screens.browse.SongDetailSheet
import com.levi.pocketdj.screens.collections.ExportRequest
import com.levi.pocketdj.screens.collections.rememberCollectionExporter
import java.io.File
import java.util.Date
import kotlinx.coroutines.delay

/** Pure row-summary text, shared with tests. */
object SessionRowText {
    fun duration(ms: Int): String {
        val s = maxOf(0, ms) / 1000
        return "%d:%02d".format(s / 60, s % 60)
    }

    fun summary(durationMs: Int, tracks: Int, actions: Int, recordings: Int): String =
        "${duration(durationMs)} · $tracks track${if (tracks == 1) "" else "s"} · " +
            "$actions action${if (actions == 1) "" else "s"}" + if (recordings > 0) " · $recordings rec" else ""

    /** Newest first by timeline t0. */
    fun newestFirst(sessions: List<MixSession>): List<MixSession> = sessions.sortedByDescending { it.startedAt }

    /** Row data built from the store's FOLDED readers so the current session reflects its live buffers. */
    fun rows(store: MixSessionStore): List<SessionRowData> = store.sessionsNewestFirst.map { s ->
        SessionRowData(
            session = s, startedAt = store.startedAt(s.id), durationMs = store.durationMs(s.id),
            tracks = store.playedSongIds(s.id).size, actions = store.events(s.id).size,
        )
    }
}

data class SessionRowData(val session: MixSession, val startedAt: Double, val durationMs: Int, val tracks: Int, val actions: Int)

private fun dateText(epochMs: Double): String =
    if (epochMs <= 0) "—" else java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT)
        .format(Date(epochMs.toLong()))

private fun timeText(epochMs: Double): String =
    if (epochMs <= 0) "—" else java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(Date(epochMs.toLong()))

/** Sessions list -> tap a row to open its replay timeline. Back from the detail returns to the list. */
@Composable
fun MixSessionsRoute(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val graph = remember { AppGraph.get(ctx).mixGraph }
    val store = graph.mixSessions
    var openId by rememberSaveable { mutableStateOf<String?>(null) }
    val id = openId
    BackHandler(enabled = id != null) { openId = null }
    Column(Modifier.fillMaxSize().testTag("mix-sessions-screen")) {
        if (id == null) {
            SessionsList(store, onBack = onBack, onOpen = { openId = it })
        } else {
            SessionDetail(store, graph.recordingPlayer, File(SessionFolders.root(ctx.filesDir), id), id, onBack = { openId = null })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SessionsList(store: MixSessionStore, onBack: () -> Unit, onOpen: (String) -> Unit) {
    val sessions by store.sessions.collectAsState()
    val currentId by store.currentIdFlow.collectAsState()
    val playedRev by store.playedRevisionFlow.collectAsState()
    // Live action logging does not emit on `sessions`, so also tick while the list is visible.
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(1000); tick++ } }
    val list = remember(sessions, currentId, playedRev, tick) { SessionRowText.rows(store) }
    var renaming by remember { mutableStateOf<MixSession?>(null) }
    var draft by remember { mutableStateOf("") }
    Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        Text("Sessions", style = MaterialTheme.typography.titleLarge)
    }
    if (list.isEmpty()) {
        Text(
            "No sessions yet. Start mixing on the Mix tab — your actions are recorded into a session you can replay here.",
            Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    LazyColumn(Modifier.fillMaxWidth().testTag("mix-sessions-list")) {
        items(list, key = { it.session.id }) { row ->
            val s = row.session
            val dismiss = rememberSwipeToDismissBoxState(confirmValueChange = {
                if (it == SwipeToDismissBoxValue.EndToStart) { store.delete(s.id); true } else false
            })
            SwipeToDismissBox(
                state = dismiss, enableDismissFromStartToEnd = false,
                backgroundContent = {
                    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.errorContainer).padding(16.dp), contentAlignment = Alignment.CenterEnd) {
                        Icon(Icons.Filled.Delete, "Delete")
                    }
                },
            ) {
                SessionRow(row, isCurrent = s.id == currentId, onClick = { onOpen(s.id) },
                    onRename = { renaming = s; draft = s.name }, onDelete = { store.delete(s.id) })
            }
        }
    }
    renaming?.let { target ->
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("Rename session") },
            text = { OutlinedTextField(draft, { draft = it }, singleLine = true, modifier = Modifier.testTag("mix-session-rename-field")) },
            confirmButton = { TextButton(onClick = { store.rename(target.id, draft); renaming = null }, modifier = Modifier.testTag("mix-session-rename-confirm")) { Text("Save") } },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(row: SessionRowData, isCurrent: Boolean, onClick: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    val s = row.session
    var menu by remember { mutableStateOf(false) }
    Box(Modifier.background(MaterialTheme.colorScheme.background)) {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = { menu = true })
                .padding(horizontal = 16.dp, vertical = 10.dp).testTag("mix-session-row-${s.id}"),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Filled.GraphicEq, null, tint = if (isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(s.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    if (isCurrent) {
                        Text(
                            "Current", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.background,
                            modifier = Modifier.background(MaterialTheme.colorScheme.primary, RoundedCornerShape(50)).padding(horizontal = 6.dp, vertical = 1.dp)
                                .testTag("mix-session-current-badge"),
                        )
                    }
                }
                Text(dateText(row.startedAt), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    SessionRowText.summary(row.durationMs, row.tracks, row.actions, s.recordingsList.size),
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(text = { Text("Rename…") }, onClick = { menu = false; onRename() })
            DropdownMenuItem(text = { Text("Delete session") }, onClick = { menu = false; onDelete() })
        }
    }
}

@Composable
private fun SessionDetail(store: MixSessionStore, player: RecordingPlayer, folder: File, id: String, onBack: () -> Unit) {
    val sessions by store.sessions.collectAsState()
    val session = sessions.firstOrNull { it.id == id }
    // Stable snapshot for the screen's lifetime (the current session keeps recording). Unknown
    // (newer-build) kinds are kept and shown by their raw kind string.
    val events = remember(id) { store.events(id) }
    val playedRev by store.playedRevisionFlow.collectAsState()
    val trackCount = remember(sessions, playedRev) { store.playedSongIds(id).size }
    DisposableEffect(id) { onDispose { player.stop() } }
    // A deleted-from-under-us session: bounce back to the list.
    LaunchedEffect(session == null) { if (session == null) onBack() }
    val ctx = LocalContext.current
    val catalogRepo = remember { AppGraph.get(ctx).catalogRepository }
    val exporter = rememberCollectionExporter()
    var sheetSongId by rememberSaveable { mutableStateOf<String?>(null) }
    val sheetSnackbar = remember { SnackbarHostState() }
    var overflow by remember { mutableStateOf(false) }
    Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
        Column(Modifier.weight(1f)) {
            Text(session?.name ?: "Session", style = MaterialTheme.typography.titleLarge)
            Text("$trackCount tracks · ${events.size} actions", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
            IconButton(onClick = { overflow = true }, modifier = Modifier.testTag("mix-session-more")) { Icon(Icons.Filled.MoreVert, "More") }
            DropdownMenu(overflow, { overflow = false }) {
                DropdownMenuItem(
                    text = { Text("Export tracklist (CSV)") },
                    modifier = Modifier.testTag("mix-session-export-csv"),
                    onClick = {
                        overflow = false
                        val name = session?.name
                        exporter.export(ExportRequest(MixSessionCsv.filename(name), MixSessionCsv.MIME) {
                            val cat = catalogRepo.state.value.catalog ?: return@ExportRequest null
                            MixSessionCsv.bytes(store.playedSongIds(id), cat.songsById, cat.albumsById)
                        })
                    },
                )
            }
        }
    }
    val recs = session?.recordingsList.orEmpty()
    if (recs.isNotEmpty()) RecordingsPanel(store, player, folder, id, recs)
    MixReplayTimeline(
        events, onOpenSong = { sheetSongId = it },
        songInCatalog = { catalogRepo.state.value.catalog?.songsById?.containsKey(it) == true },
    )
    sheetSongId?.let { SongDetailSheet(songId = it, onDismiss = { sheetSongId = null }, snackbar = sheetSnackbar) }
    val err by player.lastError.collectAsState()
    err?.let {
        AlertDialog(
            onDismissRequest = { player.consumeError() }, title = { Text("Can't play recording") }, text = { Text(it) },
            confirmButton = { TextButton(onClick = { player.consumeError() }) { Text("OK") } },
        )
    }
}

@Composable
private fun RecordingsPanel(store: MixSessionStore, player: RecordingPlayer, folder: File, sessionId: String, recs: List<MixRecording>) {
    val playingPath by player.playing.collectAsState()
    var pendingDelete by remember { mutableStateOf<MixRecording?>(null) }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 12.dp).testTag("mix-recordings-panel"), shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Recordings", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            recs.forEachIndexed { idx, rec ->
                val file = File(folder, rec.fileName)
                val isPlaying = playingPath == file.path
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    IconButton(onClick = { player.toggle(file) }, modifier = Modifier.testTag("mix-recording-play-${rec.id}")) {
                        Icon(if (isPlaying) Icons.Filled.StopCircle else Icons.Filled.PlayCircle, if (isPlaying) "Stop recording" else "Play recording", Modifier.size(30.dp), tint = MaterialTheme.colorScheme.primary)
                    }
                    Column(Modifier.weight(1f)) {
                        Text("Take ${idx + 1}", style = MaterialTheme.typography.bodySmall)
                        Text("${timeText(rec.startedAt)} · ${recordingClock(rec.durationMs.toLong())}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { pendingDelete = rec }, modifier = Modifier.testTag("mix-recording-delete-${rec.id}")) { Icon(Icons.Filled.Delete, "Delete recording", Modifier.size(20.dp), tint = MaterialTheme.colorScheme.error) }
                }
                if (isPlaying) RecordingScrubBar(player)
            }
        }
    }
    pendingDelete?.let { rec ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete this recording?") },
            text = { Text("Removes this take's audio file (${recordingClock(rec.durationMs.toLong())}) from this device. The session's played-tracks log and timeline are kept.") },
            confirmButton = {
                TextButton(onClick = {
                    val f = File(folder, rec.fileName)
                    if (player.playing.value == f.path) player.stop()   // release the file first
                    runCatching { f.delete() }
                    runCatching { if (folder.isDirectory && folder.list().isNullOrEmpty()) folder.delete() }
                    store.removeRecording(sessionId, rec.id)
                    pendingDelete = null
                }) { Text("Delete recording") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

/** Scrub bar for the take that is playing; polls the player at 10 Hz, seeks on release. */
@Composable
private fun RecordingScrubBar(player: RecordingPlayer) {
    var pos by remember { mutableStateOf(0) }
    var dragging by remember { mutableStateOf(false) }
    val dur = maxOf(player.durationMs, 1)
    LaunchedEffect(Unit) { while (true) { if (!dragging) pos = player.currentPositionMs; delay(100) } }
    Column {
        Slider(
            value = pos.coerceIn(0, dur).toFloat(), valueRange = 0f..dur.toFloat(),
            onValueChange = { dragging = true; pos = it.toInt() },
            onValueChangeFinished = { player.seekTo(pos); dragging = false },
            modifier = Modifier.testTag("mix-recording-scrub"),
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(recordingClock(pos.toLong()), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(recordingClock(dur.toLong()), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

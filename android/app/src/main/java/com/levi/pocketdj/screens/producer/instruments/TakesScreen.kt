package com.levi.pocketdj.screens.producer.instruments

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import com.levi.pocketdj.screens.producer.common.FolderRow
import com.levi.pocketdj.screens.producer.common.MoveToItems
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.studio.engine.Sf2SynthVoice
import com.levi.pocketdj.studio.engine.SynthVoice
import com.levi.pocketdj.studio.engine.TakeFileException
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.store.StudioFolderKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pure row copy. */
object TakesCopy {
    fun subtitle(t: StudioTake): String =
        "${t.instrument.displayName}  ·  ${StudioFmt.trim(t.bpm)} BPM  ·  ${StudioFmt.mmss(t.durationMs)}  ·  ${t.allScoreEvents.size} notes" +
            (if (t.staffCount > 1) "  ·  ${t.staffCount} staffs" else "")

    /** Parse the tempo field; null when it isn't a usable BPM. The store clamps to 20...300. */
    fun parseBpm(text: String): Double? = text.trim().toDoubleOrNull()?.takeIf { it.isFinite() && it > 0 }
}

/** The Takes list: replay, rename, delete, folders, instrument switch, tempo rescale, "use as sample" (copies the audio). */
@Composable
fun TakesScreen(graph: AppGraph, onNeedPacks: () -> Unit, modifier: Modifier = Modifier, onOpenScore: (String) -> Unit = {}) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val engine = studio.instrumentEngine
    val packs = studio.instrumentPacks
    val doc by store.state.collectAsState()
    val es by engine.state.collectAsState()
    val scope = rememberCoroutineScope()

    var folderId by remember { mutableStateOf<String?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<StudioTake?>(null) }
    var retempo by remember { mutableStateOf<StudioTake?>(null) }
    var pendingDelete by remember { mutableStateOf<StudioTake?>(null) }
    var moveNewFolderFor by remember { mutableStateOf<String?>(null) }
    var playingId by remember { mutableStateOf<String?>(null) }
    var busyId by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }

    DisposableEffect(Unit) { onDispose { engine.stopReplay() } }

    // Import a .mid onto the current instrument (piano when none is loaded); failures surface MidiImportException.message.
    val ctx = androidx.compose.ui.platform.LocalContext.current
    var importing by remember { mutableStateOf(false) }
    val importLauncher = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            importing = true
            scope.launch {
                try {
                    val key = engine.state.value.currentInstrument ?: InstrumentKey.PIANO
                    val (bytes, fileName) = withContext(Dispatchers.IO) {
                        val b = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw com.levi.pocketdj.studio.midi.MidiImportException(com.levi.pocketdj.studio.midi.MidiImport.CANNOT_OPEN)
                        val n = ctx.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                        b to n
                    }
                    val t = com.levi.pocketdj.studio.midi.MidiImport.importTake(bytes, fileName, key, "Imported MIDI", studio.takeFiler, packs.localBankFile(key))
                    message = "Imported “${t.name}”."
                } catch (e: com.levi.pocketdj.studio.midi.MidiImportException) {
                    message = e.message
                    if (packs.localBankFile(engine.state.value.currentInstrument ?: InstrumentKey.PIANO) == null) onNeedPacks()
                } catch (e: kotlinx.coroutines.CancellationException) { throw e
                } catch (e: Throwable) { message = "Couldn't import that MIDI file." } finally { importing = false }
            }
        }
    }

    val folders = store.foldersOrdered(StudioFolderKind.TAKE)
    val inFolder = remember(doc, folderId) { store.takes(folderId) }
    val current = folders.firstOrNull { it.id == folderId }

    suspend fun play(t: StudioTake) {
        val key = t.instrument
        val bank = packs.localBankFile(key)
        val pack = packs.pack(key)
        if (bank == null || pack == null) { message = "Download the ${key.displayName} pack to replay this take."; onNeedPacks(); return }
        if (engine.state.value.currentInstrument != key && !engine.loadInstrument(key, bank)) { message = "Couldn't load the ${key.displayName} sound bank."; return }
        // Extra staffs each get their own voice from THEIR instrument's bank (engine owns + retires them).
        val extras = ArrayList<Pair<SynthVoice, List<StudioNoteEvent>>>()
        var handed = false
        try {
            for (s in t.extraStaffs.orEmpty()) {
                val b = packs.localBankFile(s.instrument) ?: continue
                val v = withContext(Dispatchers.Default) {
                    val nv = try { engine.createVoice() } catch (e: Exception) { null } catch (e: LinkageError) { null }
                    if (nv != null && !(runCatching { nv.load(b.path) && nv.setPreset(0, s.instrument.gmProgram) }.getOrDefault(false))) { runCatching { nv.close() }; null } else nv
                }
                if (v != null) extras.add(v to s.scoreEvents)
            }
            if (engine.replay(t.scoreEvents, 0, extras)) { handed = true; playingId = t.id; message = null } else message = "Nothing to play in this take."
        } finally {
            // The engine owns the voices only when replay() accepted them; otherwise (refused / cancelled) free each native synth.
            if (!handed) extras.forEach { runCatching { it.first.close() } }
        }
    }

    Column(modifier.fillMaxSize().testTag("takes-screen")) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (current != null) {
                IconButton(onClick = { folderId = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to all takes") }
                Text(current.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else Box(Modifier.weight(1f))
            TextButton(onClick = { importLauncher.launch(arrayOf("audio/midi", "audio/x-midi", "audio/mid", "application/octet-stream")) }, enabled = !importing, modifier = Modifier.testTag("take-import-midi")) { Text(if (importing) "Importing…" else "Import MIDI") }
            IconButton(onClick = { newFolder = true }, modifier = Modifier.testTag("take-new-folder")) { Icon(Icons.Filled.CreateNewFolder, "New folder") }
        }
        HorizontalDivider()
        message?.let { Text(it, Modifier.padding(16.dp).testTag("takes-message"), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (folders.isEmpty() && inFolder.isEmpty() && folderId == null) {
            Text("No takes yet. Record one on the Play tab.", Modifier.padding(24.dp).testTag("takes-empty"), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        LazyColumn(Modifier.fillMaxSize()) {
            if (folderId == null) {
                items(folders, key = { it.id }) { f ->
                    FolderRow(f, count = store.takes(f.id).size, onOpen = { folderId = f.id },
                        onRename = { store.renameFolder(StudioFolderKind.TAKE, f.id, it) },
                        onDelete = { store.deleteFolder(StudioFolderKind.TAKE, f.id) })
                }
            }
            items(inFolder, key = { it.id }) { t ->
                val isPlaying = es.isReplaying && playingId == t.id
                TakeRow(
                    t, folders, isPlaying, busy = busyId == t.id,
                    onScore = { onOpenScore(t.id) },
                    onPlay = { if (isPlaying) engine.stopReplay() else scope.launch { play(t) } },
                    onRename = { renaming = t },
                    onInstrument = { k -> engine.stopReplay(); store.setTakeInstrument(t.id, k) },
                    onTempo = { retempo = t },
                    onUseAsSample = {
                        busyId = t.id
                        scope.launch {
                            try {
                                val s = withContext(Dispatchers.IO) { studio.takeFiler.useAsSample(store.take(t.id) ?: t) { packs.localBankFile(it) } }
                                message = "Made sample “${s.name}” — it's an independent copy, find it under Samples."
                            } catch (e: TakeFileException) { message = e.failure.message } catch (e: Exception) { message = "Couldn't make a sample from that take." }
                            finally { busyId = null }
                        }
                    },
                    onMove = { to -> store.setItemFolder(StudioFolderKind.TAKE, t.id, to) },
                    onNewFolderForMove = { moveNewFolderFor = t.id },
                    onDelete = { pendingDelete = t },
                    // STU-15: a Demuxer-made take re-extracts the other mode (comping <-> melody) in place.
                    onSwitchMode = if (t.demuxSourceKey == null) null else ({
                        busyId = t.id
                        scope.launch {
                            try { message = com.levi.pocketdj.screens.producer.demux.switchDemuxTakeMode(graph, store.take(t.id) ?: t) ?: "Switched to ${com.levi.pocketdj.studio.demux.DemuxTakeSwitch.targetMode(t.demuxMode)}." }
                            finally { busyId = null }
                        }
                    }),
                )
                HorizontalDivider()
            }
        }
    }

    if (newFolder) NameDialog("New folder", "", "Create", { newFolder = false }) { store.createFolder(StudioFolderKind.TAKE, it); newFolder = false }
    moveNewFolderFor?.let { tid ->
        NameDialog("New folder", "", "Create & move", { moveNewFolderFor = null }) {
            val f = store.createFolder(StudioFolderKind.TAKE, it); store.setItemFolder(StudioFolderKind.TAKE, tid, f.id); moveNewFolderFor = null
        }
    }
    renaming?.let { t -> NameDialog("Rename take", t.name, "Rename", { renaming = null }) { store.renameTake(t.id, it); renaming = null } }
    retempo?.let { t -> TempoDialog(t, onDismiss = { retempo = null }) { bpm -> engine.stopReplay(); store.setTakeTempo(t.id, bpm); retempo = null } }
    pendingDelete?.let { t ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete take?") },
            text = { Text("“${t.name}” and its audio are removed from this device. Samples made from it are separate copies and stay.") },
            confirmButton = { TextButton(onClick = { engine.stopReplay(); store.deleteTake(t.id); pendingDelete = null }, modifier = Modifier.testTag("take-delete-confirm")) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun TakeRow(
    t: StudioTake, folders: List<com.levi.pocketdj.studio.model.StudioFolder>, playing: Boolean, busy: Boolean,
    onPlay: () -> Unit, onScore: () -> Unit, onRename: () -> Unit, onInstrument: (InstrumentKey) -> Unit, onTempo: () -> Unit, onUseAsSample: () -> Unit,
    onMove: (String?) -> Unit, onNewFolderForMove: () -> Unit, onDelete: () -> Unit,
    onSwitchMode: (() -> Unit)? = null,
) {
    var menu by remember { mutableStateOf(false) }
    var instMenu by remember { mutableStateOf(false) }
    var addTo by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable(onClick = onPlay).padding(start = 8.dp, top = 4.dp, bottom = 4.dp).testTag("take-${t.id}"), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onPlay, modifier = Modifier.testTag("take-play-${t.id}")) {
            Icon(if (playing) Icons.Filled.Stop else Icons.Filled.PlayArrow, if (playing) "Stop" else "Replay take")
        }
        Column(Modifier.weight(1f)) {
            Text(t.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Text(if (busy) "Making sample…" else TakesCopy.subtitle(t), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box {
            IconButton(onClick = { menu = true }, modifier = Modifier.testTag("take-menu-${t.id}")) { Icon(Icons.Filled.MoreVert, "Take actions") }
            if (addTo) AddToCollectionSheet(item = AddToItem.Song(t.id), onDismiss = { addTo = false })
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Open score") }, onClick = { menu = false; onScore() }, modifier = Modifier.testTag("take-score-${t.id}"))
                DropdownMenuItem(text = { Text("Use as sample") }, enabled = !busy, onClick = { menu = false; onUseAsSample() }, modifier = Modifier.testTag("take-use-as-sample-${t.id}"))
                DropdownMenuItem(text = { Text("Add to…") }, onClick = { menu = false; addTo = true })
                DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; onRename() })
                DropdownMenuItem(text = { Text("Instrument: ${t.instrument.displayName}") }, onClick = { menu = false; instMenu = true })
                if (onSwitchMode != null) DropdownMenuItem(text = { Text(com.levi.pocketdj.studio.demux.DemuxTakeSwitch.menuLabel(t.demuxMode)) }, enabled = !busy, onClick = { menu = false; onSwitchMode() }, modifier = Modifier.testTag("take-switch-mode-${t.id}"))
                DropdownMenuItem(text = { Text("Change tempo…") }, onClick = { menu = false; onTempo() }, modifier = Modifier.testTag("take-tempo-${t.id}"))
                MoveToItems(folders, t.folderId, onMove = { menu = false; onMove(it) }, onNewFolder = { menu = false; onNewFolderForMove() })
                DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete() })
            }
            DropdownMenu(instMenu, { instMenu = false }) {
                InstrumentKey.entries.forEach { k ->
                    DropdownMenuItem(text = { Text(k.displayName + if (k == t.instrument) "  ✓" else "") }, enabled = k != t.instrument, onClick = { instMenu = false; onInstrument(k) })
                }
            }
        }
    }
}

@Composable
private fun TempoDialog(t: StudioTake, onDismiss: () -> Unit, onConfirm: (Double) -> Unit) {
    var text by remember { mutableStateOf(StudioFmt.trim(t.bpm)) }
    val bpm = TakesCopy.parseBpm(text)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Change tempo") },
        text = {
            Column {
                Text("Note times are rescaled to the new tempo and the audio is re-rendered.", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("BPM (20–300)") }, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.testTag("tempo-field"))
            }
        },
        confirmButton = { TextButton(enabled = bpm != null, onClick = { onConfirm(bpm!!) }, modifier = Modifier.testTag("tempo-confirm")) { Text("Change") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

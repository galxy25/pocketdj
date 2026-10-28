package com.levi.pocketdj.screens.producer.loops

import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.MoveToItems
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.studio.engine.LoopMath
import com.levi.pocketdj.studio.model.StudioFolder
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.store.StudioFolderKind
import kotlinx.coroutines.launch

/**
 * The Loops tab (iOS StudioLoopsView): saved loops (Unfiled + one collapsible section per loop folder) with a
 * looped audition toggle, rename / move-to / delete (the delete dialog spells out the sequencer rows that would go
 * silent), and the "New loop" entry into the slice builder sheet. Loops are DERIVED, so the empty state points at
 * the builder instead of dead-ending. Audition is app-scoped: it survives navigation; the row toggle silences it.
 */
@Composable
fun LoopsScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    val studio = graph.studioGraph
    val store = studio.studioStore
    val doc by store.state.collectAsState()
    val scope = rememberCoroutineScope()
    val audition = studio.loopAudition
    val playingId by audition.playingId.collectAsState()

    var showBuilder by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<StudioLoop?>(null) }
    var pendingDelete by remember { mutableStateOf<StudioLoop?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    var moveNewFolderFor by remember { mutableStateOf<String?>(null) }
    var renamingFolder by remember { mutableStateOf<StudioFolder?>(null) }
    var deletingFolder by remember { mutableStateOf<StudioFolder?>(null) }
    // Collapsed loop-folder ids (missing => expanded); survives rotation, not a process restart.
    var collapsed by rememberSaveable { mutableStateOf(setOf<String>()) }

    val folders = remember(doc) { store.foldersOrdered(StudioFolderKind.LOOP) }
    val unfiled = remember(doc) { store.loops(null) }

    fun toggle(l: StudioLoop) {
        if (playingId == l.id) { audition.stop(); return }
        val file = store.localUrlForPlayback(l.id)?.ref?.file
        if (file == null || !file.isFile) {
            note = "“${l.name}” can’t play right now — its audio file or folder is unreachable."
            return
        }
        note = null
        scope.launch {
            if (!audition.play(l.id, file, l.frames)) {
                note = if (audition.lastRefusal == "mic-capture-active") "Playback is paused while the microphone is recording."
                else "“${l.name}” can’t play right now — its audio file or folder is unreachable."
            }
        }
    }

    @Composable
    fun LoopItem(l: StudioLoop) {
        LoopRow(
            l, playing = playingId == l.id, sourceGone = !store.sampleExists(l.sampleId), folders = folders,
            onToggle = { toggle(l) }, onRename = { renaming = l },
            onMove = { to -> store.setItemFolder(StudioFolderKind.LOOP, l.id, to) },
            onNewFolderForMove = { moveNewFolderFor = l.id }, onDelete = { pendingDelete = l },
        )
        HorizontalDivider()
    }

    Column(modifier.fillMaxSize().testTag("loops-screen")) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Loops", Modifier.weight(1f).padding(start = 8.dp), style = MaterialTheme.typography.titleMedium)
            IconButton(onClick = { newFolder = true }, modifier = Modifier.testTag("loop-new-folder")) { Icon(Icons.Filled.CreateNewFolder, "New folder") }
            TextButton(onClick = { showBuilder = true }, modifier = Modifier.testTag("loop-new")) {
                Icon(Icons.Filled.Add, null, Modifier.size(18.dp)); Text("New loop", Modifier.padding(start = 4.dp))
            }
        }
        HorizontalDivider()
        note?.let { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 8.dp).testTag("loops-note"), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        LazyColumn(Modifier.fillMaxSize()) {
            if (doc.loops.isEmpty() && doc.loopFolders.isEmpty()) {
                item {
                    Text(
                        "No loops yet — tap New loop, pick a sample and slice a beat-synced window.",
                        Modifier.padding(24.dp).testTag("loops-empty"), color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else if (unfiled.isEmpty()) {
                item { Text("No unfiled loops.", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall) }
            }
            items(unfiled, key = { it.id }) { LoopItem(it) }
            folders.forEach { f ->
                val members = store.loops(f.id)
                val open = f.id !in collapsed
                item(key = "folder-${f.id}") {
                    LoopFolderHeader(
                        f, members.size, open,
                        onToggle = { collapsed = if (open) collapsed + f.id else collapsed - f.id },
                        onRename = { renamingFolder = f }, onDelete = { deletingFolder = f },
                    )
                }
                if (open) {
                    if (members.isEmpty()) item(key = "empty-${f.id}") {
                        Text("Empty folder — move a loop in with its ⋯ menu.", Modifier.padding(start = 48.dp, top = 4.dp, bottom = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    }
                    items(members, key = { it.id }) { LoopItem(it) }
                }
            }
        }
    }

    if (showBuilder) LoopSliceSheet(graph, onDismiss = { showBuilder = false })
    if (newFolder) NameDialog("New folder", "", "Create", { newFolder = false }) { store.createFolder(StudioFolderKind.LOOP, it); newFolder = false }
    moveNewFolderFor?.let { lid ->
        NameDialog("New folder", "", "Create & move", { moveNewFolderFor = null }) {
            val f = store.createFolder(StudioFolderKind.LOOP, it); store.setItemFolder(StudioFolderKind.LOOP, lid, f.id); moveNewFolderFor = null
        }
    }
    renaming?.let { l -> NameDialog("Rename loop", l.name, "Rename", { renaming = null }) { store.renameLoop(l.id, it); renaming = null } }
    renamingFolder?.let { f -> NameDialog("Rename folder", f.name, "Rename", { renamingFolder = null }) { store.renameFolder(StudioFolderKind.LOOP, f.id, it); renamingFolder = null } }
    deletingFolder?.let { f ->
        AlertDialog(
            onDismissRequest = { deletingFolder = null },
            title = { Text("Delete this folder?") },
            text = { Text("The folder’s loops move back to Unfiled. No loops or audio are deleted.") },
            confirmButton = { TextButton(onClick = { store.deleteFolder(StudioFolderKind.LOOP, f.id); deletingFolder = null }) { Text("Delete folder") } },
            dismissButton = { TextButton(onClick = { deletingFolder = null }) { Text("Cancel") } },
        )
    }
    pendingDelete?.let { l ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete loop?") },
            text = { Text(LoopMath.deleteMessage(store.referrers(l.id).patternRowCount)) },
            confirmButton = {
                TextButton(modifier = Modifier.testTag("loop-delete-confirm"), onClick = {
                    // Silence it first: deleting the file under a looping schedule leaves the buffer ringing with no row to stop it.
                    if (playingId == l.id) audition.stop()
                    note = if (store.deleteLoop(l.id)) null
                    else "The loops folder is unreachable right now — reconnect it, then delete “${l.name}”."
                    pendingDelete = null
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun LoopFolderHeader(f: StudioFolder, count: Int, open: Boolean, onToggle: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(start = 16.dp).testTag("folder-${f.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Folder, null, tint = MaterialTheme.colorScheme.primary)
        Text(f.name, Modifier.weight(1f).padding(start = 12.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text("$count", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
        Icon(if (open) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, if (open) "Collapse folder" else "Expand folder", Modifier.padding(start = 8.dp))
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "Folder actions") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Rename folder") }, onClick = { menu = false; onRename() })
                DropdownMenuItem(text = { Text("Delete folder") }, onClick = { menu = false; onDelete() })
            }
        }
    }
    HorizontalDivider()
}

@Composable
private fun LoopRow(
    l: StudioLoop, playing: Boolean, sourceGone: Boolean, folders: List<StudioFolder>,
    onToggle: () -> Unit, onRename: () -> Unit, onMove: (String?) -> Unit, onNewFolderForMove: () -> Unit, onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 8.dp, bottom = 8.dp).testTag("loop-${l.id}"), verticalAlignment = Alignment.CenterVertically) {
        FilledTonalIconButton(
            onClick = onToggle,
            modifier = Modifier.size(40.dp).testTag("loop-audition-${l.id}"),
            colors = if (playing) IconButtonDefaults.filledTonalIconButtonColors(containerColor = MaterialTheme.colorScheme.primaryContainer) else IconButtonDefaults.filledTonalIconButtonColors(),
        ) {
            Icon(
                if (playing) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                contentDescription = if (playing) "Stop the looped audition" else "Audition this loop (loops until stopped)",
                modifier = Modifier.semantics { contentDescription = if (playing) "Stop loop" else "Play loop" },
            )
        }
        Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(l.name.ifEmpty { "Loop" }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Text(LoopMath.rowSubtitle(l), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            // Loops are self-contained after render: flag, never break.
            if (sourceGone) Text(LoopMath.SOURCE_REMOVED_NOTE, Modifier.testTag("loop-source-removed-${l.id}"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.tertiary)
        }
        Box {
            IconButton(onClick = { menu = true }, modifier = Modifier.testTag("loop-menu-${l.id}")) { Icon(Icons.Filled.MoreVert, "Loop actions") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Rename…") }, onClick = { menu = false; onRename() })
                MoveToItems(folders, l.folderId, onMove = { menu = false; onMove(it) }, onNewFolder = { menu = false; onNewFolderForMove() })
                DropdownMenuItem(text = { Text("Delete loop") }, onClick = { menu = false; onDelete() })
            }
        }
    }
}

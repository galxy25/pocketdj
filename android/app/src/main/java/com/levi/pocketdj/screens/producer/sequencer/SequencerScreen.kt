package com.levi.pocketdj.screens.producer.sequencer

import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
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
import androidx.compose.material.icons.filled.GridOn
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.MoveToItems
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.studio.engine.PatternMath
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioFolder
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.store.StudioFolderKind

/**
 * Producer > Sequencer (iOS StudioSequencerView): the pattern list (Unfiled + collapsible folders, rename / duplicate /
 * move-to / delete) that opens into [PatternEditor]. "New pattern" creates and opens straight into the editor. The
 * open pattern id survives rotation (rememberSaveable); the engine is app-scoped and plays ONE pattern globally.
 */
@Composable
fun SequencerScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    val store = graph.studioGraph.studioStore
    var openId by rememberSaveable { mutableStateOf<String?>(null) }
    val id = openId
    androidx.activity.compose.BackHandler(enabled = id != null) { openId = null }
    if (id != null) PatternEditor(graph, id, onBack = { openId = null }, modifier)
    else PatternList(graph, onOpen = { openId = it }, modifier)
}

@Composable
private fun PatternList(graph: AppGraph, onOpen: (String) -> Unit, modifier: Modifier) {
    val sg = graph.studioGraph
    val store = sg.studioStore
    val doc by store.state.collectAsState()
    val engine = sg.patternEngine
    val loadedId by engine.loadedPatternId.collectAsState()
    val playing by engine.isPlaying.collectAsState()

    var renaming by remember { mutableStateOf<StudioPattern?>(null) }
    var deleting by remember { mutableStateOf<StudioPattern?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    var moveNewFolderFor by remember { mutableStateOf<String?>(null) }
    var renamingFolder by remember { mutableStateOf<StudioFolder?>(null) }
    var deletingFolder by remember { mutableStateOf<StudioFolder?>(null) }
    // Collapsed sequence-folder ids (missing => expanded); survives rotation.
    var collapsed by rememberSaveable { mutableStateOf(setOf<String>()) }

    val folders = remember(doc) { store.foldersOrdered(StudioFolderKind.PATTERN) }
    val unfiled = remember(doc) { store.patterns(null) }

    fun newPattern() {
        val p = StudioPattern.of(
            StudioFactory.newPatternId(), "Pattern ${store.patterns.size + 1}", bpm = 120.0, createdAt = System.currentTimeMillis().toDouble(),
        )
        store.addPattern(p)
        onOpen(p.id)
    }

    @Composable
    fun Item(p: StudioPattern) {
        PatternListRow(
            p, folders, soundingNow = playing && loadedId == p.id, onOpen = { onOpen(p.id) }, onRename = { renaming = p },
            onDuplicate = { store.addPattern(PatternMath.duplicate(p, StudioFactory.newPatternId(), System.currentTimeMillis().toDouble())) },
            onMove = { to -> store.setItemFolder(StudioFolderKind.PATTERN, p.id, to) },
            onNewFolderForMove = { moveNewFolderFor = p.id }, onDelete = { deleting = p },
        )
        HorizontalDivider()
    }

    Column(modifier.fillMaxSize().testTag("sequencer-screen")) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Patterns", Modifier.weight(1f).padding(start = 8.dp), style = MaterialTheme.typography.titleMedium)
            IconButton(onClick = { newFolder = true }, Modifier.testTag("seq-new-folder")) { Icon(Icons.Filled.CreateNewFolder, "New folder") }
            TextButton(onClick = ::newPattern, Modifier.testTag("seq-new")) {
                Icon(Icons.Filled.Add, null, Modifier.size(18.dp)); Text("New pattern", Modifier.padding(start = 4.dp))
            }
        }
        HorizontalDivider()
        LazyColumn(Modifier.fillMaxSize()) {
            if (doc.patterns.isEmpty() && doc.patternFolders.isEmpty()) {
                item {
                    Text(
                        "No patterns yet — a pattern is one bar of 16 steps over your samples and loops. Program hits, play it in a loop, bounce it for offline.",
                        Modifier.padding(24.dp).testTag("seq-empty"), color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else if (unfiled.isEmpty()) {
                item { Text("No unfiled sequences.", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall) }
            }
            items(unfiled, key = { it.id }) { Item(it) }
            folders.forEach { f ->
                val members = store.patterns(f.id)
                val open = f.id !in collapsed
                item(key = "folder-${f.id}") {
                    FolderHeader(
                        f, members.size, open, onToggle = { collapsed = if (open) collapsed + f.id else collapsed - f.id },
                        onRename = { renamingFolder = f }, onDelete = { deletingFolder = f },
                    )
                }
                if (open) {
                    if (members.isEmpty()) item(key = "empty-${f.id}") {
                        Text("Empty folder — move a sequence in with its ⋯ menu.", Modifier.padding(start = 48.dp, top = 4.dp, bottom = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    }
                    items(members, key = { it.id }) { Item(it) }
                }
            }
        }
    }

    if (newFolder) NameDialog("New folder", "", "Create", { newFolder = false }) { store.createFolder(StudioFolderKind.PATTERN, it); newFolder = false }
    moveNewFolderFor?.let { pid ->
        NameDialog("New folder", "", "Create & move", { moveNewFolderFor = null }) {
            val f = store.createFolder(StudioFolderKind.PATTERN, it); store.setItemFolder(StudioFolderKind.PATTERN, pid, f.id); moveNewFolderFor = null
        }
    }
    renaming?.let { p -> NameDialog("Rename pattern", p.name, "Save", { renaming = null }) { store.renamePattern(p.id, it); renaming = null } }
    renamingFolder?.let { f -> NameDialog("Rename folder", f.name, "Rename", { renamingFolder = null }) { store.renameFolder(StudioFolderKind.PATTERN, f.id, it); renamingFolder = null } }
    deletingFolder?.let { f ->
        AlertDialog(
            onDismissRequest = { deletingFolder = null },
            title = { Text("Delete this folder?") },
            text = { Text("The folder’s sequences move back to Unfiled. No sequences or audio are deleted.") },
            confirmButton = { TextButton(onClick = { store.deleteFolder(StudioFolderKind.PATTERN, f.id); deletingFolder = null }) { Text("Delete folder") } },
            dismissButton = { TextButton(onClick = { deletingFolder = null }) { Text("Cancel") } },
        )
    }
    deleting?.let { p ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete this pattern?") },
            text = { Text("Removes the pattern and its bounced audio. The samples and loops it uses are kept.") },
            confirmButton = {
                TextButton(modifier = Modifier.testTag("seq-delete-confirm"), onClick = {
                    // A deleted pattern must not keep sounding: the engine plays its own loaded copy, so stop it first.
                    if (engine.loadedPatternId.value == p.id && engine.isPlaying.value) engine.stopPattern()
                    store.deletePattern(p.id)
                    deleting = null
                }) { Text("Delete pattern") }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun FolderHeader(f: StudioFolder, count: Int, open: Boolean, onToggle: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(start = 16.dp).testTag("seq-folder-${f.id}"), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Folder, null, tint = MaterialTheme.colorScheme.tertiary)
        Text(f.name, Modifier.weight(1f).padding(start = 12.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text("$count", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
        Icon(if (open) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, if (open) "Collapse folder" else "Expand folder", Modifier.padding(start = 8.dp))
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "Folder actions") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Rename folder") }, onClick = { menu = false; onRename() }, modifier = Modifier.testTag("seq-folder-rename-${f.id}"))
                DropdownMenuItem(text = { Text("Delete folder") }, onClick = { menu = false; onDelete() }, modifier = Modifier.testTag("seq-folder-delete-${f.id}"))
            }
        }
    }
    HorizontalDivider()
}

@Composable
private fun PatternListRow(
    p: StudioPattern, folders: List<StudioFolder>, soundingNow: Boolean, onOpen: () -> Unit, onRename: () -> Unit, onDuplicate: () -> Unit,
    onMove: (String?) -> Unit, onNewFolderForMove: () -> Unit, onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    var addTo by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(start = 16.dp, top = 6.dp, bottom = 6.dp).testTag("seq-pattern-${p.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.GridOn, null, tint = if (soundingNow) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(p.name.ifEmpty { "Untitled pattern" }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Text(PatternMath.listSubtitle(p), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
            IconButton(onClick = { menu = true }, Modifier.testTag("seq-menu-${p.id}")) { Icon(Icons.Filled.MoreVert, "Pattern actions") }
            if (addTo) AddToCollectionSheet(item = AddToItem.Song(p.id), onDismiss = { addTo = false })
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Add to…") }, onClick = { menu = false; addTo = true }, modifier = Modifier.testTag("seq-add-to-${p.id}"))
                DropdownMenuItem(text = { Text("Rename…") }, onClick = { menu = false; onRename() }, modifier = Modifier.testTag("seq-rename-${p.id}"))
                DropdownMenuItem(text = { Text("Duplicate") }, onClick = { menu = false; onDuplicate() }, modifier = Modifier.testTag("seq-duplicate-${p.id}"))
                MoveToItems(folders, p.folderId, onMove = { menu = false; onMove(it) }, onNewFolder = { menu = false; onNewFolderForMove() })
                DropdownMenuItem(text = { Text("Delete pattern") }, onClick = { menu = false; onDelete() }, modifier = Modifier.testTag("seq-delete-${p.id}"))
            }
        }
    }
}

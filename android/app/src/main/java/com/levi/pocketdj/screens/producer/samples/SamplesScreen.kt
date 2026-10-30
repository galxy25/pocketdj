package com.levi.pocketdj.screens.producer.samples

import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Mic
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.producer.common.FolderRow
import com.levi.pocketdj.screens.producer.common.MoveToItems
import com.levi.pocketdj.screens.producer.common.NameDialog
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.studio.engine.SampleFileException
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFolderKind
import com.levi.pocketdj.studio.store.StudioReferrers
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Pure copy for the delete confirmation (lists what references the sample). */
object SamplesCopy {
    fun deleteMessage(name: String, r: StudioReferrers): String {
        val parts = mutableListOf("The audio file is removed from this device.")
        if (r.loopCount > 0) parts.add("${r.loopCount} loop${if (r.loopCount == 1) "" else "s"} sliced from it keep playing but can’t be re-sliced.")
        if (r.patternRowCount > 0) parts.add("${r.patternRowCount} sequencer row${if (r.patternRowCount == 1) "" else "s"} will be muted.")
        return parts.joinToString(" ")
    }
}

/** The Samples tab: folders + samples, record / import / carve entry points, per-row rename / move / delete. */
@Composable
fun SamplesScreen(graph: AppGraph, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val studio = graph.studioGraph
    val store = studio.studioStore
    val doc by store.state.collectAsState()
    val scope = rememberCoroutineScope()

    var folderId by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<String?>(null) }
    var showMic by remember { mutableStateOf(false) }
    var showTrack by remember { mutableStateOf(false) }
    var newFolder by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var deleteBlocked by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<StudioSample?>(null) }
    var renaming by remember { mutableStateOf<StudioSample?>(null) }
    var moveNewFolderFor by remember { mutableStateOf<String?>(null) }

    // A new sample that could not reach the user's samples folder (revoked / write failed) says so, once.
    val folderNotice by store.samplesFolderNotice.collectAsState()
    LaunchedEffect(folderNotice) {
        folderNotice?.let { message = it; store.clearSamplesFolderNotice() }
    }

    // A take interrupted by a kill is filed on entry.
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { runCatching { studio.micRecorder.recoverOrphans() } } }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        importing = true
        scope.launch {
            try {
                val (tmp, name) = withContext(Dispatchers.IO) { copyToCache(ctx, uri) }
                try {
                    val s = studio.sampleFactory.importFile(tmp, name)
                    if (folderId != null) store.setItemFolder(StudioFolderKind.SAMPLE, s.id, folderId)
                    editing = s.id
                } finally { tmp.delete() }
            } catch (e: SampleFileException) {
                message = e.failure.message
            } catch (e: Exception) {
                message = "Couldn’t import that file."
            } finally { importing = false }
        }
    }

    val folders = store.foldersOrdered(StudioFolderKind.SAMPLE)
    val inFolder = remember(doc, folderId) { store.samples(folderId) }
    val current = folders.firstOrNull { it.id == folderId }

    Column(modifier.fillMaxSize().testTag("samples-screen")) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (current != null) {
                IconButton(onClick = { folderId = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to all samples") }
                Text(current.name, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            } else Box(Modifier.weight(1f))
            IconButton(onClick = { showMic = true }, modifier = Modifier.testTag("sample-record")) { Icon(Icons.Filled.Mic, "Record from microphone") }
            IconButton(onClick = { picker.launch(arrayOf("audio/*")) }, enabled = !importing, modifier = Modifier.testTag("sample-import")) { Icon(Icons.Filled.AudioFile, "Import audio file") }
            IconButton(onClick = { showTrack = true }, modifier = Modifier.testTag("sample-from-track")) { Icon(Icons.Filled.LibraryMusic, "New sample from a track") }
            IconButton(onClick = { newFolder = true }, modifier = Modifier.testTag("sample-new-folder")) { Icon(Icons.Filled.CreateNewFolder, "New folder") }
        }
        HorizontalDivider()
        if (importing) Text("Importing…", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (folders.isEmpty() && inFolder.isEmpty() && folderId == null) {
            Text(
                "No samples yet. Record from the mic, import an audio file, or carve one from a track.",
                Modifier.padding(24.dp).testTag("samples-empty"), color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        LazyColumn(Modifier.fillMaxSize()) {
            if (folderId == null) {
                items(folders, key = { it.id }) { f ->
                    FolderRow(f, count = store.samples(f.id).size, onOpen = { folderId = f.id },
                        onRename = { store.renameFolder(StudioFolderKind.SAMPLE, f.id, it) },
                        onDelete = { store.deleteFolder(StudioFolderKind.SAMPLE, f.id) })
                }
            }
            items(inFolder, key = { it.id }) { s ->
                SampleRow(
                    s, folders,
                    onOpen = { editing = s.id },
                    onRename = { renaming = s },
                    onMove = { to -> store.setItemFolder(StudioFolderKind.SAMPLE, s.id, to) },
                    onNewFolderForMove = { moveNewFolderFor = s.id },
                    onDelete = { pendingDelete = s },
                )
                HorizontalDivider()
            }
        }
    }

    if (showMic) MicRecordSheet(graph, onDismiss = { showMic = false }, onFiled = { id -> if (folderId != null) store.setItemFolder(StudioFolderKind.SAMPLE, id, folderId) })
    if (showTrack) NewSampleFromTrackSheet(graph, onDismiss = { showTrack = false }, onFiled = { id ->
        if (folderId != null) store.setItemFolder(StudioFolderKind.SAMPLE, id, folderId)
        editing = id
    })
    editing?.let { id -> SampleEditorSheet(graph, id, onDismiss = { editing = null }) }
    if (newFolder) NameDialog("New folder", "", "Create", { newFolder = false }) { store.createFolder(StudioFolderKind.SAMPLE, it); newFolder = false }
    moveNewFolderFor?.let { sid ->
        NameDialog("New folder", "", "Create & move", { moveNewFolderFor = null }) {
            val f = store.createFolder(StudioFolderKind.SAMPLE, it); store.setItemFolder(StudioFolderKind.SAMPLE, sid, f.id); moveNewFolderFor = null
        }
    }
    renaming?.let { s -> NameDialog("Rename sample", s.name, "Rename", { renaming = null }) { store.renameSample(s.id, it); renaming = null } }
    pendingDelete?.let { s ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete sample?") },
            text = { Text(SamplesCopy.deleteMessage(s.name, store.referrers(s.id))) },
            confirmButton = { TextButton(onClick = { if (!store.deleteSample(s.id)) deleteBlocked = true; pendingDelete = null }, modifier = Modifier.testTag("sample-delete-confirm")) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }
    if (deleteBlocked) {
        AlertDialog(onDismissRequest = { deleteBlocked = false }, title = { Text("Folder unreachable") },
            text = { Text("This sample lives in your samples folder, which isn’t reachable right now. Reconnect the folder (Settings ▸ Storage) and try again — nothing was deleted.") },
            confirmButton = { TextButton(onClick = { deleteBlocked = false }) { Text("OK") } })
    }
    message?.let { m ->
        AlertDialog(onDismissRequest = { message = null }, title = { Text("Samples") }, text = { Text(m, Modifier.testTag("import-error")) },
            confirmButton = { TextButton(onClick = { message = null }) { Text("OK") } })
    }
}

@Composable
private fun SampleRow(
    s: StudioSample, folders: List<com.levi.pocketdj.studio.model.StudioFolder>,
    onOpen: () -> Unit, onRename: () -> Unit, onMove: (String?) -> Unit, onNewFolderForMove: () -> Unit, onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    var addTo by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(start = 16.dp, top = 8.dp, bottom = 8.dp).testTag("sample-${s.id}"), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(s.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Text(
                StudioFmt.mmssTenths(s.durationMs) + "  ·  " + sourceLabel(s) + (s.grid?.let { "  ·  ${StudioFmt.trim(it.bpm)} BPM" } ?: ""),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "Sample actions") }
            if (addTo) AddToCollectionSheet(item = AddToItem.Song(s.id), onDismiss = { addTo = false })
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Add to…") }, onClick = { menu = false; addTo = true }, modifier = Modifier.testTag("sample-add-to-${s.id}"))
                DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; onRename() })
                MoveToItems(folders, s.folderId, onMove = { menu = false; onMove(it) }, onNewFolder = { menu = false; onNewFolderForMove() })
                DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; onDelete() })
            }
        }
    }
}

/** Copy a SAF [uri] into the app cache (the decoder needs a path) and return it with its display name. */
private fun copyToCache(ctx: android.content.Context, uri: Uri): Pair<File, String> {
    val name = ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) c.getString(0) else null
    } ?: (uri.lastPathSegment ?: "Imported sample")
    val ext = name.substringAfterLast('.', "")
    val tmp = File.createTempFile("import-", if (ext.isNotEmpty()) ".$ext" else ".audio", ctx.cacheDir)
    ctx.contentResolver.openInputStream(uri)?.use { input -> tmp.outputStream().use { input.copyTo(it) } } ?: throw java.io.IOException("cannot open")
    return tmp to name
}

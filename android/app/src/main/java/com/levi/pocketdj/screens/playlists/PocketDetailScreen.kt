package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.PocketNote
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.SongDetailSheet

/**
 * Pocket detail (specs/playlists-ui.md §6): stats + resolution footer → Nested
 * pockets / Albums / Songs / Notes sections (move up/down + remove per row,
 * tap-to-edit notes) → ▶ Play / Shuffle over the DAG-resolved song order via
 * the reserved Now Playing setlist. Export / source-sync / rip-burn deferred.
 */
@Composable
fun PocketDetailScreen(
    pocketId: String,
    onOpenPocket: (pocketId: String) -> Unit,
    onOpenAlbum: (albumId: String) -> Unit,
    onOpenSetlist: (setlistId: String, autoplay: Boolean) -> Unit,
    onDeleted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store = remember { graph.collections }
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(Unit) {
        graph.catalogRepository.loadIfNeeded()
        graph.ripsRepository.loadAtLaunch()
    }

    val state by store.state.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val catalog = catalogState.catalog

    val pocket = state.pockets.firstOrNull { it.id == pocketId }

    var detailSongId by remember { mutableStateOf<String?>(null) }
    var renameOpen by remember { mutableStateOf(false) }
    var deleteOpen by remember { mutableStateOf(false) }
    var addNoteOpen by remember { mutableStateOf(false) }
    var editNote by remember { mutableStateOf<PocketNote?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        if (pocket == null) {
            Text(
                "Pocket gone",
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.align(Alignment.Center),
            )
            SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
            return@Box
        }

        val stats = store.statsForPocket(pocketId)

        fun playNow(shuffle: Boolean) {
            val set = store.playNowPocket(pocketId, shuffle = shuffle) ?: return
            onOpenSetlist(NOW_PLAYING_SETLIST_ID, true)
        }

        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item(key = "actions") {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Text(
                        pocket.name,
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.weight(1f),
                    )
                    Button(onClick = { playNow(false) }, enabled = stats.count > 0) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null)
                        Spacer(Modifier.width(4.dp))
                        Text("Play")
                    }
                    Spacer(Modifier.width(8.dp))
                    OutlinedButton(onClick = { playNow(true) }, enabled = stats.count > 0) {
                        Icon(Icons.Filled.Shuffle, contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                    OverflowMenu { dismiss ->
                        DropdownMenuItem(
                            text = { Text("Add note") },
                            onClick = { dismiss(); addNoteOpen = true },
                        )
                        DropdownMenuItem(
                            text = { Text("Rename…") },
                            onClick = { dismiss(); renameOpen = true },
                        )
                        DropdownMenuItem(
                            text = { Text("Delete pocket") },
                            onClick = { dismiss(); deleteOpen = true },
                        )
                    }
                }
                // Stats + resolution footer (§6.1).
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                ) {
                    Icon(
                        Icons.Filled.Layers,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        stats.summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                SectionCaption(
                    "Total resolved songs (own + album tracks + nested pockets, deduped). " +
                        "Runtime sums known track lengths.",
                )
                HorizontalDivider()
            }

            // Empty pocket (§6.1.6).
            if (pocket.isEmptyPocket) {
                item(key = "empty") {
                    SectionCaption(
                        "Empty. Add songs or albums from their detail view ▸ Add to…, " +
                            "or add a note below.",
                    )
                }
            }

            // 2. Nested pockets — hidden when none (§6.1.2).
            if (pocket.childPocketIds.isNotEmpty()) {
                item(key = "hdr-children") { SectionHeader("Nested pockets") }
                pocket.childPocketIds.forEachIndexed { index, childId ->
                    item(key = "child-$childId") {
                        val child = store.pocket(childId)
                        CollectionRow(
                            icon = Icons.Filled.Layers,
                            iconTint = MaterialTheme.colorScheme.primary,
                            name = child?.name ?: "(missing pocket)",
                            subtitle = child?.let { plural(it.memberCount, "item") },
                            onClick = { onOpenPocket(childId) },
                            trailing = {
                                OverflowMenu { dismiss ->
                                    DropdownMenuItem(
                                        text = { Text("Move up") },
                                        enabled = index > 0,
                                        onClick = {
                                            dismiss()
                                            store.movePocketChildren(pocketId, index, index - 1)
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Move down") },
                                        enabled = index < pocket.childPocketIds.lastIndex,
                                        onClick = {
                                            dismiss()
                                            store.movePocketChildren(pocketId, index, index + 1)
                                        },
                                    )
                                    // Removes the NESTING — the child pocket survives.
                                    DropdownMenuItem(
                                        text = { Text("Remove") },
                                        onClick = { dismiss(); store.removeChildPocket(childId, pocketId) },
                                    )
                                }
                            },
                        )
                    }
                }
            }

            // 3. Albums (n) (§6.1.3).
            if (pocket.albumIds.isNotEmpty()) {
                item(key = "hdr-albums") { SectionHeader("Albums (${pocket.albumIds.size})") }
                pocket.albumIds.forEachIndexed { index, albumId ->
                    item(key = "alb-$albumId") {
                        val album = catalog?.albumsById?.get(albumId)
                        CollectionRow(
                            icon = Icons.Filled.Album,
                            iconTint = MaterialTheme.colorScheme.secondary,
                            name = album?.name ?: "(missing album)",
                            subtitle = album?.artist,
                            onClick = { onOpenAlbum(albumId) },
                            trailing = {
                                OverflowMenu { dismiss ->
                                    DropdownMenuItem(
                                        text = { Text("Move up") },
                                        enabled = index > 0,
                                        onClick = {
                                            dismiss()
                                            store.movePocketAlbums(pocketId, index, index - 1)
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Move down") },
                                        enabled = index < pocket.albumIds.lastIndex,
                                        onClick = {
                                            dismiss()
                                            store.movePocketAlbums(pocketId, index, index + 1)
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Remove") },
                                        onClick = { dismiss(); store.removeAlbumFromPocket(albumId, pocketId) },
                                    )
                                }
                            },
                        )
                    }
                }
            }

            // 4. Songs (n) (§6.1.4) — Studio ids degrade to "(missing song)".
            if (pocket.songIds.isNotEmpty()) {
                item(key = "hdr-songs") { SectionHeader("Songs (${pocket.songIds.size})") }
                pocket.songIds.forEachIndexed { index, songId ->
                    item(key = "song-$songId") {
                        val song = catalog?.songsById?.get(songId)
                        val menu: @Composable androidx.compose.foundation.layout.ColumnScope.(() -> Unit) -> Unit =
                            { dismiss ->
                                DropdownMenuItem(
                                    text = { Text("Move up") },
                                    enabled = index > 0,
                                    onClick = {
                                        dismiss()
                                        store.movePocketSongs(pocketId, index, index - 1)
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Move down") },
                                    enabled = index < pocket.songIds.lastIndex,
                                    onClick = {
                                        dismiss()
                                        store.movePocketSongs(pocketId, index, index + 1)
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Remove") },
                                    onClick = { dismiss(); store.removeSongFromPocket(songId, pocketId) },
                                )
                            }
                        if (song == null || PlayResolver.isStudioId(songId)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                MissingItemRow(modifier = Modifier.weight(1f))
                                OverflowMenu(content = menu)
                            }
                        } else {
                            CollectionTrackRow(
                                title = song.name,
                                subtitle = song.artist,
                                album = song.albumId?.let { catalog.albumsById[it] },
                                bpm = song.bpm,
                                camelot = song.camelot,
                                lengthMs = song.length,
                                dimmed = !manifest.containsKey(songId),
                                onClick = { detailSongId = songId },
                                badges = {
                                    pocket.songRepeats[songId]?.takeIf { it > 1 }?.let {
                                        Spacer(Modifier.width(6.dp))
                                        CapsuleBadge("×$it")
                                    }
                                },
                                trailing = { OverflowMenu(content = menu) },
                            )
                        }
                    }
                }
            }

            // 5. Notes (n) — tap opens the edit dialog (§6.1.5).
            if (pocket.notes.isNotEmpty()) {
                item(key = "hdr-notes") { SectionHeader("Notes (${pocket.notes.size})") }
                pocket.notes.forEachIndexed { index, note ->
                    item(key = "note-${note.id}") {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "“${note.text}”",
                                style = MaterialTheme.typography.bodyMedium,
                                fontStyle = FontStyle.Italic,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .weight(1f)
                                    .clickable { editNote = note }
                                    .padding(horizontal = 16.dp, vertical = 8.dp),
                            )
                            OverflowMenu { dismiss ->
                                DropdownMenuItem(
                                    text = { Text("Move up") },
                                    enabled = index > 0,
                                    onClick = {
                                        dismiss()
                                        store.movePocketNotes(pocketId, index, index - 1)
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Move down") },
                                    enabled = index < pocket.notes.lastIndex,
                                    onClick = {
                                        dismiss()
                                        store.movePocketNotes(pocketId, index, index + 1)
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Remove") },
                                    onClick = { dismiss(); store.removeNoteFromPocket(note.id, pocketId) },
                                )
                            }
                        }
                    }
                }
            }
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

    // ---- dialogs -----------------------------------------------------------

    detailSongId?.let { songId ->
        SongDetailSheet(
            songId = songId,
            onDismiss = { detailSongId = null },
            snackbar = snackbar,
            onOpenAlbum = onOpenAlbum,
        )
    }

    if (renameOpen) {
        NameDialog(
            title = "Rename pocket",
            confirmLabel = "Rename",
            initial = pocket?.name.orEmpty(),
            onDismiss = { renameOpen = false },
            onConfirm = { store.renamePocket(pocketId, it) },
        )
    }

    if (addNoteOpen) {
        NameDialog(
            title = "Add note",
            confirmLabel = "Add",
            placeholder = "Note",
            onDismiss = { addNoteOpen = false },
            onConfirm = { store.addNoteToPocket(it, pocketId) },
        )
    }

    editNote?.let { note ->
        // Edit-note dialog: Save / Remove / Cancel; saving empty removes (§6.1.5).
        NoteEditDialog(
            initial = note.text,
            onDismiss = { editNote = null },
            onSave = { text ->
                if (text.isBlank()) {
                    store.removeNoteFromPocket(note.id, pocketId)
                } else {
                    store.setNoteText(note.id, text.trim(), pocketId)
                }
            },
            onRemove = { store.removeNoteFromPocket(note.id, pocketId) },
        )
    }

    if (deleteOpen) {
        ConfirmDialog(
            title = "Delete this pocket?",
            text = "Removes the pocket and unnests it from any parent. Its items aren't deleted. " +
                "This can't be undone.",
            confirmLabel = "Delete",
            onDismiss = { deleteOpen = false },
            onConfirm = {
                store.deletePocket(pocketId)
                onDeleted()
            },
        )
    }
}

@Composable
private fun NoteEditDialog(
    initial: String,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
    onRemove: () -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit note") },
        text = {
            androidx.compose.material3.OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            androidx.compose.material3.TextButton(
                onClick = {
                    onDismiss()
                    onSave(text)
                },
            ) { Text("Save") }
        },
        dismissButton = {
            Row {
                androidx.compose.material3.TextButton(
                    onClick = {
                        onDismiss()
                        onRemove()
                    },
                ) { Text("Remove", color = MaterialTheme.colorScheme.error) }
                androidx.compose.material3.TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

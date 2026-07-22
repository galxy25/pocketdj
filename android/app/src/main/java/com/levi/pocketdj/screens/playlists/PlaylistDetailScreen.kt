package com.levi.pocketdj.screens.playlists

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
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.GraphicEq
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
import androidx.compose.material3.TextButton
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
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.Fmt
import com.levi.pocketdj.screens.browse.SongDetailSheet

/**
 * Playlist detail (specs/playlists-ui.md §5): stats row → one section per
 * chapter (node rows with move-up/down + remove, add-note / rename-chapter /
 * delete-chapter actions) → "Set lists" section (frozen takes) → action row
 * with ▶ Play / Shuffle (→ the reserved Now Playing setlist, autostarting) and
 * the ⋯ overflow (Make set list, Add chapter, Rename, Convert to pocket,
 * Delete). Export / rip-burn / source-sync are P2-deferred (§13).
 */
@Composable
fun PlaylistDetailScreen(
    playlistId: String,
    onOpenSetlist: (setlistId: String, autoplay: Boolean) -> Unit,
    onOpenPocket: (pocketId: String) -> Unit,
    onOpenAlbum: (albumId: String) -> Unit,
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

    val playlist = state.playlists.firstOrNull { it.id == playlistId }

    var detailSongId by remember { mutableStateOf<String?>(null) }
    var renameOpen by remember { mutableStateOf(false) }
    var deleteOpen by remember { mutableStateOf(false) }
    var addChapterOpen by remember { mutableStateOf(false) }
    var noteChapterId by remember { mutableStateOf<String?>(null) }
    var renameChapter by remember { mutableStateOf<PlaylistNode?>(null) }
    var renameSetlist by remember { mutableStateOf<Pair<String, String?>?>(null) }
    var deleteSetlistId by remember { mutableStateOf<String?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        if (playlist == null) {
            Text(
                "Playlist gone",
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.align(Alignment.Center),
            )
            SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
            return@Box
        }

        val stats = store.statsForPlaylist(playlistId)
        val itemCount = playlist.sequences.sumOf { it.children?.size ?: 0 }
        val setlists = store.setlistsForPlaylist(playlistId)

        fun playNow(shuffle: Boolean) {
            // Literal resolved order (or shuffled), upserts the reserved Now
            // Playing setlist, stamps lastPlayedAt, opens NP autostarting (§5.4).
            val set = store.playNowPlaylist(playlistId, shuffle = shuffle)
            if (set == null) {
                // catalog not wired yet
                return
            }
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
                        playlist.name,
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.weight(1f),
                    )
                    Button(onClick = { playNow(false) }, enabled = itemCount > 0) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null)
                        Spacer(Modifier.width(4.dp))
                        Text("Play")
                    }
                    Spacer(Modifier.width(8.dp))
                    OutlinedButton(onClick = { playNow(true) }, enabled = itemCount > 0) {
                        Icon(Icons.Filled.Shuffle, contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                    OverflowMenu { dismiss ->
                        DropdownMenuItem(
                            text = { Text("Make set list") },
                            enabled = itemCount > 0,
                            onClick = {
                                dismiss()
                                // Realize → frozen take, open WITHOUT autoplay (§11.2).
                                store.realize(playlistId)?.let { onOpenSetlist(it.id, false) }
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Add chapter") },
                            onClick = { dismiss(); addChapterOpen = true },
                        )
                        DropdownMenuItem(
                            text = { Text("Rename…") },
                            onClick = { dismiss(); renameOpen = true },
                        )
                        DropdownMenuItem(
                            text = { Text("Convert to pocket") },
                            onClick = {
                                dismiss()
                                store.convertPlaylistToPocket(playlistId)?.let { onOpenPocket(it.id) }
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Delete playlist") },
                            onClick = { dismiss(); deleteOpen = true },
                        )
                    }
                }
                // Stats row (§5.1).
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.QueueMusic,
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
                HorizontalDivider(Modifier.padding(top = 8.dp))
            }

            // One section per chapter (§5.1–§5.3).
            playlist.sequences.forEachIndexed { seqIndex, chapter ->
                item(key = "ch-${chapter.nodeId}") {
                    SectionHeader(
                        chapter.name ?: "Chapter",
                        trailing = store.statsForChapter(chapter).summary,
                    )
                }
                val children = chapter.children.orEmpty()
                if (children.isEmpty()) {
                    item(key = "ch-empty-${chapter.nodeId}") {
                        SectionCaption("Empty chapter — add items from a song/album ▸ Add to…")
                    }
                }
                children.forEachIndexed { index, node ->
                    item(key = "nd-${node.nodeId}") {
                        NodeRow(
                            node = node,
                            catalog = catalog,
                            pocketName = { store.pocket(it)?.name },
                            manifestHit = node.songId?.let { manifest.containsKey(it) } ?: false,
                            onTapSong = { detailSongId = it },
                            onOpenAlbum = onOpenAlbum,
                            onOpenPocket = onOpenPocket,
                            menu = { dismiss ->
                                DropdownMenuItem(
                                    text = { Text("Move up") },
                                    enabled = index > 0,
                                    onClick = { dismiss(); store.moveNodeUp(node.nodeId, playlistId) },
                                )
                                DropdownMenuItem(
                                    text = { Text("Move down") },
                                    enabled = index < children.lastIndex,
                                    onClick = { dismiss(); store.moveNodeDown(node.nodeId, playlistId) },
                                )
                                DropdownMenuItem(
                                    text = { Text("Remove") },
                                    onClick = { dismiss(); store.removeNode(node.nodeId, playlistId) },
                                )
                            },
                        )
                    }
                }
                item(key = "ch-actions-${chapter.nodeId}") {
                    Row(modifier = Modifier.padding(horizontal = 8.dp)) {
                        TextButton(onClick = { noteChapterId = chapter.nodeId }) { Text("Add note") }
                        TextButton(onClick = { renameChapter = chapter }) { Text("Rename chapter") }
                        // The last chapter can't be deleted (§5.3).
                        if (playlist.sequences.size > 1) {
                            TextButton(
                                onClick = { store.removeSequence(chapter.nodeId, playlistId) },
                            ) { Text("Delete chapter", color = MaterialTheme.colorScheme.error) }
                        }
                    }
                    if (seqIndex < playlist.sequences.lastIndex) HorizontalDivider()
                }
            }

            // "Set lists" — hidden when none; NP setlist never listed (§5.1).
            if (setlists.isNotEmpty()) {
                item(key = "hdr-setlists") { SectionHeader("Set lists") }
                setlists.forEach { sl ->
                    item(key = "sl-${sl.id}") {
                        val trackCount = sl.tracks.count { it.isText != true }
                        CollectionRow(
                            icon = Icons.Filled.GraphicEq,
                            iconTint = MaterialTheme.colorScheme.tertiary,
                            name = sl.name ?: "Set list",
                            subtitle = "${plural(trackCount, "track")} · ${Fmt.duration(sl.totalMs)}" +
                                " · ${dateLabel(sl.generatedAt)}",
                            onClick = { onOpenSetlist(sl.id, false) },
                            trailing = {
                                OverflowMenu { dismiss ->
                                    DropdownMenuItem(
                                        text = { Text("Rename") },
                                        onClick = { dismiss(); renameSetlist = sl.id to sl.name },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Delete") },
                                        onClick = { dismiss(); deleteSetlistId = sl.id },
                                    )
                                }
                            },
                        )
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
            title = "Rename playlist",
            confirmLabel = "Rename",
            initial = playlist?.name.orEmpty(),
            onDismiss = { renameOpen = false },
            onConfirm = { store.renamePlaylist(playlistId, it) },
        )
    }

    if (addChapterOpen) {
        NameDialog(
            title = "Add chapter",
            confirmLabel = "Add",
            onDismiss = { addChapterOpen = false },
            onConfirm = { store.addSequence(it, playlistId) },
        )
    }

    noteChapterId?.let { chapterId ->
        NameDialog(
            title = "Add note",
            confirmLabel = "Add",
            placeholder = "Note",
            onDismiss = { noteChapterId = null },
            onConfirm = { store.addTextToPlaylist(it, playlistId, chapterId) },
        )
    }

    renameChapter?.let { chapter ->
        NameDialog(
            title = "Rename chapter",
            confirmLabel = "Rename",
            initial = chapter.name.orEmpty(),
            onDismiss = { renameChapter = null },
            onConfirm = { store.renameSequence(chapter.nodeId, it, playlistId) },
        )
    }

    renameSetlist?.let { (id, current) ->
        NameDialog(
            title = "Rename set list",
            confirmLabel = "Rename",
            initial = current.orEmpty(),
            onDismiss = { renameSetlist = null },
            onConfirm = { store.renameSetlist(id, it) },
        )
    }

    deleteSetlistId?.let { id ->
        ConfirmDialog(
            title = "Delete this set list?",
            text = "This can't be undone.",
            confirmLabel = "Delete",
            onDismiss = { deleteSetlistId = null },
            onConfirm = { store.deleteSetlist(id) },
        )
    }

    if (deleteOpen) {
        ConfirmDialog(
            title = "Delete this playlist?",
            text = "This also deletes its set lists. This can't be undone.",
            confirmLabel = "Delete",
            onDismiss = { deleteOpen = false },
            onConfirm = {
                store.deletePlaylist(playlistId)
                onDeleted()
            },
        )
    }
}

/** One template node row (§5.2) with the shared per-row actions menu. */
@Composable
private fun NodeRow(
    node: PlaylistNode,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
    pocketName: (String) -> String?,
    manifestHit: Boolean,
    onTapSong: (String) -> Unit,
    onOpenAlbum: (String) -> Unit,
    onOpenPocket: (String) -> Unit,
    menu: @Composable androidx.compose.foundation.layout.ColumnScope.(dismiss: () -> Unit) -> Unit,
) {
    when (node.kind) {
        PlaylistNode.Kind.SONG -> {
            val songId = node.songId
            val song = songId?.let { catalog?.songsById?.get(it) }
            if (song == null || (songId != null && PlayResolver.isStudioId(songId))) {
                // Unresolvable + Studio ids degrade honestly (§5.2).
                Row(verticalAlignment = Alignment.CenterVertically) {
                    MissingItemRow(modifier = Modifier.weight(1f))
                    OverflowMenu(content = menu)
                }
            } else {
                CollectionTrackRow(
                    title = song.name,
                    subtitle = song.artist,
                    album = song.albumId?.let { catalog?.albumsById?.get(it) },
                    bpm = song.bpm,
                    camelot = song.camelot,
                    lengthMs = song.length,
                    dimmed = !manifestHit,
                    onClick = { onTapSong(song.id) },
                    badges = {
                        node.repeatCount?.takeIf { it > 1 }?.let {
                            Spacer(Modifier.width(6.dp))
                            CapsuleBadge("×$it")
                        }
                    },
                    trailing = { OverflowMenu(content = menu) },
                )
            }
        }

        PlaylistNode.Kind.ALBUM -> {
            val album = node.albumId?.let { catalog?.albumsById?.get(it) }
            CollectionRow(
                icon = Icons.Filled.Album,
                iconTint = MaterialTheme.colorScheme.secondary,
                name = album?.name ?: "(missing album)",
                subtitle = album?.artist,
                onClick = { node.albumId?.let(onOpenAlbum) },
                trailing = { OverflowMenu(content = menu) },
            )
        }

        PlaylistNode.Kind.POCKET -> {
            CollectionRow(
                icon = Icons.Filled.Layers,
                iconTint = MaterialTheme.colorScheme.primary,
                // Pocket names come from the collections doc, not the catalog.
                name = node.pocketId?.let(pocketName) ?: "(missing pocket)",
                subtitle = "Pocket",
                onClick = { node.pocketId?.let(onOpenPocket) },
                trailing = { OverflowMenu(content = menu) },
            )
        }

        PlaylistNode.Kind.TEXT -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "“${node.text.orEmpty()}”",
                    style = MaterialTheme.typography.bodyMedium,
                    fontStyle = FontStyle.Italic,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
                OverflowMenu(content = menu)
            }
        }

        PlaylistNode.Kind.SEQUENCE -> {
            // Display-only indented sub-chapter label (§5.2).
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    node.name ?: "Sub-chapter",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 32.dp, top = 6.dp, bottom = 6.dp),
                )
                OverflowMenu(content = menu)
            }
        }
    }
}

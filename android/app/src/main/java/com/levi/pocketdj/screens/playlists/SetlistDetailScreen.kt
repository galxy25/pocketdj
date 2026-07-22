package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.SetlistTrack
import com.levi.pocketdj.data.collections.TrackSource
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.QueueOutcome
import com.levi.pocketdj.screens.browse.Fmt
import com.levi.pocketdj.screens.browse.SongDetailSheet
import kotlinx.coroutines.launch

/**
 * Setlist detail (specs/playlists-ui.md §7) — the frozen, ordered performance
 * ("Spin these tracks, in this order"). Rows render from the SNAPSHOT (catalog
 * lookup only for art / tap-through), cue rows get a "cue" badge, provenance
 * badges mark pocket/autofill tracks, and the transport drives ONE Media3 queue
 * (manifest hits only — skipped rows surface a count line). Reorder/remove are
 * LOCKED while this set's queue is loaded (queue-index desync guard).
 *
 * [autoplay]/[autoplayKey]: the ▶ Play / Shuffle funnels open this screen
 * autostarting; a bumped key restarts the run on re-tap (iOS re-snapshot
 * semantics without pushing a second screen).
 */
@Composable
fun SetlistDetailScreen(
    setlistId: String,
    autoplay: Boolean = false,
    autoplayKey: Int = 0,
    onDeleted: () -> Unit = {},
    onOpenAlbum: ((albumId: String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store = remember { graph.collections }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(Unit) {
        graph.catalogRepository.loadIfNeeded()
        graph.ripsRepository.loadAtLaunch()
    }

    val state by store.state.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val nowPlaying by graph.playbackController.nowPlaying.collectAsState()
    val catalog = catalogState.catalog

    val setlist = state.setlists.firstOrNull { it.id == setlistId }

    var detailSongId by remember { mutableStateOf<String?>(null) }
    var renameOpen by remember { mutableStateOf(false) }
    var deleteOpen by remember { mutableStateOf(false) }
    var addNoteOpen by remember { mutableStateOf(false) }
    var noteTrackIndex by remember { mutableStateOf<Int?>(null) }
    var lastSkippedSummary by remember { mutableStateOf<String?>(null) }

    // Source-aware transport (§7.2): this screen owns the transport only when
    // the loaded queue run is THIS setlist (contextId = the run's setlist id).
    val isThisRun = nowPlaying?.context?.contextId == setlistId
    val isPlaying = isThisRun && nowPlaying?.isPlaying == true
    // Reorder/remove lock while this set's queue is loaded — even paused,
    // editing would desync Media3 indices (§7.1, risk 5).
    val locked = isThisRun

    suspend fun start() {
        val sl = store.setlist(setlistId) ?: return
        // Starting a set stamps markPlayed on its ORIGIN playlist (the reserved
        // NP set was already stamped by its playNow funnel) (§7.2).
        if (setlistId != NOW_PLAYING_SETLIST_ID) {
            store.playlist(sl.playlistId)?.let { store.markPlaylistPlayed(it.id) }
        }
        val ctx = store.historyContext(setlistId)
        when (val outcome = graph.playbackController.playSetlist(sl, ctx)) {
            is QueueOutcome.Started -> {
                lastSkippedSummary = if (outcome.skippedEntryCount == 0) {
                    null
                } else {
                    "Playing ${outcome.playableEntryCount} of ${outcome.requestedEntryCount} — " +
                        "${outcome.skippedEntryCount} not playable on Android"
                }
            }
            is QueueOutcome.NothingPlayable ->
                snackbar.showSnackbar("None of these tracks are playable on this device yet")
            is QueueOutcome.Failed -> snackbar.showSnackbar(outcome.message)
        }
    }

    // The ▶/🔀 funnels open this screen autostarting; a bumped key restarts.
    LaunchedEffect(autoplayKey) {
        if (autoplay) start()
    }

    Box(modifier = modifier.fillMaxSize()) {
        if (setlist == null) {
            // Deleted behind the screen (§7.1).
            Text(
                "Set list gone",
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.align(Alignment.Center),
            )
            SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
            return@Box
        }

        val playableTracks = setlist.tracks.filter { it.isText != true && it.songId.isNotEmpty() }
        val unplayableCount = playableTracks.count { !manifest.containsKey(it.songId) }
        val chapterLegend = setlist.tracks
            .mapNotNull { it.sequenceName }
            .distinct()
            .joinToString(" · ")

        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item(key = "header") {
                Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Filled.GraphicEq,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.tertiary,
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            setlist.name ?: "Set list",
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        // Transport (§7.2): idle = ▶ + ⋯; running = ⏮ ⏯ ⏭ + ⋯.
                        if (isThisRun) {
                            IconButton(onClick = { scope.launch { graph.playbackController.previous() } }) {
                                Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous track")
                            }
                            FilledIconButton(
                                onClick = {
                                    scope.launch {
                                        if (isPlaying) {
                                            graph.playbackController.pause()
                                        } else {
                                            graph.playbackController.resume()
                                        }
                                    }
                                },
                            ) {
                                Icon(
                                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                                    contentDescription = if (isPlaying) "Pause" else "Resume",
                                )
                            }
                            IconButton(onClick = { scope.launch { graph.playbackController.next() } }) {
                                Icon(Icons.Filled.SkipNext, contentDescription = "Next track")
                            }
                        } else {
                            Button(
                                onClick = { scope.launch { start() } },
                                enabled = playableTracks.isNotEmpty(),
                            ) {
                                Icon(Icons.Filled.PlayArrow, contentDescription = null)
                                Spacer(Modifier.width(4.dp))
                                Text("Play")
                            }
                        }
                        OverflowMenu { dismiss ->
                            // Appends a cue to the END (§7.2).
                            DropdownMenuItem(
                                text = { Text("Add note") },
                                onClick = { dismiss(); addNoteOpen = true },
                            )
                            DropdownMenuItem(
                                text = { Text("Rename") },
                                onClick = { dismiss(); renameOpen = true },
                            )
                            DropdownMenuItem(
                                text = { Text("Delete set list") },
                                enabled = !locked,
                                onClick = { dismiss(); deleteOpen = true },
                            )
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Spin these tracks, in this order",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontStyle = FontStyle.Italic,
                    )
                    Text(
                        "${Fmt.duration(setlist.totalMs)} · " +
                            "${plural(playableTracks.size, "track")} · ${dateLabel(setlist.generatedAt)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (chapterLegend.isNotEmpty()) {
                        Text(
                            chapterLegend,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    // Unplayable presentation (§7.2 Android queue policy).
                    val skipLine = lastSkippedSummary
                        ?: unplayableCount.takeIf { it > 0 }?.let { "$it not playable on Android" }
                    skipLine?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }
                HorizontalDivider()
            }

            setlist.tracks.forEachIndexed { index, track ->
                item(key = "row-$index-${track.rowId}") {
                    SetlistTrackRow(
                        rowNumber = index + 1,
                        track = track,
                        catalog = catalog,
                        dimmed = track.isText != true && !manifest.containsKey(track.songId),
                        locked = locked,
                        onTap = {
                            if (track.isText != true && catalog?.songsById?.containsKey(track.songId) == true) {
                                detailSongId = track.songId
                            }
                        },
                        onNote = { noteTrackIndex = index },
                        onMoveUp = if (index > 0) {
                            { store.moveSetlistTrack(setlistId, index, index - 1) }
                        } else {
                            null
                        },
                        onMoveDown = if (index < setlist.tracks.lastIndex) {
                            { store.moveSetlistTrack(setlistId, index, index + 1) }
                        } else {
                            null
                        },
                        onRemove = { store.removeSetlistTrack(setlistId, index) },
                    )
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
            title = "Rename set list",
            confirmLabel = "Rename",
            initial = setlist?.name.orEmpty(),
            onDismiss = { renameOpen = false },
            onConfirm = { store.renameSetlist(setlistId, it) },
        )
    }

    if (addNoteOpen) {
        NameDialog(
            title = "Add note",
            confirmLabel = "Add",
            placeholder = "Cue text",
            onDismiss = { addNoteOpen = false },
            onConfirm = { store.addSetlistNote(it, setlistId) },
        )
    }

    noteTrackIndex?.let { index ->
        val current = setlist?.tracks?.getOrNull(index)?.note.orEmpty()
        TrackNoteDialog(
            initial = current,
            onDismiss = { noteTrackIndex = null },
            onSave = { text ->
                store.setSetlistTrackNote(setlistId, index, text.trim().ifEmpty { null })
            },
            onClear = { store.setSetlistTrackNote(setlistId, index, null) },
        )
    }

    if (deleteOpen) {
        ConfirmDialog(
            title = "Delete this set list?",
            text = "This can't be undone.",
            confirmLabel = "Delete",
            onDismiss = { deleteOpen = false },
            onConfirm = {
                store.deleteSetlist(setlistId)
                onDeleted()
            },
        )
    }
}

/**
 * One frozen row (§7.1): row number · snapshot-fed content (art via catalog
 * lookup only) · provenance/chapter badges · per-track note button. Cue rows
 * (isText) are numbered, badged "cue", italic, no audio.
 */
@Composable
private fun SetlistTrackRow(
    rowNumber: Int,
    track: SetlistTrack,
    catalog: com.levi.pocketdj.data.catalog.MergedCatalog?,
    dimmed: Boolean,
    locked: Boolean,
    onTap: () -> Unit,
    onNote: () -> Unit,
    onMoveUp: (() -> Unit)?,
    onMoveDown: (() -> Unit)?,
    onRemove: () -> Unit,
) {
    val menu: @Composable androidx.compose.foundation.layout.ColumnScope.(dismiss: () -> Unit) -> Unit =
        { dismiss ->
            DropdownMenuItem(
                text = { Text("Move up") },
                enabled = !locked && onMoveUp != null,
                onClick = { dismiss(); onMoveUp?.invoke() },
            )
            DropdownMenuItem(
                text = { Text("Move down") },
                enabled = !locked && onMoveDown != null,
                onClick = { dismiss(); onMoveDown?.invoke() },
            )
            DropdownMenuItem(
                text = { Text("Remove") },
                enabled = !locked,
                onClick = { dismiss(); onRemove() },
            )
        }

    if (track.isText == true) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                rowNumber.toString(),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .padding(start = 12.dp)
                    .width(26.dp),
            )
            CapsuleBadge("cue")
            Spacer(Modifier.width(8.dp))
            Text(
                track.name,
                style = MaterialTheme.typography.bodyMedium,
                fontStyle = FontStyle.Italic,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .padding(vertical = 8.dp),
            )
            OverflowMenu(content = menu)
        }
        return
    }

    Column {
        val song = catalog?.songsById?.get(track.songId)
        val album = song?.albumId?.let { catalog.albumsById[it] }
        CollectionTrackRow(
            title = track.name,
            subtitle = track.artist,
            album = album,
            bpm = track.bpm,
            camelot = track.camelot,
            lengthMs = track.lengthMs,
            dimmed = dimmed,
            onClick = onTap,
            leading = {
                Text(
                    rowNumber.toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(26.dp),
                )
            },
            badges = {
                // Provenance badges (§7.1): pocket / ↔ bridge; nothing explicit.
                when (track.source) {
                    TrackSource.POCKET -> {
                        Spacer(Modifier.width(6.dp))
                        CapsuleBadge("pocket")
                    }
                    TrackSource.AUTOFILL -> {
                        Spacer(Modifier.width(6.dp))
                        CapsuleBadge("↔ bridge")
                    }
                    TrackSource.EXPLICIT -> Unit
                }
                // Chapter badge for a real named chapter (not "Default").
                track.sequenceName?.takeIf { it.isNotEmpty() && it != "Default" }?.let {
                    Spacer(Modifier.width(6.dp))
                    CapsuleBadge(it)
                }
                track.repeatCount?.takeIf { it > 1 }?.let {
                    Spacer(Modifier.width(6.dp))
                    CapsuleBadge("×$it")
                }
            },
            trailing = { OverflowMenu(content = menu) },
        )
        // Per-track performer note (§7.1).
        TextButton(
            onClick = onNote,
            modifier = Modifier.padding(start = 44.dp),
        ) {
            Text(
                if (track.note.isNullOrBlank()) "＋ note" else "📝 ${track.note}",
                style = MaterialTheme.typography.labelSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun TrackNoteDialog(
    initial: String,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
    onClear: () -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Track note") },
        text = {
            androidx.compose.material3.OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = {
                    onDismiss()
                    onSave(text)
                },
            ) { Text("Save") }
        },
        dismissButton = {
            Row {
                TextButton(
                    onClick = {
                        onDismiss()
                        onClear()
                    },
                ) { Text("Clear") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

package com.levi.pocketdj.screens.playlists

import com.levi.pocketdj.data.collections.SongTransfer
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.ui.selection.SelectionBar
import com.levi.pocketdj.ui.selection.SelectionScope
import com.levi.pocketdj.ui.selection.SongTransfer
import com.levi.pocketdj.ui.selection.selectableRow
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.screens.browse.SongDetailSheet
import androidx.compose.runtime.produceState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch

/**
 * Read-only source playlist detail (specs/playlists-ui.md §4): action rows
 * (▶ Play → NEW frozen setlist without autostart · Shuffle → in-place Now
 * Playing autostarting · find-or-create Duplicate/Open editable copy · Convert
 * to pocket) + resolved-count footer + song rows. Membership is read-only;
 * duplicates are provenance-stamped for the future sync engine. Rip/Burn
 * deferred (§13).
 */
@Composable
fun SourcePlaylistDetailScreen(
    playlistId: String,
    sourceName: String,
    onOpenSetlist: (setlistId: String, autoplay: Boolean) -> Unit,
    onOpenPlaylist: (playlistId: String) -> Unit,
    onOpenPocket: (pocketId: String) -> Unit,
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

    // Observe the collections state so the Duplicate/Open row relabels live.
    val collectionsState by store.state.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val catalog = catalogState.catalog

    // Source ids are unique only within a source namespace — match BOTH (§8.4).
    val isRecentlyAdded = playlistId == com.levi.pocketdj.data.collections.RecentlyAdded.PLAYLIST_ID
    val recentlyLimit by remember {
        graph.settings.flow(com.levi.pocketdj.data.settings.ShellSettings.DEFAULT_RECENTLY_ADDED_COUNT)
            .map { com.levi.pocketdj.data.settings.ShellSettings.clampRecentlyAdded(it) }
    }.collectAsState(initial = com.levi.pocketdj.data.settings.ShellSettings.RECENTLY_ADDED_DEFAULT)
    val activityState by graph.collectionActivity.state.collectAsState()
    // The virtual "Recently added" playlist is derived off-main (memoized), never in the body.
    // `derived` distinguishes "still deriving" from "derived, empty" so we never flash "not found".
    var virtualDerived by remember { mutableStateOf(false) }
    val virtualSource by produceState<com.levi.pocketdj.data.catalog.SourcePlaylist?>(
        initialValue = null, catalog, activityState.revision, recentlyLimit, isRecentlyAdded,
    ) {
        virtualDerived = false
        value = if (!isRecentlyAdded || catalog == null) null else withContext(Dispatchers.Default) {
            graph.collectionsGraph.recentlyAdded.playlist(catalog, activityState.events, recentlyLimit)
        }
        virtualDerived = true
    }
    val virtualLoading = isRecentlyAdded && catalog != null && !virtualDerived
    val source = if (isRecentlyAdded) virtualSource else catalog?.playlists?.firstOrNull {
        it.playlist.id == playlistId && it.sourceName == sourceName
    }

    var detailSongId by remember { mutableStateOf<String?>(null) }
    // COL-13: per-collection sort/filter (key pdj.collection.<id>), independent of the Browse session.
    val sortState = rememberCollectionSortState("source:$sourceName:$playlistId")
    val playCountOf = rememberPlayCountOf()
    var showSort by remember { mutableStateOf(false) }
    var showFilter by remember { mutableStateOf(false) }

    Box(modifier = modifier.fillMaxSize()) {
        if (source == null || catalog == null) {
            Text(
                if (catalog == null) "Loading catalog…" else if (virtualLoading) "Loading…" else "Source playlist not found",
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.align(Alignment.Center),
            )
            SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
            return@Box
        }

        val songIds = source.playlist.songIds
        val resolvedCount = songIds.count { catalog.songsById.containsKey(it) }
        // Relabel instead of minting a rival copy (§4, risk 6).
        val existingCopy = collectionsState.playlists.firstOrNull {
            it.sourcePlaylistId == playlistId && (it.sourceName == sourceName || it.sourceName == null)
        }

        val rowSelection = remember { graph.collectionsGraph.rowSelection }
        val selScope = "source:$sourceName:$playlistId"
        // Rows are keyed by SONG id (as iOS); a repeat gets an occurrence suffix so keys stay
        // unique, and a reorder never moves the selection onto different songs.
        val rowKeys = com.levi.pocketdj.ui.selection.stableKeys(songIds)
        // Sorted/filtered display order, resolved OFF-main; keyed on the stored ids + inputs + catalog.
        // Null = not resolved yet (skeleton-free: show the stored rows' count honestly as loading).
        val inputs = sortState.inputs
        val readTime = rememberCollectionReadTime(inputs)
        val displayed by produceState<List<String>?>(
            initialValue = null, songIds, inputs, catalog, readTime,
        ) {
            value = if (inputs.isDefaultOrder) null else withContext(Dispatchers.Default) {
                CollectionSortFilter.resolveSongIds(songIds, catalog, inputs, playCountOf, readTime)
            }
        }
        val displayedIds: List<String>? = if (inputs.isDefaultOrder) null else displayed
        // Selection acts on what is DISPLAYED (resolved order while sorted/filtered); keys follow the rows.
        val selIds: List<String> = displayedIds ?: if (inputs.isDefaultOrder) songIds else emptyList()
        val selKeys = if (displayedIds != null) com.levi.pocketdj.ui.selection.stableKeys(selIds) else rowKeys
        fun selectableIds() = selIds.indices.filter {
            catalog.songsById.containsKey(selIds[it]) && !PlayResolver.isStudioId(selIds[it])
        }.map { selKeys[it] }
        SelectionScope(
            selection = rowSelection,
            scope = selScope,
            pruneKey = listOf(songIds, displayedIds),
            allIds = { selectableIds() },
            payload = {
                SongTransfer.make(
                    rowSelection.orderedSelection(selectableIds()).mapNotNull { k ->
                        selKeys.indexOf(k).takeIf { it >= 0 }?.let { selIds[it] }
                    },
                    catalog.songsById,
                )
            },
        )

        Column(Modifier.fillMaxSize()) {
        SelectionBar(rowSelection, selScope, store)
        LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth()) {
            item(key = "title") {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Text(
                        source.playlist.name,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    CapsuleBadge(sourceName)
                    CollectionSortFilterButtons(
                        sortState,
                        onSort = { showSort = true },
                        onFilter = { showFilter = true },
                    )
                }
            }

            item(key = "actions") {
                ActionRow(
                    icon = Icons.Filled.PlayArrow,
                    label = "Play",
                    enabled = resolvedCount > 0,
                ) {
                    // ▶ Play: realize songIds → NEW persisted transient setlist,
                    // open its detail WITHOUT autostart (§4).
                    store.realize(songIds, source.playlist.name)?.let {
                        onOpenSetlist(it.id, false)
                    }
                }
                ActionRow(
                    icon = Icons.Filled.Shuffle,
                    label = "Shuffle",
                    enabled = resolvedCount > 0,
                ) {
                    // In-place shuffle-play WITHOUT duplicating (§4).
                    val set = store.playNow(
                        songIds = songIds,
                        name = source.playlist.name,
                        shuffle = true,
                        sourceToken = PlayContext.SOURCE_PLAYLIST,
                        originId = source.playlist.id,
                    )
                    if (set != null) onOpenSetlist(NOW_PLAYING_SETLIST_ID, true)
                }
                if (existingCopy != null) {
                    ActionRow(
                        icon = Icons.Filled.OpenInNew,
                        label = "Open editable copy",
                        enabled = true,
                    ) { onOpenPlaylist(existingCopy.id) }
                } else {
                    ActionRow(
                        icon = Icons.Filled.Edit,
                        label = "Duplicate as editable playlist",
                        enabled = true,
                    ) {
                        // The ONE find-or-create primitive (§4, risk 6).
                        val copy = store.duplicateForSource(source)
                        onOpenPlaylist(copy.id)
                    }
                }
                ActionRow(
                    icon = Icons.Filled.Layers,
                    label = "Convert to pocket",
                    enabled = true,
                ) {
                    val pocket = store.convertSourceToPocket(source)
                    onOpenPocket(pocket.id)
                }
                // Footer: resolution honesty (§4).
                SectionCaption(
                    "$resolvedCount of ${plural(songIds.size, "song")} resolved from $sourceName.",
                )
                HorizontalDivider()
            }

            item(key = "hdr-songs") { SectionHeader("Songs") }
            if (!inputs.isDefaultOrder && displayedIds == null) {
                item(key = "resolving") { SectionCaption("Sorting…") }
            } else if (displayedIds != null && displayedIds.isEmpty()) {
                item(key = "no-match") { SectionCaption("No songs match the filter.") }
            }
            // Default order: the stored list (missing / Studio rows degrade honestly). Sorted or
            // filtered: only catalog songs, in pipeline order; the stored list is never mutated.
            val shownIds: List<String> = displayedIds ?: if (inputs.isDefaultOrder) songIds else emptyList()
            val shownKeys = if (displayedIds != null) {
                com.levi.pocketdj.ui.selection.stableKeys(shownIds)
            } else rowKeys
            shownIds.forEachIndexed { index, songId ->
                item(key = "song-$index-$songId") {
                    val song = catalog.songsById[songId]
                    if (song == null || PlayResolver.isStudioId(songId)) {
                        MissingItemRow()
                    } else {
                        CollectionTrackRow(
                            title = song.name,
                            subtitle = song.artist,
                            album = song.albumId?.let { catalog.albumsById[it] },
                            bpm = song.bpm,
                            camelot = song.camelot,
                            lengthMs = song.length,
                            dimmed = !manifest.containsKey(songId),
                            modifier = Modifier.selectableRow(rowSelection, shownKeys[index], selScope) { detailSongId = songId },
                            favoriteSongId = songId, favoriteAppleMusicId = song.appleMusicId,
                        )
                    }
                }
            }
        }
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

    CollectionSortFilterSheets(
        state = sortState,
        catalog = catalog,
        songIds = source?.playlist?.songIds.orEmpty(),
        showSort = showSort,
        showFilter = showFilter,
        onDismissSort = { showSort = false },
        onDismissFilter = { showFilter = false },
    )

    detailSongId?.let { songId ->
        SongDetailSheet(
            songId = songId,
            onDismiss = { detailSongId = null },
            snackbar = snackbar,
            onOpenAlbum = onOpenAlbum,
        )
    }
}

@Composable
private fun ActionRow(
    icon: ImageVector,
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val alpha = if (enabled) 1f else 0.45f
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary.copy(alpha = alpha),
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = alpha),
        )
    }
}

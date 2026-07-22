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
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.screens.browse.SongDetailSheet
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
    val source = catalog?.playlists?.firstOrNull {
        it.playlist.id == playlistId && it.sourceName == sourceName
    }

    var detailSongId by remember { mutableStateOf<String?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        if (source == null) {
            Text(
                if (catalog == null) "Loading catalog…" else "Source playlist not found",
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

        LazyColumn(modifier = Modifier.fillMaxSize()) {
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
            songIds.forEachIndexed { index, songId ->
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
                            onClick = { detailSongId = songId },
                        )
                    }
                }
            }
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

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

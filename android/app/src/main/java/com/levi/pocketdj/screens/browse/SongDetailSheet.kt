package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SnackbarHostState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.share.ShareText
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.ui.FavoriteToggle
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import java.util.Locale
import kotlinx.coroutines.launch

/**
 * Song detail sheet (specs/browse.md §9): art, title/artist, key chip, source
 * tag, album row (navigates when [onOpenAlbum] is provided), ordered metadata
 * grid, sentiment chips, play action.
 */
/** Minimal song facts for rows that are not in the catalog. */
data class MinimalSong(val title: String, val artist: String, val lengthMs: Long?)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SongDetailSheet(
    songId: String,
    onDismiss: () -> Unit,
    snackbar: SnackbarHostState,
    onOpenAlbum: ((String) -> Unit)? = null,
    /** Off-catalog rows (AM-only, amrec_, Studio): a minimal title/artist/length surface instead of "not found". */
    fallback: MinimalSong? = null,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    var showAddSheet by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf(false) }

    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val preparingId by graph.playbackController.preparingSongId.collectAsState()

    val catalog = catalogState.catalog
    val song = catalog?.songsById?.get(songId)
    val album = song?.albumId?.let { catalog.albumsById[it] }
    val source = catalog?.sourceOfSong?.get(songId)
    // Lyrics: fetch-once + disk cache, only when lyricsStatus == "found" (gate lives in the store).
    var lyrics by remember(songId) { mutableStateOf<String?>(null) }
    LaunchedEffect(song) {
        lyrics = song?.let { graph.browseGraph.lyricsStore.lyrics(it) }
    }
    val canPlay = playability(songId, manifest, settings?.hasRipServer == true, song?.appleMusicId)

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (song == null) {
                if (fallback == null) {
                    Text("Song not found", style = MaterialTheme.typography.bodyLarge)
                } else {
                    Text(fallback.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    if (fallback.artist.isNotBlank()) {
                        Text(fallback.artist, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
                    }
                    fallback.lengthMs?.takeIf { it > 0 }?.let {
                        Text("Length ${Fmt.duration(it)}", style = MaterialTheme.typography.bodySmall)
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        FavoriteToggle(songId = songId)
                        Spacer(Modifier.width(4.dp))
                        FilledTonalIconButton(
                            onClick = { showAddSheet = true },
                            modifier = Modifier.testTag("song-add-to-collection"),
                        ) { Icon(Icons.Filled.AddCircleOutline, contentDescription = "Add to collection") }
                        Spacer(Modifier.width(4.dp))
                        FilledTonalIconButton(
                            onClick = { ShareText.send(context, "${fallback.title} — ${fallback.artist}", "${fallback.title} — ${fallback.artist}") },
                            modifier = Modifier.testTag("song-share"),
                        ) { Icon(Icons.Filled.Share, contentDescription = "Share") }
                    }
                }
                return@Column
            }

            AlbumArt(album, modifier = Modifier.size(220.dp), cornerRadius = 10)
            Spacer(Modifier.height(14.dp))
            Text(
                song.name,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                song.artist,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.height(8.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                KeyChip(song.key, song.camelot)
                source?.let { MetaTag(it) }
            }

            Spacer(Modifier.height(16.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Button(
                    onClick = {
                        scope.launch { playAndReport(graph.playbackController, songId, snackbar) }
                    },
                    enabled = canPlay != Playability.NONE && preparingId != songId,
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = null)
                    Spacer(Modifier.width(6.dp))
                    Text(
                        when {
                            preparingId == songId -> "Preparing…"
                            canPlay == Playability.STREAM -> "Play"
                            canPlay == Playability.APPLE_MUSIC -> "Play (Apple Music)"
                            canPlay == Playability.RIP -> "Rip and play"
                            else -> "Not playable on this device"
                        },
                    )
                }
                Spacer(Modifier.width(4.dp))
                FavoriteToggle(songId = songId, appleMusicId = song.appleMusicId)
                Spacer(Modifier.width(4.dp))
                // Add-to-Collection launch point (specs/playlists-ui.md §8.1).
                FilledTonalIconButton(
                    onClick = { showAddSheet = true },
                    modifier = Modifier.testTag("song-add-to-collection"),
                ) {
                    Icon(Icons.Filled.AddCircleOutline, contentDescription = "Add to collection")
                }
                Spacer(Modifier.width(4.dp))
                FilledTonalIconButton(
                    onClick = { ShareText.send(context, ShareText.forSong(song), "${song.name} — ${song.artist}") },
                    modifier = Modifier.testTag("song-share"),
                ) {
                    Icon(Icons.Filled.Share, contentDescription = "Share")
                }
            }

            if (album != null) {
                Spacer(Modifier.height(16.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .let { base ->
                            if (onOpenAlbum != null) {
                                base.clickable {
                                    onDismiss()
                                    onOpenAlbum(album.id)
                                }
                            } else {
                                base
                            }
                        }
                        .padding(vertical = 6.dp),
                ) {
                    AlbumArt(album, modifier = Modifier.size(44.dp))
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(album.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                        MetaTag(listOfNotNull(album.year?.toString(), Genre.category(album.genre)).joinToString(" · "))
                    }
                }
            }

            SuggestedCollectionsBlock(songId = songId, graph = graph)

            Spacer(Modifier.height(12.dp))
            HorizontalDivider()
            Spacer(Modifier.height(8.dp))

            // Metadata grid — rows in spec order, skipping absent values except
            // BPM and Length which always render ("–" when absent, §9).
            val rows = buildList {
                add("Artist" to song.artist)
                album?.name?.let { add("Album" to it) }
                song.trackNumber?.let { add("Track #" to it.toString()) }
                song.year?.let { add("Year" to it.toString()) }
                add("BPM" to Fmt.bpm(song.bpm))
                song.key?.takeIf { it.isNotBlank() }?.let { add("Key" to it) }
                song.camelot?.takeIf { it.isNotBlank() }?.let { add("Camelot" to it) }
                add("Length" to Fmt.duration(song.length))
                song.explicit?.let { add("Explicit" to if (it) "Yes" else "No") }
                song.fileType?.takeIf { it.isNotBlank() }
                    ?.let { add("File type" to it.uppercase(Locale.ROOT)) }
                source?.let { add("Source" to it) }
                song.lyricsStatus?.takeIf { it.isNotBlank() }?.let { add("Lyrics" to it) }
            }
            rows.forEach { (label, value) ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 3.dp),
                ) {
                    Text(
                        label,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(96.dp),
                    )
                    Text(value, style = MaterialTheme.typography.bodySmall)
                }
            }

            val sentiments = song.sentimentKeywords.orEmpty().filter { it.isNotBlank() }
            if (sentiments.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    sentiments.forEach { keyword ->
                        AssistChip(onClick = {}, label = { Text(keyword) }, enabled = false)
                    }
                }
            }

            // DISC-2: user-added provisional songs (Discover / Imported) can be removed from the library.
            if (com.levi.pocketdj.screens.discover.isRemovableFromLibrary(source)) {
                Spacer(Modifier.height(14.dp))
                androidx.compose.material3.TextButton(
                    onClick = { confirmRemove = true },
                    colors = androidx.compose.material3.ButtonDefaults.textButtonColors(
                        contentColor = MaterialTheme.colorScheme.error,
                    ),
                    modifier = Modifier.testTag("song-remove-from-library"),
                ) { Text("Remove from Library") }
                if (confirmRemove) {
                    androidx.compose.material3.AlertDialog(
                        onDismissRequest = { confirmRemove = false },
                        title = { Text("Remove from Library?") },
                        text = { Text("${song.name} will be removed from your library.") },
                        confirmButton = {
                            androidx.compose.material3.TextButton(
                                modifier = Modifier.testTag("song-remove-confirm"),
                                onClick = {
                                    confirmRemove = false
                                    scope.launch {
                                        val removed = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                            graph.browseGraph.removeFromLibrary(songId, source, song.name, song.artist)
                                        }
                                        if (removed) {
                                            scope.launch { snackbar.showSnackbar("Removed ${song.name} from your library") }
                                            onDismiss()
                                        }
                                    }
                                },
                            ) { Text("Remove", color = MaterialTheme.colorScheme.error) }
                        },
                        dismissButton = {
                            androidx.compose.material3.TextButton(onClick = { confirmRemove = false }) { Text("Cancel") }
                        },
                    )
                }
            }

            lyrics?.takeIf { it.isNotBlank() }?.let { text ->
                Spacer(Modifier.height(14.dp))
                Text(
                    "LYRICS",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(6.dp))
                SelectionContainer {
                    Text(
                        text,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.fillMaxWidth().testTag("song-lyrics"),
                    )
                }
            }
        }
    }

    if (showAddSheet) {
        AddToCollectionSheet(
            item = AddToItem.Song(songId),
            onDismiss = { showAddSheet = false },
        )
    }
}

/** Row cap (iOS `prefix(5)`). */
internal const val SUGGESTED_COLLECTIONS_MAX = 5

/**
 * "Suggested collections" (BRW-13): the rec engine's per-song collection matches, hidden when there
 * are none (engine off, offline, nothing above threshold). Rows whose collection no longer resolves
 * locally are dropped; a stale server snapshot that already contains the song shows a check, not Add.
 */
@Composable
private fun SuggestedCollectionsBlock(songId: String, graph: AppGraph) {
    val engineOn by graph.browseGraph.recEnabled.collectAsState()
    var rows by remember(songId) { mutableStateOf<List<com.levi.pocketdj.data.recs.RecommendationService.CollectionSuggestion>>(emptyList()) }
    var added by remember(songId) { mutableStateOf(setOf<String>()) }
    LaunchedEffect(songId, engineOn) {
        rows = emptyList(); added = emptySet()
        if (!engineOn) return@LaunchedEffect
        rows = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val svc = graph.browseGraph.recService
            val collections = graph.collections
            svc.collectionSuggestions(songId).filter {
                if (it.kind == "pocket") collections.pocket(it.id) != null else collections.playlist(it.id) != null
            }
        }
    }
    if (rows.isEmpty()) return
    val collections = graph.collections
    HorizontalDivider(Modifier.padding(top = 12.dp))
    Column(Modifier.fillMaxWidth().padding(top = 8.dp).testTag("song-suggested-collections")) {
        Text(
            "SUGGESTED COLLECTIONS",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        rows.take(SUGGESTED_COLLECTIONS_MAX).forEachIndexed { idx, sug ->
            val isPocket = sug.kind == "pocket"
            val member = added.contains(sug.id) ||
                if (isPocket) collections.pocket(sug.id)?.songIds?.contains(songId) == true
                else collections.playlistContains(sug.id, songId)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp).testTag("song-suggested-collection-$idx"),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(sug.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                    sug.reasons.firstOrNull()?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                }
                if (member) {
                    Text("Added", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                } else {
                    androidx.compose.material3.OutlinedButton(onClick = {
                        // The generic addSong choke point: stamps activity + MRU exactly like the Add sheet.
                        collections.addSong(
                            songId,
                            com.levi.pocketdj.data.collections.AddTarget(
                                if (isPocket) com.levi.pocketdj.data.collections.AddTarget.Kind.POCKET
                                else com.levi.pocketdj.data.collections.AddTarget.Kind.PLAYLIST,
                                sug.id,
                            ),
                        )
                        added = added + sug.id
                    }) { Text("Add") }
                }
            }
        }
    }
}

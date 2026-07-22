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
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SnackbarHostState
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
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import java.util.Locale
import kotlinx.coroutines.launch

/**
 * Song detail sheet (specs/browse.md §9): art, title/artist, key chip, source
 * tag, album row (navigates when [onOpenAlbum] is provided), ordered metadata
 * grid, sentiment chips, play action.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SongDetailSheet(
    songId: String,
    onDismiss: () -> Unit,
    snackbar: SnackbarHostState,
    onOpenAlbum: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    var showAddSheet by remember { mutableStateOf(false) }

    val catalogState by graph.catalogRepository.state.collectAsState()
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val preparingId by graph.playbackController.preparingSongId.collectAsState()

    val catalog = catalogState.catalog
    val song = catalog?.songsById?.get(songId)
    val album = song?.albumId?.let { catalog.albumsById[it] }
    val source = catalog?.sourceOfSong?.get(songId)
    val canPlay = playability(songId, manifest, settings?.hasRipServer == true)

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
                Text("Song not found", style = MaterialTheme.typography.bodyLarge)
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
                            canPlay == Playability.RIP -> "Rip and play"
                            else -> "Not playable on this device"
                        },
                    )
                }
                Spacer(Modifier.width(8.dp))
                // Add-to-Collection launch point (specs/playlists-ui.md §8.1).
                FilledTonalIconButton(
                    onClick = { showAddSheet = true },
                    modifier = Modifier.testTag("song-add-to-collection"),
                ) {
                    Icon(Icons.Filled.AddCircleOutline, contentDescription = "Add to collection")
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
        }
    }

    if (showAddSheet) {
        AddToCollectionSheet(
            item = AddToItem.Song(songId),
            onDismiss = { showAddSheet = false },
        )
    }
}

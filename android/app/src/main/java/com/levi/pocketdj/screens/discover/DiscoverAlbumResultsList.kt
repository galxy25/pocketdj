package com.levi.pocketdj.screens.discover

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.browse.Fmt
import kotlinx.coroutines.launch

/**
 * Discover ▸ Albums results. Tapping a row expands its ordered track list in place
 * (`/album-tracks`, subscription-free); the trailing ＋ delegates to the album add (DISC-2).
 */
@Composable
fun DiscoverAlbumResultsList(
    ui: DiscoverUi<DiscoverAlbumHit>,
    canAddToLibrary: Boolean,
    loadTracks: suspend (collectionId: String) -> DiscoverAlbumExpansion,
    onAdd: suspend (DiscoverAlbumHit) -> Boolean,
    modifier: Modifier = Modifier,
) {
    var expandedId by rememberSaveable { mutableStateOf<String?>(null) }
    DiscoverStateHost(ui, "album") {
        LazyColumn(modifier.fillMaxSize()) {
            items(ui.hits, key = { it.id }) { hit ->
                DiscoverAlbumRow(
                    hit, canAddToLibrary, expanded = expandedId == hit.id,
                    onToggle = { expandedId = if (expandedId == hit.id) null else hit.id },
                    loadTracks = loadTracks, onAdd = onAdd,
                )
            }
        }
    }
}

@Composable
private fun DiscoverAlbumRow(
    hit: DiscoverAlbumHit,
    canAddToLibrary: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    loadTracks: suspend (String) -> DiscoverAlbumExpansion,
    onAdd: suspend (DiscoverAlbumHit) -> Boolean,
) {
    val scope = rememberCoroutineScope()
    var busy by remember(hit.id) { mutableStateOf(false) }
    var added by rememberSaveable(hit.id) { mutableStateOf(false) }
    var tracks by remember(hit.id) { mutableStateOf<DiscoverAlbumExpansion?>(null) }
    LaunchedEffect(expanded, hit.id) {
        if (expanded && tracks == null) tracks = loadTracks(hit.appleMusicId)
    }
    Column(Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle)
                .padding(horizontal = 12.dp, vertical = 6.dp),
        ) {
            DiscoverArt(hit.artworkUrl, 56)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(hit.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    listOfNotNull(
                        hit.artist.ifBlank { null }, hit.year?.toString(), hit.trackCount?.let { "$it tracks" },
                    ).joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            val help = DiscoverAddWording.addHelp("album", canAddToLibrary, opensInMusic = false)
            when {
                busy -> CircularProgressIndicator(Modifier.padding(12.dp).size(20.dp), strokeWidth = 2.dp)
                added -> Icon(Icons.Filled.Check, "Added", tint = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(12.dp))
                else -> IconButton(
                    onClick = {
                        busy = true
                        scope.launch { added = try { onAdd(hit) } finally { busy = false } }
                    },
                    modifier = Modifier.semantics { contentDescription = help },
                ) { Icon(Icons.Filled.Add, contentDescription = help) }
            }
        }
        if (expanded) {
            val t = tracks
            Column(Modifier.fillMaxWidth().padding(start = 80.dp, end = 16.dp, bottom = 8.dp)) {
                when {
                    t == null -> CircularProgressIndicator(Modifier.padding(8.dp).size(18.dp), strokeWidth = 2.dp)
                    t.tracks.isEmpty() -> Text(
                        "Track list unavailable", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    else -> t.tracks.forEachIndexed { i, track ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "${track.trackNumber ?: (i + 1)}", style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(24.dp),
                            )
                            Text(
                                track.title, style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                            )
                            track.durationMs?.let {
                                Text(
                                    Fmt.duration(it.toLong()), style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

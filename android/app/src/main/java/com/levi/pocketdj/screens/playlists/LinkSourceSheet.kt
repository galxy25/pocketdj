package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.CollectionSyncDirection
import java.text.Normalizer

/** Case/diacritic-insensitive name filter for the picker (iOS `folding(.caseInsensitive, .diacriticInsensitive)`). */
internal fun filterSourcePlaylists(sources: List<SourcePlaylist>, query: String): List<SourcePlaylist> {
    fun fold(s: String) = Normalizer.normalize(s, Normalizer.Form.NFD)
        .replace(Regex("\\p{Mn}+"), "").lowercase()
    val q = fold(query.trim())
    if (q.isEmpty()) return sources
    return sources.filter { fold(it.playlist.name).contains(q) }
}

/**
 * Picks the Apple Music source playlist to link an unlinked pocket to (searchable; tapping a row
 * links immediately). The caller passes only AM sources and shows this only when worthwhile.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LinkSourceSheet(
    sources: List<SourcePlaylist>,
    onDismiss: () -> Unit,
    onPick: (SourcePlaylist) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    val filtered = remember(sources, query) { filterSourcePlaylists(sources, query) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text("Link to a playlist", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                singleLine = true,
                placeholder = { Text("Search playlists") },
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("link-source-search"),
            )
            if (sources.isEmpty()) {
                Text(
                    "No Apple Music playlists found. Make sure the Apple Music source is enabled and loaded.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 16.dp),
                )
            }
            LazyColumn {
                items(filtered, key = { it.sourceName + "/" + it.playlist.id }) { sp ->
                    Column(
                        Modifier.fillMaxWidth().clickable { onPick(sp) }.padding(vertical = 10.dp)
                            .testTag("link-source-${sp.playlist.id}"),
                    ) {
                        Text(sp.playlist.name, style = MaterialTheme.typography.bodyLarge)
                        val n = sp.playlist.songIds.size
                        Text(
                            "$n song${if (n == 1) "" else "s"} · ${sp.sourceName}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

/**
 * Shared ⋯-menu block for a source-linked collection (pocket + playlist twins): the source
 * section (Apple Music sync direction, "Sync with source" toggle, "Sync from source now") when
 * [hasSource]; otherwise a "Link to Apple Music playlist…" entry when [onLink] is offered.
 */
@Composable
internal fun androidx.compose.foundation.layout.ColumnScope.SourceSyncMenuItems(
    dismiss: () -> Unit,
    hasSource: Boolean,
    syncEnabled: Boolean,
    direction: CollectionSyncDirection,
    onToggle: (Boolean) -> Unit,
    onSyncNow: () -> Unit,
    onDirection: (CollectionSyncDirection) -> Unit,
    onLink: (() -> Unit)?,
) {
    if (!hasSource) {
        if (onLink != null) {
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Link to Apple Music playlist…") },
                onClick = { dismiss(); onLink() },
                modifier = Modifier.testTag("pocket-link-source"),
            )
        }
        return
    }
    HorizontalDivider()
    Text(
        "Apple Music sync",
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
    )
    for (d in CollectionSyncDirection.entries) {
        DropdownMenuItem(
            text = { Text(d.label) },
            trailingIcon = { if (d == direction) Icon(Icons.Filled.Check, contentDescription = "Selected") },
            onClick = { onDirection(d) },
            modifier = Modifier.testTag("am-sync-direction-${d.raw}"),
        )
    }
    DropdownMenuItem(
        text = { Text("Sync with source") },
        trailingIcon = { if (syncEnabled) Icon(Icons.Filled.Check, contentDescription = "On") },
        onClick = { onToggle(!syncEnabled) },
        modifier = Modifier.testTag("sync-toggle"),
    )
    DropdownMenuItem(
        text = { Text("Sync from source now") },
        onClick = { dismiss(); onSyncNow() },
        modifier = Modifier.testTag("sync-now"),
    )
    if (onLink != null) {
        DropdownMenuItem(
            text = { Text("Re-link to Apple Music playlist…") },
            onClick = { dismiss(); onLink() },
        )
    }
}

/** Result alert for "Sync from source now" / link confirmation (null = hidden). */
@Composable
internal fun SourceSyncMessageAlert(message: String?, onDismiss: () -> Unit) {
    if (message == null) return
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sync from source") },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
    )
}

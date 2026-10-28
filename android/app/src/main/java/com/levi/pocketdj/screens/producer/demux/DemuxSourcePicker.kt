package com.levi.pocketdj.screens.producer.demux

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.studio.demux.DemuxSource

/** Pure picker rules (JVM-tested): collapse persistence, search force-expand, burned-first track ordering. */
object DemuxPickerRules {
    const val TRACK_LIMIT = 80
    const val STUDIO_BROWSE_LIMIT = 24

    /** Comma-joined EXPANDED group keys -> set (absent = collapsed = the default). */
    fun parseExpanded(raw: String): Set<String> = raw.split(',').filter { it.isNotBlank() }.toSet()
    fun serializeExpanded(keys: Set<String>): String = keys.sorted().joinToString(",")
    fun toggled(keys: Set<String>, key: String): Set<String> = if (key in keys) keys - key else keys + key

    /** A search force-expands every group so matches are never hidden behind a closed one. */
    fun isExpanded(query: String, key: String, expanded: Set<String>): Boolean = query.isNotEmpty() || key in expanded

    fun normalize(q: String): String = q.trim().lowercase()

    /** Empty query browses the BURNED subset; a query searches the whole catalog. Burned first, artist, name, top 80. */
    fun trackMatches(all: Collection<IndexSong>, query: String, burned: Set<String>): List<IndexSong> {
        val q = normalize(query)
        val filtered = if (q.isEmpty()) all.filter { it.id in burned }
        else all.filter { it.name.lowercase().contains(q) || it.artist.lowercase().contains(q) }
        return filtered.sortedWith(
            compareByDescending<IndexSong> { it.id in burned }
                .thenBy { it.artist.lowercase() }.thenBy { it.name.lowercase() },
        ).take(TRACK_LIMIT)
    }

    data class StudioRow(val id: String, val name: String, val kind: String)

    fun studioMatches(all: List<StudioRow>, query: String): List<StudioRow> {
        val q = normalize(query)
        return if (q.isEmpty()) all.take(STUDIO_BROWSE_LIMIT) else all.filter { it.name.lowercase().contains(q) }
    }

    fun fileMatches(all: List<Pair<String, String>>, query: String): List<Pair<String, String>> {
        val q = normalize(query)
        return if (q.isEmpty()) all else all.filter { it.second.lowercase().contains(q) }
    }
}

/** Everything the picker needs, supplied by the screen (keeps the composable free of graph types). */
class DemuxPickerData(
    val files: List<Pair<String, String>>,
    val studio: List<DemuxPickerRules.StudioRow>,
    val songs: Collection<IndexSong>,
    val burned: Set<String>,
)

@Composable
fun DemuxSourcePicker(
    data: DemuxPickerData,
    expandedRaw: String,
    onExpandedChange: (String) -> Unit,
    onImport: () -> Unit,
    onPick: (DemuxSource) -> Unit,
    modifier: Modifier = Modifier,
) {
    var search by remember { mutableStateOf("") }
    val expanded = DemuxPickerRules.parseExpanded(expandedRaw)
    val files = DemuxPickerRules.fileMatches(data.files, search)
    val studio = DemuxPickerRules.studioMatches(data.studio, search)
    val tracks = DemuxPickerRules.trackMatches(data.songs, search, data.burned)
    val q = DemuxPickerRules.normalize(search)

    Column(modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Demuxer", style = MaterialTheme.typography.titleMedium)
                Text("Pick audio to demux into chords and stems", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TextButton(onClick = onImport, modifier = Modifier.testTag("demux-import")) {
                Icon(Icons.Filled.FileDownload, null); Text(" Import")
            }
        }
        OutlinedTextField(
            value = search, onValueChange = { search = it }, singleLine = true,
            placeholder = { Text("Search tracks, samples, loops, instrumentals") },
            modifier = Modifier.fillMaxWidth().testTag("demux-source-search"),
        )
        LazyColumn(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            fun group(title: String, key: String, count: Int, rows: List<@Composable () -> Unit>) {
                item(key = "g-$key") {
                    val open = DemuxPickerRules.isExpanded(q, key, expanded)
                    Row(
                        Modifier.fillMaxWidth().clickable { onExpandedChange(DemuxPickerRules.serializeExpanded(DemuxPickerRules.toggled(expanded, key))) }
                            .padding(top = 8.dp, start = 8.dp, end = 8.dp, bottom = 4.dp).testTag("demux-group-$key"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(if (open) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(title, Modifier.weight(1f).padding(start = 6.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text("$count", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                rows.forEachIndexed { i, row -> item(key = "r-$key-$i") { if (DemuxPickerRules.isExpanded(q, key, expanded)) row() } }
            }
            if (files.isNotEmpty()) group("Imported audio", "imported", files.size, files.map { f -> { Row2(f.second, null, "demux-file-row-${f.first}") { onPick(DemuxSource.ImportedFile(f.first, f.second)) } } })
            if (studio.isNotEmpty()) group("Performance media", "studio", studio.size, studio.map { s -> { Row2(s.name, s.kind, "demux-studio-row-${s.id}") { onPick(DemuxSource.Studio(s.id, s.name)) } } })
            if (tracks.isNotEmpty()) group("Tracks", "tracks", tracks.size, tracks.map { t -> { Row2(t.name, t.artist + if (t.id in data.burned) " · on device" else "", "demux-track-row-${t.id}") { onPick(DemuxSource.Song(t.id, t.name, t.artist)) } } })
            if (files.isEmpty() && studio.isEmpty() && tracks.isEmpty()) item {
                Text(
                    if (q.isEmpty()) "Burn a track, make a sample, or Import an audio file to demux it." else "Nothing matches “$search”.",
                    Modifier.fillMaxWidth().padding(32.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun Row2(title: String, subtitle: String?, tag: String, onClick: () -> Unit) {
    Surface(Modifier.fillMaxWidth().clickable(onClick = onClick).testTag(tag), shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
        Column(Modifier.padding(horizontal = 10.dp, vertical = 8.dp)) {
            Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!subtitle.isNullOrEmpty()) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

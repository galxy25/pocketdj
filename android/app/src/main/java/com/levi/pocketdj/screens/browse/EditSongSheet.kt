package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.SongEdit
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.launch

/** Edit a song's metadata. Stores only fields that differ from the RAW song (iOS `EditSongView`). */
@Composable
fun EditSongSheet(song: IndexSong, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store = graph.collectionsGraph.editsStore
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(song.name) }
    var artist by remember { mutableStateOf(song.artist) }
    var year by remember { mutableStateOf(song.year?.toString().orEmpty()) }
    var track by remember { mutableStateOf(song.trackNumber?.toString().orEmpty()) }
    var bpm by remember { mutableStateOf(song.bpm?.let(EditDelta::trim).orEmpty()) }
    var key by remember { mutableStateOf(song.key.orEmpty()) }
    var camelot by remember { mutableStateOf(song.camelot.orEmpty()) }
    var explicit by remember { mutableStateOf(song.explicit ?: false) }
    var sentiment by remember { mutableStateOf(song.sentimentKeywords.orEmpty().joinToString(", ")) }
    val hasEdit = remember { store.songEdit(song.id) != null }

    EditSheetScaffold(
        title = "Edit Song",
        saveTag = "save-edit",
        onDismiss = onDismiss,
        saveEnabled = !EditDelta.songInvalid(year, track, bpm),
        onSave = {
            val raw = graph.catalogRepository.rawSong(song.id) ?: return@EditSheetScaffold onDismiss()
            val edit = EditDelta.songEdit(raw, name, artist, year, track, bpm, key, camelot, explicit, sentiment)
            scope.launch { store.setSongEditIo(song.id, edit); onDismiss() }
        },
        resetLabel = if (hasEdit) "Reset to original" else null,
        onReset = { scope.launch { store.setSongEditIo(song.id, SongEdit()); onDismiss() } },
    ) {
        EditField("Title", name, { name = it }, tag = "edit-song-title")
        EditField("Artist", artist, { artist = it })
        EditField("Track #", track, { track = it }, numeric = true, isError = EditDelta.badInt(track))
        EditField("Year", year, { year = it }, numeric = true, isError = EditDelta.badInt(year))
        EditField("BPM", bpm, { bpm = it }, numeric = true, tag = "edit-song-bpm", isError = EditDelta.badDouble(bpm))
        EditField("Key", key, { key = it })
        EditField("Camelot", camelot, { camelot = it })
        Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Explicit", modifier = Modifier.weight(1f))
            Switch(checked = explicit, onCheckedChange = { explicit = it })
        }
        EditField("Sentiment keywords", sentiment, { sentiment = it })
        Text("Comma-separated", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

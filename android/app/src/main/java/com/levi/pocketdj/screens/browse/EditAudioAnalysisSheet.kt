package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.AlbumEdit
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.launch

/**
 * Edit an album's detected audio-analysis segments (BPM / key / Camelot / start / end). Per-segment deltas against
 * the RAW detected segments go into the album's `audioTracks` edit; an all-default save drops the override
 * (iOS `EditAudioAnalysisView`).
 */
@Composable
fun EditAudioAnalysisSheet(album: IndexAlbum, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store = graph.collectionsGraph.editsStore
    val scope = rememberCoroutineScope()
    val rows = remember { mutableStateListOf<EditDelta.AudioRow>().also { it.addAll(EditDelta.audioRows(album.audioTracks)) } }
    val hasOverride = remember { store.albumEdit(album.id)?.audioTracks != null }

    EditSheetScaffold(
        title = "Edit Audio Analysis",
        saveTag = "save-audio-edit",
        onDismiss = onDismiss,
        onSave = {
            val edit = EditDelta.audioEdit(store.albumEdit(album.id), graph.catalogRepository.rawAlbum(album.id) ?: album, rows.toList())
            scope.launch { store.setAlbumEditIo(album.id, edit); onDismiss() }
        },
        resetLabel = if (hasOverride) "Reset audio analysis" else null,
        resetTag = "reset-audio-edit",
        onReset = {
            scope.launch {
                val e = store.albumEdit(album.id) ?: AlbumEdit()
                store.setAlbumEditIo(album.id, e.copy(audioTracks = null))
                onDismiss()
            }
        },
    ) {
        Column {
            rows.forEachIndexed { i, row ->
                Text("Segment ${row.trackNumber ?: (row.index + 1)}", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                EditField("BPM", row.bpm, { rows[i] = row.copy(bpm = it) }, numeric = true, tag = "audio-bpm-$i")
                EditField("Key", row.key, { rows[i] = row.copy(key = it) }, tag = "audio-key-$i")
                EditField("Camelot", row.camelot, { rows[i] = row.copy(camelot = it) }, tag = "audio-camelot-$i")
                EditField("Start (ms)", row.startMs, { rows[i] = row.copy(startMs = it) }, numeric = true, tag = "audio-start-$i")
                EditField("End (ms)", row.endMs, { rows[i] = row.copy(endMs = it) }, numeric = true, tag = "audio-end-$i")
                Spacer(Modifier.height(10.dp))
            }
        }
    }
}

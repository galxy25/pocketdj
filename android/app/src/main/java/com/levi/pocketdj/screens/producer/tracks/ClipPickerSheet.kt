package com.levi.pocketdj.screens.producer.tracks

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.model.StudioDocument
import java.io.File

/** One pickable source row. */
data class PickItem(val id: String, val name: String, val detail: String? = null)

/** A titled group of [PickItem]s. [kind] is null for stems and artifacts (they are not studio ids). */
data class PickSection(val key: String, val title: String, val kind: StudioClipSource?, val items: List<PickItem>)

/** What the user picked. */
sealed class ClipPick {
    data class Source(val id: String, val kind: StudioClipSource) : ClipPick()
    data class Artifact(val id: String) : ClipPick()
    /** Import all four stems of a song as four new tracks. */
    data class Stems(val songId: String) : ClipPick()
}

/** Songs with on-device stems (drums/bass/other/vocals); wired by the stems package, empty until then. */
interface TracksStemSource {
    fun songs(): List<PickItem>
    /** stem name -> local file for [songId] (all four, or null when any is missing). */
    suspend fun stemFiles(songId: String): Map<String, File>?
}

/** Pure sectioning + search for the add-clip picker (iOS ClipSourcePicker). */
object ClipPickerModel {
    val STEM_ORDER = listOf("drums", "bass", "other", "vocals")

    fun sections(doc: StudioDocument, stems: List<PickItem>, query: String): List<PickSection> {
        val q = query.trim()
        fun f(xs: List<PickItem>) = if (q.isEmpty()) xs else xs.filter { it.name.contains(q, ignoreCase = true) }
        fun named(n: String, fallback: String = "Untitled") = n.ifEmpty { fallback }
        val all = listOf(
            PickSection("samples", "Samples", StudioClipSource.SAMPLE, doc.samples.map { PickItem(it.id, named(it.name)) }),
            PickSection("loops", "Loops", StudioClipSource.LOOP, doc.loops.map { PickItem(it.id, named(it.name)) }),
            PickSection("sequences", "Sequences", StudioClipSource.PATTERN, doc.patterns.map { PickItem(it.id, named(it.name)) }),
            PickSection("takes", "Instrumentals", StudioClipSource.TAKE, doc.takes.map { PickItem(it.id, named(it.name)) }),
            PickSection("stems", "Stems", null, stems.map { it.copy(detail = "4 stems") }),
            PickSection(
                "artifacts", "Bounces & recordings", null,
                doc.arrangementArtifacts.sortedByDescending { it.createdAt }.map { PickItem(it.id, named(it.name), it.kind.raw) },
            ),
        )
        return all.map { it.copy(items = f(it.items)) }.filter { it.items.isNotEmpty() }
    }

    fun isEmpty(doc: StudioDocument, stems: List<PickItem>) = sections(doc, stems, "").isEmpty()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ClipPickerSheet(doc: StudioDocument, stems: List<PickItem>, onPick: (ClipPick) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val sections = remember(doc, stems, query) { ClipPickerModel.sections(doc, stems, query) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag("clip-picker")) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text("Add clip", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(query, { query = it }, placeholder = { Text("Search sources") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("clip-picker-search"))
            if (ClipPickerModel.isEmpty(doc, stems)) {
                Text("No sources yet. Make a sample, loop, sequence, or instrumental first, then add it to a track.",
                    Modifier.padding(vertical = 24.dp).testTag("clip-picker-empty"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            LazyColumn(Modifier.fillMaxWidth()) {
                for (sec in sections) {
                    item(key = "h-${sec.key}") {
                        Text("${sec.title} (${sec.items.size})", style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 12.dp, bottom = 4.dp))
                    }
                    items(sec.items, key = { "${sec.key}-${it.id}" }) { item ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                onPick(
                                    when (sec.key) {
                                        "stems" -> ClipPick.Stems(item.id)
                                        "artifacts" -> ClipPick.Artifact(item.id)
                                        else -> ClipPick.Source(item.id, sec.kind!!)
                                    },
                                )
                            }.padding(vertical = 12.dp).testTag("clip-picker-item-${item.id}"),
                        ) {
                            Text(item.name, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            item.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

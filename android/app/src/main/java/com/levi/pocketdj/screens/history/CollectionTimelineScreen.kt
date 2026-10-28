package com.levi.pocketdj.screens.history

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.RecentlyAdded
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.timeline.CollectionTimeline
import com.levi.pocketdj.data.timeline.TimelineCueStore
import com.levi.pocketdj.data.timeline.TimelineGrain
import com.levi.pocketdj.di.AppGraph
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The Collection tab's grain picker: Activity (default, ephemeral) | Songs | Albums. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CollectionTab(
    catalog: MergedCatalog,
    query: String,
    onSongClick: (String) -> Unit,
    activityContent: @Composable () -> Unit,
) {
    // Ephemeral by design: every open of the tab lands on Activity.
    var grain by remember { mutableStateOf(TimelineGrain.ACTIVITY) }
    Column(Modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
            TimelineGrain.entries.forEachIndexed { i, g ->
                SegmentedButton(
                    selected = grain == g,
                    onClick = { grain = g },
                    shape = SegmentedButtonDefaults.itemShape(i, TimelineGrain.entries.size),
                    modifier = Modifier.testTag("collection-grain-${g.token}"),
                ) { Text(g.label) }
            }
        }
        if (grain == TimelineGrain.ACTIVITY) activityContent()
        else CollectionTimelineScreen(grain, catalog, query, onSongClick)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CollectionTimelineScreen(
    grain: TimelineGrain,
    catalog: MergedCatalog,
    query: String,
    onSongClick: (String) -> Unit,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val activity by produceState<List<com.levi.pocketdj.data.activity.ActivityEvent>>(emptyList()) {
        val store = withContext(Dispatchers.IO) { graph.collectionActivity }
        store.state.collect { value = it.events }
    }
    val cueStore = remember { TimelineCueStore(File(context.filesDir, TimelineCueStore.FILE_NAME)) }
    val cues by cueStore.state.collectAsState()

    var afterMs by remember { mutableStateOf<Double?>(null) }
    var ascending by remember { mutableStateOf(false) }
    var showDate by remember { mutableStateOf(false) }
    var showCues by remember { mutableStateOf(false) }
    var showAddCue by remember { mutableStateOf(false) }

    // Heavy derivation OFF main; the body only indexes the finished list.
    val resultOrNull by produceState<CollectionTimeline.Result?>(null, grain, catalog, query, afterMs, ascending, activity) {
        value = withContext(Dispatchers.Default) {
            val added = RecentlyAdded.addedAtBySongId(catalog.songs, RecentlyAdded.addTimeOverrides(activity))
            val plays = PlayHistoryStore.get(context.applicationContext).events.groupingBy { it.songId }.eachCount()
            CollectionTimeline.build(
                CollectionTimeline.Input(catalog.songsById, catalog.albumsById, added, plays, grain, afterMs, ascending, query),
            )
        }
    }
    val result = resultOrNull
    val listState = rememberLazyListState()
    val dateFmt = remember { DateFormat.getDateInstance(DateFormat.MEDIUM) }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            TextButton(onClick = { showDate = true }, modifier = Modifier.testTag("timeline-since")) {
                Text(afterMs?.let { "Since ${dateFmt.format(Date(it.toLong()))}" } ?: "Since: all time")
            }
            if (afterMs != null) TextButton(onClick = { afterMs = null }) { Text("Clear") }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { ascending = !ascending }, modifier = Modifier.testTag("timeline-direction")) {
                Text(if (ascending) "Oldest first" else "Newest first")
            }
            TextButton(onClick = { showCues = true }, modifier = Modifier.testTag("timeline-cues")) { Text("Cues") }
        }
        if (result != null) {
            val s = result.summary
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
                Text(
                    "${s.heard} of ${s.songs} songs heard · ${s.plays} plays",
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.testTag("timeline-summary"),
                )
                LinearProgressIndicator(progress = { s.progress.toFloat() }, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp))
                if (s.undated > 0) Text(
                    "${s.undated} ${if (grain == TimelineGrain.ALBUMS) "albums" else "songs"} have no add date and aren't placed in the timeline",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (s.ungrouped > 0) Text(
                    "${s.ungrouped} songs have no album and aren't shown here",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            LazyColumn(state = listState, modifier = Modifier.fillMaxSize().testTag("timeline-list")) {
                items(result.rows, key = { it.id }) { row ->
                    if (row.startsMonth) Text(
                        row.monthLabel,
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("timeline-month"),
                    )
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable(enabled = !row.isAlbum) { onSongClick(row.itemId) }
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                            .testTag("timeline-row"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(row.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                            Text(
                                row.artist + " · " + dateFmt.format(Date(row.addedAtMs.toLong())),
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (row.isAlbum) "${row.heard}/${row.total}" else if (row.heard > 0) "heard" else "",
                            style = MaterialTheme.typography.labelSmall,
                            color = if (row.fullyHeard) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }

    if (showDate) {
        val st = rememberDatePickerState(initialSelectedDateMillis = afterMs?.toLong())
        DatePickerDialog(
            onDismissRequest = { showDate = false },
            confirmButton = { TextButton(onClick = { afterMs = st.selectedDateMillis?.toDouble(); showDate = false }) { Text("Apply") } },
            dismissButton = { TextButton(onClick = { showDate = false }) { Text("Cancel") } },
        ) { DatePicker(state = st) }
    }

    if (showCues) {
        AlertDialog(
            onDismissRequest = { showCues = false },
            title = { Text("Cue points") },
            text = {
                Column {
                    if (cues.cues.isEmpty()) Text("No cues yet. Add one at the date shown at the top of the list.")
                    cues.cues.forEach { cue ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            TextButton(
                                onClick = {
                                    showCues = false
                                    val idx = result?.let { CollectionTimeline.jumpIndex(it.rows, cue.atMs, ascending) }
                                    if (idx != null) scope.launch { listState.scrollToItem(idx) }
                                },
                                modifier = Modifier.weight(1f),
                            ) { Text("${cue.name} · ${dateFmt.format(Date(cue.atMs.toLong()))}", maxLines = 1, overflow = TextOverflow.Ellipsis) }
                            TextButton(onClick = { cueStore.remove(cue.id) }) { Text("Delete") }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { showCues = false; showAddCue = true }) { Text("Add cue here") } },
            dismissButton = { TextButton(onClick = { showCues = false }) { Text("Close") } },
        )
    }

    if (showAddCue) {
        var name by remember { mutableStateOf("") }
        val first = result?.rows?.getOrNull(listState.firstVisibleItemIndex.coerceAtMost((result.rows.size - 1).coerceAtLeast(0)))
        AlertDialog(
            onDismissRequest = { showAddCue = false },
            title = { Text("Name this cue") },
            text = {
                Column {
                    first?.let { Text(dateFmt.format(Date(it.addedAtMs.toLong())), style = MaterialTheme.typography.labelMedium) }
                    OutlinedTextField(name, { name = it }, singleLine = true, modifier = Modifier.testTag("timeline-cue-name"))
                }
            },
            confirmButton = {
                TextButton(
                    enabled = first != null && name.isNotBlank(),
                    onClick = { first?.let { cueStore.add(name, it.addedAtMs) }; showAddCue = false },
                ) { Text("Add") }
            },
            dismissButton = { TextButton(onClick = { showAddCue = false }) { Text("Cancel") } },
        )
    }
}

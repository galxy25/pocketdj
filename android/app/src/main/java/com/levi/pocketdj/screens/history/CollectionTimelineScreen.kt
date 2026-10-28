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
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import com.levi.pocketdj.data.timeline.CollectionTimeline
import com.levi.pocketdj.data.timeline.TimelineCueStore
import com.levi.pocketdj.data.timeline.TimelineGrain
import com.levi.pocketdj.di.AppGraph
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The Collection tab's grain picker: Activity (default, ephemeral) | Songs | Albums. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CollectionTab(
    catalog: MergedCatalog,
    query: String,
    onSongClick: (String) -> Unit,
    onAlbumClick: (String) -> Unit,
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
        else CollectionTimelineScreen(grain, catalog, query, onSongClick, onAlbumClick)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CollectionTimelineScreen(
    grain: TimelineGrain,
    catalog: MergedCatalog,
    query: String,
    onSongClick: (String) -> Unit,
    onAlbumClick: (String) -> Unit,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val activity by produceState<List<com.levi.pocketdj.data.activity.ActivityEvent>>(emptyList()) {
        val store = withContext(Dispatchers.IO) { graph.collectionActivity }
        store.state.collect { value = it.events }
    }
    // One graph-owned store (synced, cleared on account deletion); loaded off main.
    val cueStoreOrNull by produceState<TimelineCueStore?>(null) {
        value = withContext(Dispatchers.IO) { graph.servicesGraph.timelineCues }
    }
    val cueStore = cueStoreOrNull
    val cues by (cueStore?.state ?: remember { MutableStateFlow(TimelineCueStore.State(emptyList(), 0)) }).collectAsState()

    var afterMs by remember { mutableStateOf<Double?>(null) }
    var ascending by remember { mutableStateOf(false) }
    var showDate by remember { mutableStateOf(false) }
    var showCues by remember { mutableStateOf(false) }
    var showAddCue by remember { mutableStateOf(false) }
    var renameCue by remember { mutableStateOf<TimelineCueStore.Cue?>(null) }

    // Debounce typing (a non-empty query waits 180 ms; clearing is immediate).
    val builtQuery by produceState(query, query) {
        if (query.isNotBlank()) delay(180)
        value = query
    }
    // Memoised separately from grain/direction/query: add-dates by (catalog, activity), plays by the stats revision.
    val addedAt by produceState<Map<String, Double>?>(null, catalog, activity) {
        value = withContext(Dispatchers.Default) {
            RecentlyAdded.addedAtBySongId(catalog.songs, RecentlyAdded.addTimeOverrides(activity))
        }
    }
    val plays by produceState<Map<String, Int>?>(null) {
        val stats = withContext(Dispatchers.IO) { graph.servicesGraph.playStats }
        stats.revision.collect { value = withContext(Dispatchers.Default) { stats.playCountsSnapshot() } }
    }

    // Heavy derivation OFF main; superseded builds are cancelled (key change) and abandon via cancelCheck.
    val built by produceState<Built?>(null, grain, catalog, builtQuery, afterMs, ascending, addedAt, plays) {
        val a = addedAt ?: return@produceState
        val p = plays ?: return@produceState
        val key = listOf(grain, ascending, afterMs, builtQuery)
        val r = withContext(Dispatchers.Default) {
            val job = coroutineContext
            CollectionTimeline.build(
                CollectionTimeline.Input(
                    catalog.songsById, catalog.albumsById, a, p, grain, afterMs, ascending, builtQuery,
                    cancelCheck = { job.ensureActive() },
                ),
            )
        }
        value = Built(key, r)
    }
    val result = built?.result
    val listState = rememberLazyListState()
    // A new stream (grain / direction / since-date / query) starts at the top; a cue jump scrolls explicitly after.
    LaunchedEffect(built?.key) { if (built != null) listState.scrollToItem(0) }
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
        val emptyMsg = CollectionTimeline.emptyMessage(built == null, result, afterMs, builtQuery)
        if (emptyMsg != null) Text(
            emptyMsg,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.fillMaxWidth().padding(24.dp).testTag("timeline-empty"),
        )
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
                            .clickable { if (row.isAlbum) onAlbumClick(row.itemId) else onSongClick(row.itemId) }
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
        val st = rememberDatePickerState(
            initialSelectedDateMillis = afterMs?.let { CollectionTimeline.localToPickerMillis(it) },
            selectableDates = PastOrToday,
        )
        DatePickerDialog(
            onDismissRequest = { showDate = false },
            confirmButton = {
                TextButton(onClick = {
                    afterMs = st.selectedDateMillis?.let { CollectionTimeline.pickerMillisToLocalStartOfDay(it) }
                    showDate = false
                }) { Text("Apply") }
            },
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
                            TextButton(onClick = { renameCue = cue; showCues = false }) { Text("Rename") }
                            TextButton(onClick = { cueStore?.remove(cue.id) }) { Text("Delete") }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { showCues = false; showAddCue = true }) { Text("Add cue here") } },
            dismissButton = { TextButton(onClick = { showCues = false }) { Text("Close") } },
        )
    }

    renameCue?.let { cue ->
        var name by remember(cue.id) { mutableStateOf(cue.name) }
        AlertDialog(
            onDismissRequest = { renameCue = null },
            title = { Text("Rename cue") },
            text = { OutlinedTextField(name, { name = it }, singleLine = true, modifier = Modifier.testTag("timeline-cue-rename")) },
            confirmButton = {
                TextButton(enabled = name.isNotBlank(), onClick = { cueStore?.rename(cue.id, name); renameCue = null }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { renameCue = null }) { Text("Cancel") } },
        )
    }

    if (showAddCue) {
        var name by remember { mutableStateOf("") }
        // Default: the first visible row's date (read once at open), else today; any past date is allowed.
        var atMs by remember {
            val first = result?.rows?.getOrNull(listState.firstVisibleItemIndex.coerceAtMost((result.rows.size - 1).coerceAtLeast(0)))
            mutableStateOf(first?.addedAtMs ?: System.currentTimeMillis().toDouble())
        }
        var pickDate by remember { mutableStateOf(false) }
        AlertDialog(
            onDismissRequest = { showAddCue = false },
            title = { Text("Name this cue") },
            text = {
                Column {
                    TextButton(onClick = { pickDate = true }, modifier = Modifier.testTag("timeline-cue-date")) {
                        Text(dateFmt.format(Date(atMs.toLong())))
                    }
                    OutlinedTextField(name, { name = it }, singleLine = true, modifier = Modifier.testTag("timeline-cue-name"))
                }
            },
            confirmButton = {
                TextButton(
                    enabled = name.isNotBlank(),
                    onClick = { cueStore?.add(name, atMs); showAddCue = false },
                ) { Text("Add") }
            },
            dismissButton = { TextButton(onClick = { showAddCue = false }) { Text("Cancel") } },
        )
        if (pickDate) {
            val st = rememberDatePickerState(
                initialSelectedDateMillis = CollectionTimeline.localToPickerMillis(atMs),
                selectableDates = PastOrToday,
            )
            DatePickerDialog(
                onDismissRequest = { pickDate = false },
                confirmButton = {
                    TextButton(onClick = {
                        st.selectedDateMillis?.let { atMs = CollectionTimeline.pickerMillisToLocalStartOfDay(it) }
                        pickDate = false
                    }) { Text("Set") }
                },
                dismissButton = { TextButton(onClick = { pickDate = false }) { Text("Cancel") } },
            ) { DatePicker(state = st) }
        }
    }
}

private class Built(val key: List<Any?>, val result: CollectionTimeline.Result)

/** Dates up to and including today (iOS `in: ...Date()`); the picker's UTC-midnight values compare against now + 1 day. */
@OptIn(ExperimentalMaterial3Api::class)
private val PastOrToday = object : SelectableDates {
    override fun isSelectableDate(utcTimeMillis: Long): Boolean =
        CollectionTimeline.pickerMillisToLocalStartOfDay(utcTimeMillis) <= System.currentTimeMillis()
}

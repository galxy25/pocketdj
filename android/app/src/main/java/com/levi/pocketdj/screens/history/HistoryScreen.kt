package com.levi.pocketdj.screens.history

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DateRangePicker
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDateRangePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * One derived timeline row (specs/history.md §5): identity is the EVENT id —
 * a song played three times is three rows. Title/artist resolve live-catalog
 * first, event snapshot second, so history outlives the catalog.
 */
private data class HistoryRow(
    val eventId: String,
    val songId: String,
    val title: String,
    val artist: String,
    val artUrl: String?,
    val source: PlaySource,
    val contextName: String?,
    val playedAtMs: Long,
    /** Total plays of this song in the log (badge shows only when > 1). */
    val playCount: Int,
)

private const val PAGE_SIZE = 120

/** One selected day covers the whole day — the range end is exclusive +24 h. */
private const val DAY_MS = 24L * 60 * 60 * 1000

/**
 * History tab (specs/history.md §5–§7): `Plays | Activity` segments — Plays is
 * the play timeline with search ("Search title or artist"), sort (last-played
 * asc/desc) and the played-between date-range filter (§6 P1 minimum); Activity
 * is a Phase 2 stub ([ActivityContent]) whose segment is selectable so the P2
 * seam is visible.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    modifier: Modifier = Modifier,
    onSongClick: (songId: String) -> Unit = {},
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store = remember { PlayHistoryStore.get(context) }
    LaunchedEffect(Unit) { graph.catalogRepository.loadIfNeeded() }

    val historyState by store.state.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val catalog = catalogState.catalog ?: MergedCatalog.EMPTY

    // 0 = Plays, 1 = Activity (P2 placeholder — selectable, per §7).
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }

    // History-only search/sort/filter state (never shared with Browse's, §6.4).
    var query by rememberSaveable { mutableStateOf("") }
    var newestFirst by rememberSaveable { mutableStateOf(true) }
    var rangeStartMs by rememberSaveable { mutableStateOf<Long?>(null) }
    var rangeEndMs by rememberSaveable { mutableStateOf<Long?>(null) }
    var showSortMenu by remember { mutableStateOf(false) }
    var showRangeDialog by remember { mutableStateOf(false) }

    // Filter/sort compute over up to 20k rows runs off the main thread, keyed
    // on (history revision, catalog identity, filter/sort signature) — never on
    // events.size, which pins at the cap (specs/history.md §5).
    val rows by produceState(
        initialValue = emptyList<HistoryRow>(),
        historyState.revision,
        catalog,
        query,
        newestFirst,
        rangeStartMs,
        rangeEndMs,
    ) {
        val events = historyState.events
        value = withContext(Dispatchers.Default) {
            buildRows(events, catalog, store, query, newestFirst, rangeStartMs, rangeEndMs)
        }
    }

    Column(modifier = modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .testTag("history-tab-picker"),
        ) {
            SegmentedButton(
                selected = selectedTab == 0,
                onClick = { selectedTab = 0 },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
            ) { Text("Plays") }
            SegmentedButton(
                selected = selectedTab == 1,
                onClick = { selectedTab = 1 },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                modifier = Modifier.testTag("history-tab-activity"),
            ) { Text("Activity") }
        }
        when (selectedTab) {
            0 -> {
                // Search + toolbar (Plays segment only, §6.3).
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp),
                ) {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        singleLine = true,
                        placeholder = { Text("Search title or artist") },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        trailingIcon = {
                            if (query.isNotEmpty()) {
                                IconButton(onClick = { query = "" }) {
                                    Icon(Icons.Filled.Close, contentDescription = "Clear search")
                                }
                            }
                        },
                        modifier = Modifier
                            .weight(1f)
                            .testTag("history-search"),
                    )
                    Box {
                        IconButton(
                            onClick = { showSortMenu = true },
                            modifier = Modifier.testTag("history-sort"),
                        ) {
                            Icon(Icons.AutoMirrored.Filled.Sort, contentDescription = "Sort")
                        }
                        DropdownMenu(
                            expanded = showSortMenu,
                            onDismissRequest = { showSortMenu = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text(if (newestFirst) "✓ Newest first" else "Newest first") },
                                onClick = {
                                    newestFirst = true
                                    showSortMenu = false
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(if (!newestFirst) "✓ Oldest first" else "Oldest first") },
                                onClick = {
                                    newestFirst = false
                                    showSortMenu = false
                                },
                            )
                        }
                    }
                    val rangeActive = rangeStartMs != null || rangeEndMs != null
                    IconButton(
                        onClick = { showRangeDialog = true },
                        modifier = Modifier.testTag("history-filter"),
                    ) {
                        Icon(
                            Icons.Filled.FilterList,
                            contentDescription = "Filter by date",
                            tint = if (rangeActive) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.onSurface
                            },
                        )
                    }
                }
                PlaysTimeline(
                    rows = rows,
                    hasAnyEvents = historyState.events.isNotEmpty(),
                    onSongClick = onSongClick,
                )
            }
            else -> ActivityContent()
        }
    }

    if (showRangeDialog) {
        val rangeState = rememberDateRangePickerState(
            initialSelectedStartDateMillis = rangeStartMs,
            initialSelectedEndDateMillis = rangeEndMs?.let { it - DAY_MS },
        )
        DatePickerDialog(
            onDismissRequest = { showRangeDialog = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        rangeStartMs = rangeState.selectedStartDateMillis
                        // Selected end DAY is inclusive → exclusive bound +24 h.
                        rangeEndMs = (rangeState.selectedEndDateMillis
                            ?: rangeState.selectedStartDateMillis)?.plus(DAY_MS)
                        showRangeDialog = false
                    },
                ) { Text("Apply") }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        rangeStartMs = null
                        rangeEndMs = null
                        showRangeDialog = false
                    },
                ) { Text("Clear") }
            },
        ) {
            DateRangePicker(
                state = rangeState,
                title = {
                    Text(
                        "Played between",
                        modifier = Modifier.padding(start = 24.dp, top = 16.dp),
                    )
                },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun PlaysTimeline(
    rows: List<HistoryRow>,
    hasAnyEvents: Boolean,
    onSongClick: (String) -> Unit,
) {
    if (rows.isEmpty()) {
        if (hasAnyEvents) {
            EmptyState(
                icon = Icons.Filled.History,
                title = "No matches",
                caption = "No plays match the search or date range.",
                testTag = "history-no-matches",
            )
        } else {
            EmptyState(
                icon = Icons.Filled.History,
                title = "No plays yet",
                caption = "Songs you play in a Mix, Playlist, Pocket, Set list, or the Browser show up here.",
                testTag = "history-empty",
            )
        }
        return
    }

    // Render a growing prefix of the row list (History can hold 20k events);
    // a catalog refresh must not reset a scrolled-in budget.
    var pageBudget by rememberSaveable { mutableIntStateOf(PAGE_SIZE) }
    val visible = if (rows.size > pageBudget) rows.subList(0, pageBudget) else rows

    LazyColumn(modifier = Modifier.fillMaxSize()) {
        items(visible, key = { it.eventId }) { row ->
            PlayRow(row = row, onClick = { onSongClick(row.songId) })
        }
        if (rows.size > visible.size) {
            item(key = "history-load-more") {
                // Composing the sentinel = the last page scrolled in; grow.
                LaunchedEffect(pageBudget) { pageBudget += PAGE_SIZE }
                Spacer(Modifier.height(48.dp))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlayRow(row: HistoryRow, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ArtThumb(row.artUrl)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = row.title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onBackground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = row.artist,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                ContextLine(row)
            }
            if (row.playCount > 1) {
                Spacer(Modifier.width(8.dp))
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = RoundedCornerShape(50),
                    modifier = Modifier.testTag("history-count-${row.songId}"),
                ) {
                    Text(
                        text = "${row.playCount} plays",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                    )
                }
            }
        }
    }
}

/** `[source-icon] {SourceLabel} · {contextName} · {relative time}` (§6 row). */
@Composable
private fun ContextLine(row: HistoryRow) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = row.source.icon(),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(13.dp),
        )
        Spacer(Modifier.width(4.dp))
        val contextLabel = row.contextName
            ?.takeIf { it.isNotBlank() }
            ?.let { "${row.source.label} · $it" }
            ?: row.source.label
        Text(
            text = "$contextLabel · ${relativeTime(row.playedAtMs)}",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ArtThumb(artUrl: String?) {
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(RoundedCornerShape(6.dp)),
        contentAlignment = Alignment.Center,
    ) {
        if (artUrl != null) {
            AsyncImage(
                model = artUrl,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Surface(
                color = MaterialTheme.colorScheme.surfaceVariant,
                modifier = Modifier.fillMaxSize(),
            ) {}
            Icon(
                imageVector = Icons.Filled.MusicNote,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

/**
 * Phase 2 seam (specs/history.md §7): standalone composable that will take the
 * collection-activity store when it exists — P2 drops in real rows without
 * touching the Plays side.
 */
@Composable
private fun ActivityContent() {
    EmptyState(
        icon = Icons.Filled.History,
        title = "No collection activity yet",
        caption = "Adding a song to a playlist or pocket, hearting a song, or removing one shows up here.",
        testTag = "history-activity-empty",
    )
}

@Composable
private fun EmptyState(
    icon: ImageVector,
    title: String,
    caption: String,
    testTag: String,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp)
            .testTag(testTag),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(44.dp),
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = caption,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

/** Nearest Material icons to the iOS SF Symbols per source (§2). */
private fun PlaySource.icon(): ImageVector = when (this) {
    PlaySource.BROWSER -> Icons.AutoMirrored.Filled.List
    PlaySource.PLAYLIST -> Icons.AutoMirrored.Filled.QueueMusic
    PlaySource.POCKET -> Icons.Filled.Layers
    PlaySource.ALBUM -> Icons.Filled.Album
    PlaySource.SETLIST -> Icons.AutoMirrored.Filled.QueueMusic
    PlaySource.MIX -> Icons.Filled.Tune
    PlaySource.ARTIST -> Icons.Filled.Mic
}

/** Abbreviated relative time ("2 hr. ago") from an epoch-ms play time. */
private fun relativeTime(playedAtMs: Long): String {
    val now = System.currentTimeMillis()
    if (now - playedAtMs < DateUtils.MINUTE_IN_MILLIS) return "just now"
    return DateUtils.getRelativeTimeSpanString(
        playedAtMs,
        now,
        DateUtils.MINUTE_IN_MILLIS,
        DateUtils.FORMAT_ABBREV_RELATIVE,
    ).toString()
}

/**
 * Rows with live-catalog-first, snapshot-second resolution, filtered by the
 * search query (title or artist, case-folded) and the played-between range
 * ([rangeStartMs] inclusive, [rangeEndMs] exclusive), sorted by playedAt in
 * the requested direction (§6.4).
 */
private fun buildRows(
    events: List<PlayEvent>,
    catalog: MergedCatalog,
    store: PlayHistoryStore,
    query: String,
    newestFirst: Boolean,
    rangeStartMs: Long?,
    rangeEndMs: Long?,
): List<HistoryRow> {
    val needle = query.trim()
    val ordered = if (newestFirst) events.asReversed() else events
    return ordered.mapNotNull { event ->
        val playedAtMs = event.playedAt.toLong()
        if (rangeStartMs != null && playedAtMs < rangeStartMs) return@mapNotNull null
        if (rangeEndMs != null && playedAtMs >= rangeEndMs) return@mapNotNull null
        val song = catalog.songsById[event.songId]
        val title = song?.name ?: event.title ?: event.songId
        val artist = song?.artist ?: event.artist ?: ""
        if (needle.isNotEmpty() &&
            !title.contains(needle, ignoreCase = true) &&
            !artist.contains(needle, ignoreCase = true)
        ) {
            return@mapNotNull null
        }
        val album = song?.albumId?.let { catalog.albumsById[it] }
        HistoryRow(
            eventId = event.id,
            songId = event.songId,
            title = title,
            artist = artist,
            artUrl = album?.artCandidates()?.firstOrNull(),
            source = event.source,
            contextName = event.contextName,
            playedAtMs = playedAtMs,
            playCount = store.playCount(event.songId),
        )
    }
}

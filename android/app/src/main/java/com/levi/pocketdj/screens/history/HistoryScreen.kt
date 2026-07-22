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
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.HeartBroken
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.RemoveCircleOutline
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
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val PAGE_SIZE = 120

/** One selected day covers the whole day — the range end is exclusive +24 h. */
private const val DAY_MS = 24L * 60 * 60 * 1000

/**
 * The three History views. Default is [UNIFIED]; the tab bar always offers the
 * two you're NOT currently in ([altTabs]) — iOS `HistoryView.HistoryTab` parity.
 */
private enum class HistoryTab(val label: String, val icon: ImageVector) {
    UNIFIED("Unified", Icons.Filled.Layers),
    PLAYBACK("Playback", Icons.Filled.PlayCircle),
    COLLECTION("Collection", Icons.AutoMirrored.Filled.QueueMusic),
}

/** The two destinations shown as tabs from the current view (never the current one). */
private fun HistoryTab.altTabs(): List<HistoryTab> = when (this) {
    HistoryTab.UNIFIED -> listOf(HistoryTab.PLAYBACK, HistoryTab.COLLECTION)
    HistoryTab.PLAYBACK -> listOf(HistoryTab.COLLECTION, HistoryTab.UNIFIED)
    HistoryTab.COLLECTION -> listOf(HistoryTab.PLAYBACK, HistoryTab.UNIFIED)
}

/**
 * History tab — THREE views over two event streams (iOS `HistoryView` parity):
 *  • Unified (default) — song plays + collection activity interleaved newest-first.
 *  • Playback — the play timeline with search, sort (last-played asc/desc) and the
 *    played-between date-range filter (§6 P1 minimum).
 *  • Collection — the LIVE collection-activity log ([ActivityContent],
 *    specs/activity-favorites.md §5).
 *
 * The tab control is a custom TWO-button row of the views you're NOT in; tapping
 * one switches to it. The shared search query filters every view; sort + the
 * date-range filter stay Playback-only.
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

    // Default view is Unified; the two-button bar offers the other two (iOS parity).
    var tab by rememberSaveable { mutableStateOf(HistoryTab.UNIFIED) }

    // History-only search/sort/filter state (never shared with Browse's, §6.4).
    var query by rememberSaveable { mutableStateOf("") }
    var newestFirst by rememberSaveable { mutableStateOf(true) }
    var rangeStartMs by rememberSaveable { mutableStateOf<Long?>(null) }
    var rangeEndMs by rememberSaveable { mutableStateOf<Long?>(null) }
    var showSortMenu by remember { mutableStateOf(false) }
    var showRangeDialog by remember { mutableStateOf(false) }

    // Playback filter/sort compute over up to 20k rows runs off the main thread,
    // keyed on (history revision, catalog identity, filter/sort signature) — never
    // on events.size, which pins at the cap (specs/history.md §5).
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
            buildRows(events, catalog, store::playCount, query, newestFirst, rangeStartMs, rangeEndMs)
        }
    }

    Column(modifier = modifier.fillMaxSize()) {
        HistoryTabBar(current = tab, onSelect = { tab = it })

        // Search filters every view; sort + date-range controls are Playback-only.
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
            if (tab == HistoryTab.PLAYBACK) {
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
        }

        when (tab) {
            HistoryTab.UNIFIED -> UnifiedTimeline(
                playEvents = historyState.events,
                historyRevision = historyState.revision,
                playStore = store,
                catalog = catalog,
                query = query,
                onSongClick = onSongClick,
            )
            HistoryTab.PLAYBACK -> PlaysTimeline(
                rows = rows,
                hasAnyEvents = historyState.events.isNotEmpty(),
                onSongClick = onSongClick,
            )
            HistoryTab.COLLECTION -> ActivityContent(
                catalog = catalog,
                query = query,
                onSongClick = onSongClick,
            )
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

/**
 * Custom two-button tab control (not a fixed 3-segment picker): each button is a
 * DESTINATION — one of the two views you can switch TO — so the current view is
 * never shown. Tapping switches and the pair re-renders (iOS parity).
 */
@Composable
private fun HistoryTabBar(current: HistoryTab, onSelect: (HistoryTab) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        current.altTabs().forEach { destination ->
            OutlinedButton(
                onClick = { onSelect(destination) },
                modifier = Modifier
                    .weight(1f)
                    .testTag("history-tab-${destination.label.lowercase()}"),
            ) {
                Icon(
                    imageVector = destination.icon,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(destination.label)
            }
        }
    }
}

/**
 * Unified timeline (iOS parity): song plays + collection activity interleaved
 * newest-first, filtered by the shared [query]. Loads the activity store lazily
 * (its first read decodes the whole log — kept off-main, like [ActivityContent]);
 * merges off the main thread; renders a growing page prefix.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun UnifiedTimeline(
    playEvents: List<PlayEvent>,
    historyRevision: Int,
    playStore: PlayHistoryStore,
    catalog: MergedCatalog,
    query: String,
    onSongClick: (String) -> Unit,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }

    val activityStore by produceState<CollectionActivityStore?>(initialValue = null) {
        value = withContext(Dispatchers.IO) { graph.collectionActivity }
    }
    val store = activityStore ?: return
    val activityState by store.state.collectAsState()

    // Seed NULL so the first frame renders nothing rather than flashing the empty
    // state before the merge finishes on Dispatchers.Default. Keyed on both stream
    // revisions + catalog identity + query (never events.size — pins at the cap).
    val entriesOrNull by produceState<List<HistoryEntry>?>(
        initialValue = null,
        historyRevision,
        activityState.revision,
        catalog,
        query,
    ) {
        val plays = playEvents
        val acts = activityState.events
        value = withContext(Dispatchers.Default) {
            buildUnified(plays, acts, catalog, playStore::playCount, query)
        }
    }
    val entries = entriesOrNull ?: return

    if (entries.isEmpty()) {
        val hasAny = playEvents.isNotEmpty() || activityState.events.isNotEmpty()
        EmptyState(
            icon = Icons.Filled.History,
            title = if (hasAny) "Nothing matches your search" else "No history yet",
            caption = "Songs you play — and changes you make to your collections " +
                "(adds, hearts, removals) — show up here together.",
            testTag = if (hasAny) "history-unified-no-matches" else "history-unified-empty",
        )
        return
    }

    // Render a growing prefix (History can hold 20k+ combined events); a catalog
    // refresh must not reset a scrolled-in budget.
    var pageBudget by rememberSaveable { mutableIntStateOf(PAGE_SIZE) }
    val visible = if (entries.size > pageBudget) entries.subList(0, pageBudget) else entries

    LazyColumn(modifier = Modifier.fillMaxSize()) {
        items(visible, key = { it.id }) { entry ->
            when (entry) {
                is HistoryEntry.Play -> PlayRow(
                    row = entry.row,
                    onClick = { onSongClick(entry.row.songId) },
                )
                is HistoryEntry.Activity -> ActivityRow(
                    row = entry.row,
                    onSongClick = onSongClick,
                )
            }
        }
        if (entries.size > visible.size) {
            item(key = "unified-load-more") {
                // Composing the sentinel = the last page scrolled in; grow.
                LaunchedEffect(pageBudget) { pageBudget += PAGE_SIZE }
                Spacer(Modifier.height(48.dp))
            }
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
 * LIVE Collection segment (specs/activity-favorites.md §5): a reverse-chronological
 * list of collection acts — outside the Playback sort/date-range machinery but,
 * like every History view, honouring the shared search [query] (item title or
 * collection name). Rows resolve titles live-catalog-first (snapshot second), tap
 * through to song detail only when the item still resolves, and render all four
 * kinds even though P2 emits add/remove only.
 */
@Composable
private fun ActivityContent(
    catalog: MergedCatalog,
    query: String,
    onSongClick: (String) -> Unit,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }

    // First touch of the lazy store reads its JSON doc — keep it off-main.
    val activityStore by produceState<CollectionActivityStore?>(initialValue = null) {
        value = withContext(Dispatchers.IO) { graph.collectionActivity }
    }
    val store = activityStore ?: return
    val activityState by store.state.collectAsState()

    // Recompute keys off the store's revision (never events.size — pins at the
    // cap) plus catalog identity for live-title resolution and the search query.
    // Seed NULL (not empty) so the first frame renders nothing rather than
    // flashing the empty state before buildActivityRows finishes on Default.
    val rowsOrNull by produceState<List<ActivityRowUi>?>(
        initialValue = null,
        activityState.revision,
        catalog,
        query,
    ) {
        val events = activityState.events
        value = withContext(Dispatchers.Default) { buildActivityRows(events, catalog, query) }
    }
    val rows = rowsOrNull ?: return

    if (rows.isEmpty()) {
        EmptyState(
            icon = Icons.Filled.History,
            title = "No collection activity yet",
            caption = "Adding a song to a playlist or pocket, hearting a song, or removing one shows up here.",
            testTag = "history-activity-empty",
        )
        return
    }

    LazyColumn(modifier = Modifier.fillMaxSize()) {
        items(rows, key = { it.eventId }) { row ->
            ActivityRow(row = row, onSongClick = onSongClick)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ActivityRow(row: ActivityRowUi, onSongClick: (String) -> Unit) {
    // Tap → song detail only when the itemId resolves; otherwise inert.
    val songId = row.songId
    Surface(
        onClick = { songId?.let(onSongClick) },
        enabled = songId != null,
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("activity-row"),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            Icon(
                imageVector = row.kind.icon(),
                contentDescription = null,
                tint = if (row.kind == ActivityKind.HEART) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = row.headline,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onBackground,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text = relativeTime(row.atMs),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** Nearest Material icons to the iOS SF Symbols per kind (§2 mapping). */
private fun ActivityKind.icon(): ImageVector = when (this) {
    ActivityKind.ADD -> Icons.Filled.AddCircleOutline
    ActivityKind.HEART -> Icons.Filled.Favorite
    ActivityKind.UNHEART -> Icons.Filled.HeartBroken
    ActivityKind.REMOVE -> Icons.Filled.RemoveCircleOutline
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

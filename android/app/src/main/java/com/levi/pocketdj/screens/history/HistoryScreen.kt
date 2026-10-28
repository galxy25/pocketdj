package com.levi.pocketdj.screens.history

import android.text.format.DateUtils
import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.HeartBroken
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.activity.CollectionActivityStore
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.share.ShareText
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.BrowseFilterSheet
import com.levi.pocketdj.screens.browse.BrowseFilters
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.BrowseSortSheet
import com.levi.pocketdj.screens.browse.CollectionRef
import com.levi.pocketdj.screens.browse.FieldOptions
import com.levi.pocketdj.screens.browse.SongRow
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val PAGE_SIZE = 120

/**
 * The History tabs (iOS `HistoryView.HistoryTab`, 2026-08-10 shape). Declaration order IS the tab
 * order. Unified is gone (Rewind moved to Playback rows). Pockets / For You are gated on their
 * stores reporting enabled; every visible tab is shown, the current one selected.
 */
internal enum class HistoryTab(val label: String) {
    PLAYBACK("Playback"),
    COLLECTION("Collection"),
    POCKETS("Pockets"),
    FOR_YOU("For You"),
}

/** Which gated tabs the stores currently report enabled. Their packages flip these. */
internal object HistoryTabGate {
    @Volatile var pocketsEnabled: Boolean = false
    @Volatile var forYouEnabled: Boolean = false
}

/** Pure tab-visibility rule: Playback + Collection always; Pockets / For You only when enabled. */
internal fun visibleHistoryTabs(pocketsEnabled: Boolean, forYouEnabled: Boolean): List<HistoryTab> =
    buildList {
        add(HistoryTab.PLAYBACK)
        add(HistoryTab.COLLECTION)
        if (pocketsEnabled) add(HistoryTab.POCKETS)
        if (forYouEnabled) add(HistoryTab.FOR_YOU)
    }

/**
 * History tab: Playback | Collection (+ Pockets / For You when enabled). The Playback timeline runs
 * through [HistoryBrowseState] (the shared BrowseEngine over a base of one row per play event, its
 * own persisted filter/sort, the three `refreshExternal` guards). The Collection tab is the live
 * collection-activity log.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    modifier: Modifier = Modifier,
    onSongClick: (songId: String) -> Unit = {},
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    LaunchedEffect(Unit) { graph.catalogRepository.loadIfNeeded() }
    val catalogState by graph.catalogRepository.state.collectAsState()
    val catalog = catalogState.catalog ?: MergedCatalog.EMPTY

    var tab by rememberSaveable { mutableStateOf(HistoryTab.PLAYBACK) }
    val tabs = visibleHistoryTabs(HistoryTabGate.pocketsEnabled, HistoryTabGate.forYouEnabled)
    val current = if (tab in tabs) tab else HistoryTab.PLAYBACK

    val state = graph.browseGraph.historyBrowse
    val inputs by state.inputs.collectAsState()
    var showFilter by remember { mutableStateOf(false) }
    var showSort by remember { mutableStateOf(false) }

    Column(modifier = modifier.fillMaxSize()) {
        HistoryTabBar(tabs = tabs, current = current, onSelect = { tab = it })

        // Search is shared by Playback + Collection; sort/filter are Playback-only.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
        ) {
            OutlinedTextField(
                value = inputs.query,
                onValueChange = { state.setQuery(it) },
                singleLine = true,
                placeholder = { Text("Search title or artist") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = {
                    if (inputs.query.isNotEmpty()) {
                        IconButton(onClick = { state.setQuery("") }) {
                            Icon(Icons.Filled.Close, contentDescription = "Clear search")
                        }
                    }
                },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = {
                    // Explicit submit: drop both memos so this is a REAL search, even when the
                    // signature did not move (unstructured on purpose, like iOS).
                    state.submit()
                }),
                modifier = Modifier.weight(1f).testTag("history-search"),
            )
            if (current == HistoryTab.PLAYBACK) {
                IconButton(onClick = { showSort = true }, modifier = Modifier.testTag("history-sort")) {
                    Icon(Icons.AutoMirrored.Filled.Sort, contentDescription = "Sort")
                }
                IconButton(onClick = { showFilter = true }, modifier = Modifier.testTag("history-filter")) {
                    Icon(
                        Icons.Filled.FilterList,
                        contentDescription = "Filters",
                        tint = if (inputs.activeCount > 0) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }

        when (current) {
            HistoryTab.PLAYBACK -> PlaybackContent(
                graph = graph,
                state = state,
                catalog = catalog,
                onSongClick = onSongClick,
            )
            HistoryTab.COLLECTION -> ActivityContent(
                catalog = catalog,
                query = inputs.query,
                onSongClick = onSongClick,
            )
            HistoryTab.POCKETS -> EmptyState(
                icon = Icons.Filled.Layers,
                title = "Listening pockets",
                caption = "Pockets learned from your listening show up here.",
                testTag = "history-pockets",
            )
            HistoryTab.FOR_YOU -> EmptyState(
                icon = Icons.Filled.History,
                title = "For You",
                caption = "Recommendations from your history show up here.",
                testTag = "history-foryou",
            )
        }
    }

    if (showSort) {
        BrowseSortSheet(
            kind = BrowseKind.SONGS,
            sortKeys = inputs.sortKeys,
            onSortKeys = { state.setSortKeys(it) },
            onDismiss = { showSort = false },
            historyMode = true,
        )
    }
    if (showFilter) {
        val results by state.results.collectAsState()
        BrowseFilterSheet(
            kind = BrowseKind.SONGS,
            filters = BrowseFilters(clauses = inputs.clauses, hideSkips = inputs.hideSkips),
            optionsFor = { fieldId ->
                FieldOptions.of(fieldId, results.allRows, catalog.availableSources)
            },
            historyMode = true,
            playlists = emptyList<CollectionRef>(),
            pockets = emptyList<CollectionRef>(),
            onFilters = { f -> state.update { it.copy(clauses = f.clauses, hideSkips = f.hideSkips) } },
            onDismiss = { showFilter = false },
        )
    }
}

/** Segmented tab control: every visible tab shown, the current one selected. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryTabBar(tabs: List<HistoryTab>, current: HistoryTab, onSelect: (HistoryTab) -> Unit) {
    SingleChoiceSegmentedButtonRow(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        tabs.forEachIndexed { i, t ->
            SegmentedButton(
                selected = t == current,
                onClick = { onSelect(t) },
                shape = SegmentedButtonDefaults.itemShape(index = i, count = tabs.size),
                modifier = Modifier.testTag("history-tab-${t.label.lowercase().replace(' ', '-')}"),
            ) { Text(t.label, maxLines = 1) }
        }
    }
}

/** The Playback timeline: recompute pipeline + paged rows + row chrome + rewind confirm. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlaybackContent(
    graph: AppGraph,
    state: HistoryBrowseState,
    catalog: MergedCatalog,
    onSongClick: (String) -> Unit,
) {
    val context = LocalContext.current
    val store = remember { com.levi.pocketdj.data.history.PlayHistoryStore.get(context) }
    val historyState by store.state.collectAsState()
    val inputs by state.inputs.collectAsState()
    val results by state.results.collectAsState()
    val scope = rememberCoroutineScope()

    // Recompute: signature = catalog identity + event-log revision + inputs. The base binds BEFORE
    // the recompute (guard 3); the effect restarts (cancelling the prior run) when it moves.
    val catalogId = System.identityHashCode(catalog)
    val signature = "$catalogId-${historyState.revision}-${inputs.signature()}"
    val baseKey = "$catalogId-${historyState.revision}-${inputs.hideSkips}"
    LaunchedEffect(signature, inputs.submitNonce) {
        val events = historyState.events
        state.externalBase = {
            buildItems(
                events = events,
                catalog = catalog,
                hideSkips = state.inputs.value.hideSkips,
                playCountOf = store::playCount,
                isFromAnotherDevice = store::isFromAnotherDevice,
            )
        }
        state.playCounts = if (inputs.usesPlayCounts) {
            withContext(Dispatchers.Default) {
                events.asSequence().map { it.songId }.distinct().associateWith(store::playCount)
            }
        } else emptyMap()
        state.refreshExternal(signature, baseKey)
    }

    val liveEventId by remember { graph.playbackGraph.skipTracker.currentEventIdState }.collectAsState()
    val nowPlaying by graph.playbackController.nowPlaying.collectAsState()
    val playing = nowPlaying?.isPlaying == true

    var menuEventId by remember { mutableStateOf<String?>(null) }
    var rewindEventId by remember { mutableStateOf<String?>(null) }
    var addToSongId by remember { mutableStateOf<String?>(null) }

    val rows = results.rows
    if (rows.isEmpty()) {
        // Distinguish "nothing recorded" from "everything filtered out".
        if (historyState.events.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.History,
                title = "No plays yet",
                caption = "Songs you play in a Mix, Playlist, Pocket, Set list, or the Browser show up here.",
                testTag = "history-empty",
            )
        } else {
            EmptyState(
                icon = Icons.Filled.History,
                title = "No matches",
                caption = "No plays match the search or filters.",
                testTag = "history-no-matches",
            )
        }
    } else {
        // Paging budget survives a catalog refresh: the key excludes catalog identity.
        val pagingKey = state.pagingKey(historyState.revision, rows.size)
        var pageBudget by rememberSaveable(pagingKey) { mutableIntStateOf(PAGE_SIZE) }
        val visible = if (rows.size > pageBudget) rows.subList(0, pageBudget) else rows
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(visible, key = { results.refOf(it)?.eventId ?: it.song.id + it.playedAt }) { row ->
                val ref = results.refOf(row) ?: return@items
                val live = isLiveRow(ref, liveEventId, playing)
                Box {
                    PlayRow(
                        row = row,
                        ref = ref,
                        live = live,
                        onClick = { onSongClick(ref.songId) },
                        onLongClick = { menuEventId = ref.eventId },
                    )
                    HistoryRowMenu(
                        expanded = menuEventId == ref.eventId,
                        ref = ref,
                        onDismiss = { menuEventId = null },
                        onAction = { action ->
                            when (action) {
                                HistoryRowAction.REWIND -> rewindEventId = ref.eventId
                                HistoryRowAction.ADD_TO -> addToSongId = ref.songId
                                HistoryRowAction.SHARE -> {
                                    val song = catalog.songsById[ref.songId]
                                    val text = song?.let { ShareText.forSong(it) }
                                        ?: ShareText.forTitleArtist(row.song.name, row.song.artist)
                                    ShareText.send(context, text, "${row.song.name} — ${row.song.artist}")
                                }
                            }
                        },
                    )
                }
            }
            if (rows.size > visible.size) {
                item(key = "history-load-more") {
                    LaunchedEffect(pageBudget) { pageBudget += PAGE_SIZE }
                    Spacer(Modifier.height(48.dp))
                }
            }
        }
    }

    rewindEventId?.let { id ->
        val replacesLive = graph.playbackGraph.sequencer.state.value.isRunning
        AlertDialog(
            onDismissRequest = { rewindEventId = null },
            title = { Text("Rewind playback?") },
            text = {
                Text(
                    if (replacesLive) "This replaces what's playing and restarts from here."
                    else "Playback restarts from here.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        rewindEventId = null
                        scope.launch {
                            // Re-read the log at EXECUTE time: a merge can change it under the dialog.
                            val result = performRewind(graph, id, store.state.value.events)
                            if (result is RewindResult.Failed) {
                                Toast.makeText(context, result.message, Toast.LENGTH_SHORT).show()
                            }
                        }
                    },
                    modifier = Modifier.testTag("history-rewind-confirm"),
                ) { Text("Rewind to here") }
            },
            dismissButton = { TextButton(onClick = { rewindEventId = null }) { Text("Cancel") } },
        )
    }
    addToSongId?.let { id ->
        AddToCollectionSheet(item = AddToItem.Song(id), onDismiss = { addToSongId = null })
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PlayRow(
    row: SongRow,
    ref: PlayRef,
    live: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    Surface(
        color = if (live) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f)
        else MaterialTheme.colorScheme.background,
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .testTag("history-row-${ref.eventId}" + if (live) "-live" else ""),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ArtThumb(ref.artUrl)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = row.song.name,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onBackground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = row.song.artist,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                ContextLine(ref)
            }
            if (live) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.VolumeUp,
                    contentDescription = "playing",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 8.dp).size(20.dp).testTag("history-live-${ref.eventId}"),
                )
            }
            if (ref.wasSkipped) {
                Spacer(Modifier.width(8.dp))
                Chip("skipped", "history-skipped-${ref.eventId}")
            }
            if (ref.count > 1) {
                Spacer(Modifier.width(8.dp))
                Chip("${ref.count} plays", "history-count-${ref.songId}")
            }
        }
    }
}

@Composable
private fun Chip(text: String, tag: String) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(50),
        modifier = Modifier.testTag(tag),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
        )
    }
}

/** `[source-icon] {Source} · {contextName} · on another device · {relative time}`. */
@Composable
private fun ContextLine(ref: PlayRef) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = ref.source.icon(),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(13.dp),
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = "${contextLabel(ref)} · ${relativeTime(ref.playedAtMs)}",
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
    ActivityKind.CATALOG_ADD -> Icons.Filled.Download
    ActivityKind.CATALOG_REMOVE -> Icons.Filled.Delete
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
    PlaySource.GAME -> Icons.Filled.SportsEsports
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

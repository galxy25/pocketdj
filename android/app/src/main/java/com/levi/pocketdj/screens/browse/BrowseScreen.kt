package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ViewList
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Rows rendered per page of the incremental list (specs/browse.md §4.1). */
private const val PAGE_SIZE = 120

/** One filtered result set; [version] keys the paging budget reset. */
private data class BrowseResults(
    val albums: List<AlbumRow> = emptyList(),
    val songs: List<SongRow> = emptyList(),
    val version: Int = 0,
)

/**
 * Browse — the P1 surface (specs/browse.md §11 build target): sources rail →
 * Albums grid / Songs list toggle → on-device search → filter sheet
 * (genre/bpm/key/source) → album detail via [onOpenAlbum] → song detail sheet.
 *
 * The integrator wires [onOpenAlbum] to the album-detail destination.
 */
@Composable
fun BrowseScreen(
    onOpenAlbum: (albumId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(Unit) {
        graph.catalogRepository.loadIfNeeded()
        graph.ripsRepository.loadAtLaunch()
    }

    val catalogState by graph.catalogRepository.state.collectAsState()
    val kind by BrowseSession.kind.collectAsState()
    val layout by BrowseSession.layout.collectAsState()
    val query by BrowseSession.query.collectAsState()
    val filters by BrowseSession.filters.collectAsState()
    val sortKeys by BrowseSession.sortKeys.collectAsState()

    var showFilterSheet by remember { mutableStateOf(false) }
    var showSortSheet by remember { mutableStateOf(false) }
    var detailSongId by remember { mutableStateOf<String?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        when {
            catalogState.catalog == null &&
                (catalogState.phase == CatalogRepository.Phase.Loading ||
                    catalogState.phase == CatalogRepository.Phase.Idle) -> {
                LoadingState(Modifier.align(Alignment.Center))
            }

            catalogState.catalog == null && catalogState.phase == CatalogRepository.Phase.Failed -> {
                ErrorState(
                    message = catalogState.error ?: "Couldn't load the catalog",
                    onRetry = { graph.catalogRepository.refresh() },
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            else -> {
                val catalog = catalogState.catalog ?: MergedCatalog.EMPTY
                BrowseContent(
                    catalog = catalog,
                    kind = kind,
                    layout = layout,
                    query = query,
                    filters = filters,
                    sortKeys = sortKeys,
                    isRefreshing = catalogState.isRefreshing,
                    onKind = { BrowseSession.kind.value = it },
                    onLayout = { BrowseSession.layout.value = it },
                    onQuery = { BrowseSession.query.value = it },
                    onFilters = { BrowseSession.filters.value = it },
                    onShowFilters = { showFilterSheet = true },
                    onShowSort = { showSortSheet = true },
                    onOpenAlbum = onOpenAlbum,
                    onOpenSong = { detailSongId = it },
                    onPlaySong = { songId ->
                        // Songs-list ▶ with no album in view = a Browser single
                        // (specs/history.md §4) — never an album-context queue.
                        scope.launch {
                            playAndReport(
                                graph.playbackController,
                                songId,
                                snackbar,
                                queueAlbumContext = false,
                            )
                        }
                    },
                )
            }
        }

        SnackbarHost(hostState = snackbar, modifier = Modifier.align(Alignment.BottomCenter))
    }

    if (showFilterSheet) {
        val rows = catalogState.catalog?.let { remember(it) { BrowseRows.of(it) } }
        BrowseFilterSheet(
            filters = filters,
            genreOptions = rows?.genreOptions.orEmpty(),
            camelotOptions = rows?.camelotOptions.orEmpty(),
            sourceOptions = catalogState.catalog?.availableSources.orEmpty(),
            onFilters = { BrowseSession.filters.value = it },
            onDismiss = { showFilterSheet = false },
        )
    }

    if (showSortSheet) {
        BrowseSortSheet(
            kind = kind,
            sortKeys = sortKeys,
            onSortKeys = { BrowseSession.sortKeys.value = it },
            onDismiss = { showSortSheet = false },
        )
    }

    detailSongId?.let { songId ->
        SongDetailSheet(
            songId = songId,
            onDismiss = { detailSongId = null },
            snackbar = snackbar,
            onOpenAlbum = onOpenAlbum,
        )
    }
}

@Composable
private fun BrowseContent(
    catalog: MergedCatalog,
    kind: BrowseKind,
    layout: AlbumLayout,
    query: String,
    filters: BrowseFilters,
    sortKeys: List<SortKey>,
    isRefreshing: Boolean,
    onKind: (BrowseKind) -> Unit,
    onLayout: (AlbumLayout) -> Unit,
    onQuery: (String) -> Unit,
    onFilters: (BrowseFilters) -> Unit,
    onShowFilters: () -> Unit,
    onShowSort: () -> Unit,
    onOpenAlbum: (String) -> Unit,
    onOpenSong: (String) -> Unit,
    onPlaySong: (String) -> Unit,
) {
    // Debounced query (~180 ms, specs/browse.md §4.1).
    var debouncedQuery by remember { mutableStateOf(query) }
    LaunchedEffect(query) {
        if (query != debouncedQuery) {
            delay(180)
            debouncedQuery = query
        }
    }

    // Filter + search off the main thread; a new result set carries a new
    // version so the paging budget resets in the same frame (§13).
    var resultVersion by remember { mutableIntStateOf(0) }
    val results by produceState(
        initialValue = BrowseResults(),
        catalog, kind, debouncedQuery, filters, sortKeys,
    ) {
        value = withContext(Dispatchers.Default) {
            // Pipeline (§4.1): base rows → text query → filter clauses → sort.
            // Filter AND sort both run here off the main thread; a ~90k-row
            // locale-aware pass on the UI thread was a shipped runloop hang (§13).
            val rows = BrowseRows.of(catalog)
            when (kind) {
                BrowseKind.ALBUMS -> BrowseResults(
                    albums = BrowseSort.albums(rows.filteredAlbums(debouncedQuery, filters), sortKeys),
                    version = ++resultVersion,
                )
                BrowseKind.SONGS -> BrowseResults(
                    songs = BrowseSort.songs(rows.filteredSongs(debouncedQuery, filters), sortKeys),
                    version = ++resultVersion,
                )
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        SourcesRail(
            sources = catalog.availableSources,
            selected = filters.sources,
            onSelect = { selection -> onFilters(filters.copy(sources = selection)) },
        )

        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
        ) {
            SingleChoiceSegmentedButtonRow(modifier = Modifier.weight(1f)) {
                BrowseKind.entries.forEachIndexed { index, entry ->
                    SegmentedButton(
                        selected = kind == entry,
                        onClick = { onKind(entry) },
                        shape = SegmentedButtonDefaults.itemShape(index, BrowseKind.entries.size),
                    ) {
                        Text(if (entry == BrowseKind.ALBUMS) "Albums" else "Songs")
                    }
                }
            }
            if (kind == BrowseKind.ALBUMS) {
                IconButton(
                    onClick = {
                        onLayout(if (layout == AlbumLayout.GRID) AlbumLayout.LIST else AlbumLayout.GRID)
                    },
                ) {
                    Icon(
                        if (layout == AlbumLayout.GRID) {
                            Icons.AutoMirrored.Filled.ViewList
                        } else {
                            Icons.Filled.GridView
                        },
                        contentDescription = "Toggle album layout",
                    )
                }
            }
            IconButton(onClick = onShowSort) {
                Icon(
                    Icons.Filled.SwapVert,
                    contentDescription = "Sort",
                    tint = if (sortKeys.isNotEmpty()) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
            }
            BadgedBox(
                badge = {
                    if (filters.activeCount > 0) Badge { Text(filters.activeCount.toString()) }
                },
            ) {
                IconButton(onClick = onShowFilters) {
                    Icon(
                        Icons.Filled.FilterList,
                        contentDescription = "Filters",
                        tint = if (filters.activeCount > 0) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurface
                        },
                    )
                }
            }
        }

        OutlinedTextField(
            value = query,
            onValueChange = onQuery,
            singleLine = true,
            placeholder = { Text(if (kind == BrowseKind.ALBUMS) "Search albums" else "Search songs") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (query.isNotEmpty()) {
                    IconButton(onClick = { onQuery("") }) {
                        Icon(Icons.Filled.Close, contentDescription = "Clear search")
                    }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 4.dp),
        )

        // Results header: "<count> albums|songs" (+ refresh spinner in place).
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            val count = if (kind == BrowseKind.ALBUMS) results.albums.size else results.songs.size
            Text(
                text = "$count " + if (kind == BrowseKind.ALBUMS) "albums" else "songs",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.width(8.dp))
            // Active-sort summary — "BPM › Artist" style (iOS results header).
            if (sortKeys.isNotEmpty()) {
                Icon(
                    Icons.Filled.SwapVert,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(13.dp),
                )
                Spacer(Modifier.width(3.dp))
                Text(
                    text = sortKeys.joinToString(" › ") { it.field.label },
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
            }
            Spacer(Modifier.weight(1f))
            if (isRefreshing) {
                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
            }
        }

        // Incremental paging: budget keyed by the result-set version so a new
        // result set never renders the previous set's large prefix (§13).
        var pageCount by remember(results.version) { mutableIntStateOf(1) }
        val emptyMessage = when {
            query.isNotBlank() || filters.activeCount > 0 -> "No matches — adjust search or filters"
            else -> "Nothing here yet — pull the catalog from Settings"
        }

        when (kind) {
            BrowseKind.ALBUMS -> {
                val visible = results.albums.take(pageCount * PAGE_SIZE)
                if (results.albums.isEmpty()) {
                    EmptyState(emptyMessage)
                } else if (layout == AlbumLayout.GRID) {
                    LazyVerticalGrid(
                        columns = GridCells.Adaptive(minSize = 150.dp),
                        contentPadding = PaddingValues(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(visible, key = { it.album.id }) { row ->
                            AlbumGridCard(row, onClick = { onOpenAlbum(row.album.id) })
                        }
                        if (visible.size < results.albums.size) {
                            item(key = "pager") {
                                PagingTrigger(visible.size) { pageCount += 1 }
                            }
                        }
                    }
                } else {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(visible, key = { it.album.id }) { row ->
                            AlbumListRow(row, onClick = { onOpenAlbum(row.album.id) })
                        }
                        if (visible.size < results.albums.size) {
                            item(key = "pager") {
                                PagingTrigger(visible.size) { pageCount += 1 }
                            }
                        }
                    }
                }
            }

            BrowseKind.SONGS -> {
                val visible = results.songs.take(pageCount * PAGE_SIZE)
                if (results.songs.isEmpty()) {
                    EmptyState(emptyMessage)
                } else {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(visible, key = { it.song.id }) { row ->
                            BrowseSongRow(
                                row = row,
                                onClick = { onOpenSong(row.song.id) },
                                onPlay = { onPlaySong(row.song.id) },
                            )
                        }
                        if (visible.size < results.songs.size) {
                            item(key = "pager") {
                                PagingTrigger(visible.size) { pageCount += 1 }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Sources rail: "All" + one chip per source = a source filter shortcut (§11). */
@Composable
private fun SourcesRail(
    sources: List<String>,
    selected: Set<String>,
    onSelect: (Set<String>) -> Unit,
) {
    if (sources.size < 2) return
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        item(key = "all") {
            FilterChip(
                selected = selected.isEmpty(),
                onClick = { onSelect(emptySet()) },
                label = { Text("All") },
            )
        }
        items(sources, key = { it }) { source ->
            FilterChip(
                selected = selected == setOf(source),
                onClick = { onSelect(setOf(source)) },
                label = { Text(source) },
            )
        }
    }
}

/**
 * Sentinel row that grows the page budget the moment it renders (§13). Keyed on
 * the current visible count so it re-fires when the budget grows but the
 * sentinel never left composition (short remainder pages).
 */
@Composable
private fun PagingTrigger(visibleCount: Int, onGrow: () -> Unit) {
    LaunchedEffect(visibleCount) { onGrow() }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
    }
}

@Composable
private fun AlbumGridCard(row: AlbumRow, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth(),
    ) {
        AlbumArt(
            row.album,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f),
            cornerRadius = 8,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            row.album.name,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            row.album.artist,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        MetaTag(
            listOfNotNull(row.genreCategory, row.album.year?.toString()).joinToString(" · "),
        )
    }
}

@Composable
private fun AlbumListRow(row: AlbumRow, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        AlbumArt(row.album, modifier = Modifier.size(52.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                row.album.name,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                row.album.artist,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(8.dp))
        MetaTag(
            listOfNotNull(row.genreCategory, row.album.year?.toString()).joinToString(" · "),
        )
    }
}

/**
 * Song row (§3): thumbnail, title (+E), artist · album, BPM, key chip,
 * duration, play affordance. Metadata-only rows are dimmed with no ▶
 * (sources-reality rule).
 */
@Composable
fun BrowseSongRow(
    row: SongRow,
    onClick: () -> Unit,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
    zebra: Boolean = false,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val preparingId by graph.playbackController.preparingSongId.collectAsState()

    val playable = playability(row.song.id, manifest, settings?.hasRipServer == true)
    val contentAlpha = if (playable == Playability.NONE) 0.45f else 1f

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .let { base ->
                if (zebra) {
                    base.background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                } else {
                    base
                }
            }
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    row.song.name,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = contentAlpha),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (row.song.explicit == true) {
                    Spacer(Modifier.width(6.dp))
                    ExplicitBadge()
                }
            }
            Text(
                listOfNotNull(row.song.artist, row.albumName).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = contentAlpha),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            Fmt.bpm(row.song.bpm),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(30.dp),
        )
        KeyChip(row.song.key?.takeIf { row.song.camelot == null }, row.song.camelot)
        Spacer(Modifier.width(6.dp))
        Text(
            Fmt.duration(row.song.length),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        when {
            preparingId == row.song.id -> {
                Spacer(Modifier.width(10.dp))
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(10.dp))
            }

            playable != Playability.NONE -> {
                IconButton(onClick = onPlay) {
                    Icon(
                        Icons.Filled.PlayArrow,
                        contentDescription = "Play",
                        tint = if (playable == Playability.STREAM) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            // Rip-on-demand ▶ — possible but slower; render dimmer.
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
            }

            else -> Spacer(Modifier.width(12.dp))
        }
    }
}

@Composable
private fun LoadingState(modifier: Modifier = Modifier) {
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator()
        Spacer(Modifier.height(12.dp))
        Text(
            "Loading catalog…",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ErrorState(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier = modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Couldn't load the catalog", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(6.dp))
        Text(
            message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(12.dp))
        Button(onClick = onRetry) { Text("Retry") }
    }
}

@Composable
private fun EmptyState(message: String) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

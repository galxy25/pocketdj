package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
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
import com.levi.pocketdj.data.artists.Artist
import com.levi.pocketdj.data.artists.ArtistCatalog
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.catalog.CatalogRepository
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.favorites.FavoriteFilter
import com.levi.pocketdj.data.search.OnlineSearchModel
import com.levi.pocketdj.screens.discover.DiscoverPane
import com.levi.pocketdj.data.search.SearchSettings
import com.levi.pocketdj.di.AppGraph
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CloudQueue
import com.levi.pocketdj.ui.FavoriteToggle
import com.levi.pocketdj.screens.collections.AddToCollectionSheet
import com.levi.pocketdj.screens.collections.AddToItem
import com.levi.pocketdj.screens.collections.AddToPlaylistMenu
import com.levi.pocketdj.ui.selection.SelectionBar
import com.levi.pocketdj.ui.selection.SelectionScope
import com.levi.pocketdj.ui.selection.SelectionBarSemantics
import com.levi.pocketdj.ui.selection.SongTransfer
import com.levi.pocketdj.ui.selection.writeSongTransfer
import com.levi.pocketdj.ui.selection.selectionDecor
import com.levi.pocketdj.ui.selection.selectionTap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** RowSelection scope for the Browse Songs list. */
internal const val BROWSE_SELECTION_SCOPE = "browse"

/** Rows rendered per page of the incremental list (specs/browse.md §4.1). */
private const val PAGE_SIZE = 120

/** One filtered result set; [version] keys the paging budget reset. */
private data class BrowseResults(
    val albums: List<AlbumRow> = emptyList(),
    val songs: List<SongRow> = emptyList(),
    val artists: List<Artist> = emptyList(),
    val version: Int = 0,
)

/**
 * Browse — the P1 surface (specs/browse.md §11 build target): sources rail →
 * Albums grid / Songs list toggle → on-device search → filter sheet
 * (genre/bpm/key/source) → album detail via [onOpenAlbum] → song detail sheet.
 *
 * The integrator wires [onOpenAlbum] to the album-detail destination and
 * [onOpenArtist] to the artist-detail destination (specs/artists.md §7). The
 * artist callback defaults to a no-op so the composition root can adopt the
 * Artists kind on its own schedule; wire it to keep the segment tappable.
 */
@Composable
fun BrowseScreen(
    onOpenAlbum: (albumId: String) -> Unit,
    onOpenArtist: (artistName: String) -> Unit = {},
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
    val searchMode by BrowseSession.searchMode.collectAsState()

    var showFilterSheet by remember { mutableStateOf(false) }
    var showSortSheet by remember { mutableStateOf(false) }
    var detailSongId by remember { mutableStateOf<String?>(null) }
    // Long-press add-to-collection target (specs/playlists-ui.md §8; the
    // long-press launch point is an Android addition to the iOS ＋-only set).
    var addItem by remember { mutableStateOf<AddToItem?>(null) }
    var addSheetOpen by remember { mutableStateOf(false) }

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
                    searchMode = searchMode,
                    onSearchMode = { BrowseSession.searchMode.value = it },
                    isRefreshing = catalogState.isRefreshing,
                    onKind = { BrowseSession.kind.value = it },
                    onLayout = { BrowseSession.layout.value = it },
                    onQuery = { BrowseSession.query.value = it },
                    onFilters = { BrowseSession.filters.value = it },
                    onShowFilters = { showFilterSheet = true },
                    onShowSort = { showSortSheet = true },
                    onOpenAlbum = onOpenAlbum,
                    onOpenArtist = onOpenArtist,
                    onOpenSong = { detailSongId = it },
                    onAddSong = { addItem = AddToItem.Song(it) },
                    onAddAlbum = { addItem = AddToItem.Album(it) },
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
        val rows = catalogState.catalog?.takeIf { kind != BrowseKind.ARTISTS }?.let { remember(it) { BrowseRows.of(it) } }
        val sheetCollections = remember { AppGraph.get(context).collections }
        val collState by sheetCollections.state.collectAsState()
        val sources = catalogState.catalog?.availableSources.orEmpty()
        val artistRows = catalogState.catalog?.takeIf { kind == BrowseKind.ARTISTS }?.let { remember(it) { ArtistCatalog.of(it).artists.map(::ArtistRow) } }
        BrowseFilterSheet(
            kind = kind,
            filters = filters,
            optionsFor = { fieldId ->
                val base: List<BrowseRow> = when (kind) {
                    BrowseKind.ALBUMS -> rows?.albumRows.orEmpty()
                    BrowseKind.SONGS -> rows?.songRows.orEmpty()
                    BrowseKind.ARTISTS -> artistRows.orEmpty()
                }
                FieldOptions.of(fieldId, base, sources)
            },
            showFavorite = kind == BrowseKind.SONGS,
            playlists = collState.playlists.sortedBy { it.name.lowercase() }.map { CollectionRef(it.id, it.name) },
            pockets = collState.pockets.sortedBy { it.name.lowercase() }.map { CollectionRef(it.id, it.name) },
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

    // Long-press → "Add to Playlist" submenu (top-5 ✓ toggles + More…); More… opens the full
    // sheet with the search field focused.
    addItem?.let { item ->
        if (addSheetOpen) {
            AddToCollectionSheet(
                item = item,
                searchFirst = true,
                onDismiss = { addItem = null; addSheetOpen = false },
            )
        } else {
            val songId = (item as? AddToItem.Song)?.id
            val ctx = LocalContext.current
            val sel = remember { graph.collectionsGraph.rowSelection }
            val extras = if (songId == null) emptyList() else listOf<Pair<String, () -> Unit>>(
                "Select" to { sel.enterSelectMode(BROWSE_SELECTION_SCOPE, songId) },
                "Copy" to {
                    val st = sel.state.value
                    val picked = if (st.scopeId == BROWSE_SELECTION_SCOPE) sel.currentPayload()?.songIds else null
                    val ids = SelectionBarSemantics.rowOrSelectionIds(picked, songId)
                    val songs = catalogState.catalog?.songsById.orEmpty()
                    writeSongTransfer(ctx, SongTransfer.make(ids, songs))
                },
            )
            AddToPlaylistMenu(
                item = item,
                onDismiss = { addItem = null },
                onMore = { addSheetOpen = true },
                extraActions = extras,
            )
        }
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
    searchMode: SearchMode,
    onSearchMode: (SearchMode) -> Unit,
    isRefreshing: Boolean,
    onKind: (BrowseKind) -> Unit,
    onLayout: (AlbumLayout) -> Unit,
    onQuery: (String) -> Unit,
    onFilters: (BrowseFilters) -> Unit,
    onShowFilters: () -> Unit,
    onShowSort: () -> Unit,
    onOpenAlbum: (String) -> Unit,
    onOpenArtist: (String) -> Unit,
    onOpenSong: (String) -> Unit,
    onAddSong: (String) -> Unit,
    onAddAlbum: (String) -> Unit,
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

    // Lifetime play counts are the one pipeline input living outside the catalog
    // (device-local store): snapshot them, and fold the revision into the key
    // ONLY while a clause/sort actually reads them.
    val context = LocalContext.current
    val history = remember { PlayHistoryStore.get(context) }
    val usesPlayCounts = filters.usesPlayCounts(sortKeys)
    val historyRevision = if (usesPlayCounts) history.state.collectAsState().value.revision else -1
    val resultsKey = BrowseEngine.resultsKey(
        catalogIdentity = System.identityHashCode(catalog).toLong(),
        kind = kind,
        query = debouncedQuery,
        clauses = filters.clauses,
        sortKeys = sortKeys,
        playCountsRevision = historyRevision,
    )

    // Filter + search + sort off the main thread; a new result set carries a new
    // version so the paging budget resets in the same frame (§13).
    var resultVersion by remember { mutableIntStateOf(0) }
    // Favorite tri-state: applied at READ time against the live ♥ set, outside the memoized
    // resultsKey. The revision is collected (and folded into the produceState keys) only while
    // the filter is active, so ♥ taps elsewhere never recompute an inactive pipeline.
    val favStore = remember { AppGraph.get(context).collectionsGraph.favorites }
    val collStore = remember { AppGraph.get(context).collections }
    val favoriteFilter = if (kind == BrowseKind.SONGS) filters.favorite else FavoriteFilter.ANY
    val membership = if (kind == BrowseKind.SONGS) filters.membership else MembershipFilter()
    val favRevision = if (favoriteFilter != FavoriteFilter.ANY) {
        favStore.state.collectAsState().value.revision
    } else {
        -1
    }
    val collRevision = if (membership.active) collStore.state.collectAsState().value.revision else -1
    // ---- Online (OpenSearch) mode: Albums/Songs only; Artists is always on-device. ----
    val online = searchMode == SearchMode.ONLINE && kind != BrowseKind.ARTISTS
    val discover = searchMode == SearchMode.DISCOVER
    val onlineGraph = remember { AppGraph.get(context) }
    val onlineScope = rememberCoroutineScope()
    val onlineModel = remember { OnlineSearchModel(onlineGraph.browseGraph.searchService, onlineScope) }
    val secretsRev by onlineGraph.secrets.revision.collectAsState(initial = 0L)
    // null = not read yet (no false "add credentials" error); Some(null) = read, none configured.
    val onlineCredsLoad by produceState<List<com.levi.pocketdj.net.SigV4.Creds?>?>(null, secretsRev) {
        value = listOf(withContext(Dispatchers.IO) { SearchSettings.creds(onlineGraph.secrets) })
    }
    val onlineCreds = onlineCredsLoad?.firstOrNull()
    val onlineUi by onlineModel.ui.collectAsState()
    // Any query/kind/filter/SORT change (or creds change) RESETS and reloads page 1 (300 ms debounce
    // lives in the model); leaving online mode cancels in-flight work.
    LaunchedEffect(online, kind, query, filters.clauses, sortKeys, onlineCredsLoad) {
        if (online && onlineCredsLoad == null) {
            // credentials still loading: wait
        } else if (online) {
            onlineModel.searchDebounced(query, kind, filters.clauses, sortKeys, onlineCreds)
        } else {
            onlineModel.cancel()
        }
    }

    val results by produceState(initialValue = BrowseResults(), if (online) "online" else if (discover) "discover" else resultsKey) {
        // iOS parity: the heavy local filter/sort never runs in online mode.
        if (online || discover) return@produceState
        value = withContext(Dispatchers.Default) {
            // Pipeline (§4.1): base rows → text query → filter clauses → sort,
            // all in BrowseEngine.filterSort. A ~90k-row locale-aware pass on
            // the UI thread was a shipped runloop hang (§13).
            val rows = BrowseRows.of(catalog)
            val playCounts = if (usesPlayCounts) {
                rows.songRows.asSequence()
                    .map { it.song.id }
                    .associateWith(history::playCount)
                    .filterValues { it > 0 }
            } else {
                emptyMap()
            }
            val clauses = filters.clauses
            when (kind) {
                BrowseKind.ALBUMS -> BrowseResults(
                    albums = BrowseEngine.filterSort(
                        rows.albumRows, rows.albumKeys, debouncedQuery, clauses, sortKeys,
                    ),
                    version = ++resultVersion,
                )
                BrowseKind.SONGS -> BrowseResults(
                    songs = rows.songResults(
                        // Favorites + membership are READ-TIME layers (applied below), so the
                        // memoized pipeline — and the paging reset — ignore store contents.
                        debouncedQuery, filters.copy(favorite = FavoriteFilter.ANY), sortKeys, playCounts,
                        emptySet(),
                    ),
                    version = ++resultVersion,
                )
                BrowseKind.ARTISTS -> {
                    val artistRows = ArtistCatalog.of(catalog).artists.map(::ArtistRow)
                    BrowseResults(
                        artists = BrowseEngine.filterSort(
                            artistRows, artistRows.map { it.searchKey },
                            debouncedQuery, clauses, sortKeys,
                        ).map { it.artist },
                        version = ++resultVersion,
                    )
                }
            }
        }
    }

    // Read-time layers over the already filtered+sorted rows: cheap Set lookups, never memoized.
    val shownSongs = remember(results.songs, membership, favoriteFilter, favRevision, collRevision) {
        ReadTimeFilters.apply(
            rows = results.songs,
            membership = membership,
            allCollectionIds = (collStore.playlists.map { it.id } + collStore.pockets.map { it.id }).toSet(),
            membersOf = { id ->
                if (id.startsWith("pkt_")) collStore.songIdsForPocket(id) else collStore.songIdsForPlaylist(id)
            },
            favorite = favoriteFilter,
            favoriteIds = favStore.favoriteIds,
        )
    }
    // Paging resets when the CONSTRAINT changes (selection / mode), never when store contents do.
    val pagingKey = "${results.version}|${favoriteFilter.name}|${membership.selectionKey()}"

    // Multi-select (COL-5): Songs list only, never in online mode. The registered universe is the
    // FULL filtered list (shownSongs), not the rendered page.
    val rowSelection = remember { AppGraph.get(context).collectionsGraph.rowSelection }
    val selectable = kind == BrowseKind.SONGS && !online && !discover
    if (selectable) {
        SelectionScope(
            selection = rowSelection,
            scope = BROWSE_SELECTION_SCOPE,
            pruneKey = System.identityHashCode(shownSongs),
            allIds = { shownSongs.map { it.song.id } },
            payload = {
                val ordered = rowSelection.orderedSelection(shownSongs.map { it.song.id })
                SongTransfer.make(ordered, catalog.songsById)
            },
        )
    }

    Column(Modifier.fillMaxSize()) {
        if (selectable) SelectionBar(rowSelection, BROWSE_SELECTION_SCOPE, collStore)
        if (!discover) SourcesRail(
            sources = catalog.availableSources,
            selected = filters.sources,
            onSelect = { selection -> onFilters(filters.withSources(selection)) },
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
                        selected = kind == entry && !discover,
                        onClick = {
                            // Leaving Discover returns to device mode (Discover is a search mode, not a kind).
                            if (discover) onSearchMode(SearchMode.DEVICE)
                            onKind(entry)
                        },
                        shape = SegmentedButtonDefaults.itemShape(index, BrowseKind.entries.size + 1),
                    ) {
                        Text(
                            when (entry) {
                                BrowseKind.ALBUMS -> "Albums"
                                BrowseKind.SONGS -> "Songs"
                                BrowseKind.ARTISTS -> "Artists"
                            },
                        )
                    }
                }
                SegmentedButton(
                    selected = discover,
                    onClick = { onSearchMode(SearchMode.DISCOVER) },
                    shape = SegmentedButtonDefaults.itemShape(BrowseKind.entries.size, BrowseKind.entries.size + 1),
                ) { Text("Discover") }
            }
            if (!discover && kind == BrowseKind.ALBUMS) {
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
            if (!discover && kind != BrowseKind.ARTISTS) {
                IconButton(
                    onClick = {
                        onSearchMode(if (online) SearchMode.DEVICE else SearchMode.ONLINE)
                    },
                ) {
                    Icon(
                        if (online) Icons.Filled.Cloud else Icons.Filled.CloudQueue,
                        contentDescription = if (online) "Searching online — switch to this device" else "Search online",
                        tint = if (online) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
            if (!discover) IconButton(onClick = onShowSort) {
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
            if (!discover) BadgedBox(
                badge = {
                    if (filters.activeCount(kind) > 0) Badge { Text(filters.activeCount(kind).toString()) } else if (filters.glyphLit(kind)) Badge()
                },
            ) {
                IconButton(onClick = onShowFilters) {
                    Icon(
                        Icons.Filled.FilterList,
                        contentDescription = "Filters",
                        tint = if (filters.glyphLit(kind)) {
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
            placeholder = {
                Text(
                    if (discover) "Search Apple Music" else when (kind) {
                        BrowseKind.ALBUMS -> "Search albums"
                        BrowseKind.SONGS -> "Search songs"
                        BrowseKind.ARTISTS -> "Search artists"
                    },
                )
            },
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
        if (!discover) Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            val count = when (kind) {
                BrowseKind.ALBUMS -> results.albums.size
                BrowseKind.SONGS -> shownSongs.size
                BrowseKind.ARTISTS -> results.artists.size
            }
            val noun = when (kind) {
                BrowseKind.ALBUMS -> "albums"
                BrowseKind.SONGS -> "songs"
                BrowseKind.ARTISTS -> "artists"
            }
            Text(
                text = if (online) onlineCountLabel(onlineUi, kind) else "$count $noun",
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
            if (online && (onlineUi.isLoadingPage || onlineUi.state == OnlineSearchModel.State.Loading) || isRefreshing) {
                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
            }
        }

        // Incremental paging: budget keyed by the result-set version so a new
        // result set never renders the previous set's large prefix (§13).
        var pageCount by remember(pagingKey) { mutableIntStateOf(1) }
        val emptyMessage = when {
            query.isNotBlank() || filters.glyphLit(kind) -> "No matches — adjust search or filters"
            else -> "Nothing here yet — pull the catalog from Settings"
        }

        if (discover) {
            DiscoverPane(query = query, modifier = Modifier.weight(1f))
        } else if (online) {
            OnlineResults(
                ui = onlineUi,
                kind = kind,
                layout = layout,
                catalog = catalog,
                onLoadMore = { onlineScope.launch { onlineModel.loadMore() } },
                onOpenAlbum = onOpenAlbum,
                onOpenSong = onOpenSong,
                onAddSong = onAddSong,
                onAddAlbum = onAddAlbum,
                onPlaySong = onPlaySong,
            )
        } else when (kind) {
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
                            AlbumGridCard(
                                row,
                                onClick = { onOpenAlbum(row.album.id) },
                                onLongClick = { onAddAlbum(row.album.id) },
                            )
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
                            AlbumListRow(
                                row,
                                onClick = { onOpenAlbum(row.album.id) },
                                onLongClick = { onAddAlbum(row.album.id) },
                            )
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
                val visible = shownSongs.take(pageCount * PAGE_SIZE)
                if (shownSongs.isEmpty()) {
                    EmptyState(emptyMessage)
                } else {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(visible, key = { it.song.id }) { row ->
                            val songId = row.song.id
                            BrowseSongRow(
                                row = row,
                                modifier = Modifier.selectionDecor(rowSelection, songId, BROWSE_SELECTION_SCOPE),
                                // Select mode armed HERE eats the tap; otherwise it opens as before.
                                onClick = {
                                    selectionTap(rowSelection, songId, BROWSE_SELECTION_SCOPE) { onOpenSong(songId) }
                                },
                                onPlay = { onPlaySong(songId) },
                                // Armed: long-press toggles. Otherwise the COL-4 Add-to menu (with Select / Copy).
                                onLongClick = {
                                    if (rowSelection.state.value.isSelectMode(BROWSE_SELECTION_SCOPE)) {
                                        rowSelection.handleLongPress(songId, BROWSE_SELECTION_SCOPE)
                                    } else {
                                        onAddSong(songId)
                                    }
                                },
                            )
                        }
                        if (visible.size < shownSongs.size) {
                            item(key = "pager") {
                                PagingTrigger(visible.size) { pageCount += 1 }
                            }
                        }
                    }
                }
            }

            BrowseKind.ARTISTS -> {
                val visible = results.artists.take(pageCount * PAGE_SIZE)
                if (results.artists.isEmpty()) {
                    EmptyState(emptyMessage)
                } else {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        // Keyed by name — unique after case-insensitive grouping
                        // (specs/artists.md §3.2 / §12 trap 1).
                        items(visible, key = { it.name }) { artist ->
                            ArtistListRow(
                                artist = artist,
                                catalog = catalog,
                                onClick = { onOpenArtist(artist.name) },
                            )
                        }
                        if (visible.size < results.artists.size) {
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

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun AlbumGridCard(
    row: AlbumRow,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    Column(
        modifier = Modifier
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
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

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun AlbumListRow(
    row: AlbumRow,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
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
 * Artist row (specs/artists.md §4): representative-album thumbnail + name +
 * "N albums · M songs" counts + a trailing chevron; whole row taps into the
 * artist detail. No long-press add (an artist is derived, not a collectable).
 */
@Composable
private fun ArtistListRow(
    artist: Artist,
    catalog: MergedCatalog,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        AlbumArt(
            artist.artworkAlbumId?.let(catalog.albumsById::get),
            modifier = Modifier.size(46.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                artist.name,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            MetaTag(
                "${plural(artist.albumCount, "album")} · ${plural(artist.songCount, "song")}",
            )
        }
        Spacer(Modifier.width(8.dp))
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** iOS pluralization: "1 album" / "2 albums" (specs/artists.md §4). */
private fun plural(n: Int, noun: String): String = "$n $noun" + if (n == 1) "" else "s"

/**
 * Song row (§3): thumbnail, title (+E), artist · album, BPM, key chip,
 * duration, play affordance. Metadata-only rows are dimmed with no ▶
 * (sources-reality rule).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun BrowseSongRow(
    row: SongRow,
    onClick: () -> Unit,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
    zebra: Boolean = false,
    /** Long-press → Add to collection (null keeps the row tap-only). */
    onLongClick: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val manifest by graph.ripsRepository.manifest.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val preparingId by graph.playbackController.preparingSongId.collectAsState()

    val playable = playability(row.song.id, manifest, settings?.hasRipServer == true, row.song.appleMusicId)
    val contentAlpha = if (playable == Playability.NONE) 0.45f else 1f

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
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
        FavoriteToggle(songId = row.song.id, appleMusicId = row.song.appleMusicId, iconSize = 18.dp)
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
internal fun EmptyState(message: String) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

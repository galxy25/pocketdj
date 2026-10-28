package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.collections.CollectionSortDoc
import com.levi.pocketdj.data.collections.CollectionSortSettings
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.favorites.FavoriteFilter
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.BrowseEngine
import com.levi.pocketdj.screens.browse.BrowseFilterSheet
import com.levi.pocketdj.screens.browse.BrowseFilters
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.BrowseSortSheet
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.CollectionRef
import com.levi.pocketdj.screens.browse.MembershipFilter
import com.levi.pocketdj.screens.browse.ReadTimeFilters
import com.levi.pocketdj.screens.browse.FieldOptions
import com.levi.pocketdj.screens.browse.Fields
import com.levi.pocketdj.screens.browse.Fmt
import com.levi.pocketdj.screens.browse.Genre
import com.levi.pocketdj.screens.browse.SongRow
import com.levi.pocketdj.screens.browse.SortField
import com.levi.pocketdj.screens.browse.SortKey
import com.levi.pocketdj.screens.browse.toClause
import com.levi.pocketdj.screens.browse.toDoc
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Per-collection sort + filter (iOS `Views/CollectionSortFilter.swift`, `AppModel.sortedFilteredSongs`).
 *
 * The collection's own song subset runs through the SAME [BrowseEngine] pipeline the Browser uses;
 * the STORED order is never mutated, so choosing "default order" (no sort keys, no filters) shows
 * the stored order again and re-enables reorder / up-down / remove. State is remembered per
 * collection under `pdj.collection.<id>` ([CollectionSortSettings]).
 */

/** A collection's live sort/filter. "Default order" = no sort keys AND no complete filter clause. */
internal data class CollectionBrowseInputs(
    val clauses: List<Clause> = emptyList(),
    val sortKeys: List<SortKey> = emptyList(),
    /** Favorite tri-state. TRANSIENT (iOS: never persisted; the truth lives in FavoritesStore). */
    val favorite: FavoriteFilter = FavoriteFilter.ANY,
    /** Collection-membership SHOW/HIDE. TRANSIENT, read-time. */
    val membership: MembershipFilter = MembershipFilter(),
) {
    /** Complete clauses + favorite + membership constraints (an in-progress clause is a no-op). */
    val activeFilterCount: Int
        get() = clauses.count { !it.isIncomplete } +
            (if (favorite != FavoriteFilter.ANY) 1 else 0) +
            (if (membership.active) 1 else 0)

    val usesReadTime: Boolean get() = favorite != FavoriteFilter.ANY || membership.active

    /** iOS `browse.sortKeys.isEmpty && browse.activeFilterCount == 0`. */
    val isDefaultOrder: Boolean get() = sortKeys.isEmpty() && activeFilterCount == 0

    val usesPlayCounts: Boolean
        get() = sortKeys.any { it.field == SortField.PLAY_COUNT } ||
            clauses.any { !it.isIncomplete && it.field == "playCount" }

    fun toDoc(): CollectionSortDoc = CollectionSortDoc(
        clauses = clauses.map(Clause::toDoc),
        sortKeys = sortKeys.map { BrowseSortKeyDoc(it.field.id, it.ascending) },
    )

    companion object {
        /** Unknown field / op ids are dropped (a future field decodes without crashing). */
        fun fromDoc(doc: CollectionSortDoc): CollectionBrowseInputs = CollectionBrowseInputs(
            clauses = doc.clauses.mapNotNull { it.toClause() }.filter { Fields.byId.containsKey(it.field) },
            sortKeys = doc.sortKeys.mapNotNull { d -> SortField.byId[d.field]?.let { SortKey(it, d.ascending) } },
        )
    }
}

/**
 * Snapshot of the live read-time layers (favorites, collection membership) so the off-main resolve
 * never touches a store. [members] maps every collection id (when a "Any" membership is used) or
 * just the selected ones to their song ids.
 */
internal data class CollectionReadTime(
    val favoriteIds: Set<String>? = null,
    val members: Map<String, Set<String>> = emptyMap(),
)

internal object CollectionSortFilter {

    /**
     * The song ids a multi-select acts on, in DISPLAY order: stored order in the default order,
     * otherwise the resolved list (hidden rows are never selectable). Catalog songs only.
     */
    fun selectableSongIds(
        stored: List<String>,
        resolved: List<String>?,
        defaultOrder: Boolean,
        catalog: MergedCatalog?,
        isStudio: (String) -> Boolean = PlayResolver::isStudioId,
    ): List<String> {
        val shown = if (defaultOrder) stored else resolved.orEmpty()
        return shown.filter { catalog?.songsById?.containsKey(it) == true && !isStudio(it) }
    }

    /** Playlist song NODES a multi-select acts on, in chapter display order (resolved when sorted/filtered). */
    fun selectableSongNodes(
        chapters: List<PlaylistNode>,
        resolvedChapters: Map<String, List<PlaylistNode>>?,
        defaultOrder: Boolean,
        catalog: MergedCatalog?,
        isStudio: (String) -> Boolean = PlayResolver::isStudioId,
    ): List<PlaylistNode> = chapters.flatMap { ch ->
        if (defaultOrder) ch.children.orEmpty() else resolvedChapters?.get(ch.nodeId).orEmpty()
    }.filter { n ->
        n.kind == PlaylistNode.Kind.SONG && n.songId?.let { id ->
            catalog?.songsById?.containsKey(id) == true && !isStudio(id)
        } == true
    }

    /** Browse-shaped rows for [ids] (ids missing from the catalog are skipped; repeats kept). */
    fun rowsFor(ids: List<String>, catalog: MergedCatalog): List<SongRow> {
        val rows = ArrayList<SongRow>(ids.size)
        for (id in ids) {
            val song = catalog.songsById[id] ?: continue
            val album = song.albumId?.let(catalog.albumsById::get)
            rows += SongRow(
                song = song,
                albumName = album?.name,
                source = catalog.sourceOfSong[id],
                genreCategory = Genre.category(album?.genre),
                searchKey = Fmt.fold("${song.name}\n${song.artist}\n${album?.name.orEmpty()}"),
                dateAdded = song.dateAdded,
            )
        }
        return rows
    }

    /**
     * The collection's catalog songs filtered + sorted by [inputs] (song ids, repeats preserved).
     * Pure + off-main safe. Default inputs return the catalog-resolvable subset in stored order.
     */
    fun resolveSongIds(
        ids: List<String>,
        catalog: MergedCatalog,
        inputs: CollectionBrowseInputs,
        playCountOf: (String) -> Int = { 0 },
        readTime: CollectionReadTime? = null,
    ): List<String> {
        val rows = rowsFor(ids, catalog)
        val counts = if (inputs.usesPlayCounts) {
            rows.asSequence().map { it.song.id }.distinct().associateWith(playCountOf).filterValues { it > 0 }
        } else emptyMap()
        val sorted = BrowseEngine.filterSort(
            base = rows,
            searchKeys = rows.map { it.searchKey },
            query = "",
            clauses = inputs.clauses,
            sortKeys = inputs.sortKeys,
            playCounts = counts,
        )
        val shown = if (readTime == null || !inputs.usesReadTime) sorted else ReadTimeFilters.apply(
            rows = sorted,
            membership = inputs.membership,
            allCollectionIds = readTime.members.keys,
            membersOf = { readTime.members[it].orEmpty() },
            favorite = inputs.favorite,
            favoriteIds = readTime.favoriteIds,
        )
        return shown.map { it.song.id }
    }

    /**
     * A pocket's displayed song ids: catalog songs ordered by the pipeline, then Studio items
     * pinned at the very end — a FILTER hides them (they carry no song fields), a plain sort
     * keeps them. Default order is NOT routed through here (stored order, reorderable).
     */
    fun resolvePocketSongs(
        ids: List<String>,
        catalog: MergedCatalog,
        inputs: CollectionBrowseInputs,
        playCountOf: (String) -> Int = { 0 },
        isStudio: (String) -> Boolean = PlayResolver::isStudioId,
        readTime: CollectionReadTime? = null,
    ): List<String> {
        val sorted = resolveSongIds(ids.filterNot(isStudio), catalog, inputs, playCountOf, readTime)
        val tail = if (inputs.activeFilterCount == 0) ids.filter(isStudio) else emptyList()
        return sorted + tail
    }

    /**
     * A chapter's children reordered: SONG leaves ordered by the pipeline, then the non-song nodes
     * (text / album / pocket / sub-chapter / Studio song nodes) appended — hidden while a FILTER is
     * active. Dup-safe: several nodes for the same songId each consume one slot. Song nodes whose
     * song is not in the catalog drop out in a non-default order (iOS `displayChildrenAsync`).
     */
    fun resolveChapterChildren(
        children: List<PlaylistNode>,
        catalog: MergedCatalog,
        inputs: CollectionBrowseInputs,
        playCountOf: (String) -> Int = { 0 },
        isStudio: (String) -> Boolean = PlayResolver::isStudioId,
        readTime: CollectionReadTime? = null,
    ): List<PlaylistNode> {
        if (inputs.isDefaultOrder) return children
        fun isCatalogSong(n: PlaylistNode) =
            n.kind == PlaylistNode.Kind.SONG && n.songId?.let { !isStudio(it) } == true
        val songNodes = children.filter(::isCatalogSong)
        val queues = HashMap<String, ArrayDeque<PlaylistNode>>()
        for (n in songNodes) queues.getOrPut(n.songId!!) { ArrayDeque() }.addLast(n)
        val ordered = ArrayList<PlaylistNode>(songNodes.size)
        for (id in resolveSongIds(songNodes.map { it.songId!! }, catalog, inputs, playCountOf, readTime)) {
            queues[id]?.removeFirstOrNull()?.let(ordered::add)
        }
        val tail = if (inputs.activeFilterCount == 0) {
            children.filter { n ->
                n.kind != PlaylistNode.Kind.SONG || n.songId?.let(isStudio) == true
            }
        } else emptyList()
        return ordered + tail
    }
}

/** Live, persisted sort/filter state for ONE collection (key `pdj.collection.<id>`). */
@Stable
internal class CollectionSortState(val collectionId: String) {
    var inputs by mutableStateOf(CollectionBrowseInputs())
        private set

    /** True once the persisted doc has been applied (a save before this must not clobber it). */
    var loaded by mutableStateOf(false)
        private set

    /** True once the user changed anything; a late hydrate must then NOT overwrite the choice. */
    private var edited = false

    fun setSortKeys(keys: List<SortKey>) { edited = true; inputs = inputs.copy(sortKeys = keys) }
    fun setClauses(clauses: List<Clause>) { edited = true; inputs = inputs.copy(clauses = clauses) }
    fun setFilters(f: BrowseFilters) {
        edited = true
        inputs = inputs.copy(clauses = f.clauses, favorite = f.favorite, membership = f.membership)
    }

    /**
     * Applies the persisted doc. If the user already edited before the load finished, keep their
     * edit (and persist it) but still keep the stored sort/clauses they did not touch out of the way.
     */
    internal fun restore(doc: CollectionSortDoc) {
        if (!edited) inputs = CollectionBrowseInputs.fromDoc(doc).copy(favorite = inputs.favorite, membership = inputs.membership)
        loaded = true
    }
}

@Composable
internal fun rememberCollectionSortState(collectionId: String): CollectionSortState {
    val context = LocalContext.current
    val settings = remember { AppGraph.get(context).settings }
    val state = remember(collectionId) { CollectionSortState(collectionId) }
    LaunchedEffect(collectionId) {
        runCatching { CollectionSortSettings.load(settings, collectionId) }
            .onSuccess(state::restore)
            // Load failed: stay un-loaded so the save effect never overwrites the stored entry.
    }
    // Persist every change once hydrated (survives process death; an empty doc drops the entry).
    LaunchedEffect(state.inputs, state.loaded) {
        if (!state.loaded) return@LaunchedEffect
        withContext(NonCancellable) {
            runCatching { CollectionSortSettings.save(settings, collectionId, state.inputs.toDoc()) }
        }
    }
    return state
}

/** Live favorites / membership snapshot for [inputs] (null-cheap when neither layer is active). */
@Composable
internal fun rememberCollectionReadTime(inputs: CollectionBrowseInputs): CollectionReadTime? {
    val context = LocalContext.current
    val favStore = remember { AppGraph.get(context).collectionsGraph.favorites }
    val collStore = remember { AppGraph.get(context).collections }
    if (!inputs.usesReadTime) return null
    val favRev = if (inputs.favorite != FavoriteFilter.ANY) favStore.state.collectAsState().value.revision else -1
    val collRev = if (inputs.membership.active) collStore.state.collectAsState().value.revision else -1
    return remember(inputs.favorite, inputs.membership, favRev, collRev) {
        val m = inputs.membership
        val ids: Set<String> = when {
            !m.active -> emptySet()
            m.includeAny || m.excludeAny -> (collStore.playlists.map { it.id } + collStore.pockets.map { it.id }).toSet()
            else -> m.includeIds + m.excludeIds
        }
        CollectionReadTime(
            favoriteIds = if (inputs.favorite != FavoriteFilter.ANY) favStore.favoriteIds else null,
            members = ids.associateWith { id ->
                (if (id.startsWith("pkt_")) collStore.songIdsForPocket(id) else collStore.songIdsForPlaylist(id)).toSet()
            },
        )
    }
}

/** Play counts accessor for a `playCount` sort/filter (history is device-local). */
@Composable
internal fun rememberPlayCountOf(): (String) -> Int {
    val context = LocalContext.current
    return remember { PlayHistoryStore.get(context).let { h -> { id: String -> h.playCount(id) } } }
}

/**
 * Sort + Filter sheets bound to [state]. Song-kind only; the filter sheet's option lists come from
 * the collection's own songs ([songIds]), built off-main when the sheet opens.
 */
@Composable
internal fun CollectionSortFilterSheets(
    state: CollectionSortState,
    catalog: MergedCatalog?,
    songIds: List<String>,
    showSort: Boolean,
    showFilter: Boolean,
    onDismissSort: () -> Unit,
    onDismissFilter: () -> Unit,
) {
    if (showSort) {
        BrowseSortSheet(
            kind = BrowseKind.SONGS,
            includeDateAdded = true,
            sortKeys = state.inputs.sortKeys,
            onSortKeys = state::setSortKeys,
            onDismiss = onDismissSort,
        )
    }
    if (showFilter) {
        val optionRows by produceState<List<SongRow>>(emptyList(), catalog, songIds) {
            value = if (catalog == null) emptyList()
            else withContext(Dispatchers.Default) { CollectionSortFilter.rowsFor(songIds, catalog) }
        }
        val context = LocalContext.current
        val collStore = remember { AppGraph.get(context).collections }
        val collState by collStore.state.collectAsState()
        BrowseFilterSheet(
            kind = BrowseKind.SONGS,
            filters = BrowseFilters(
                clauses = state.inputs.clauses,
                favorite = state.inputs.favorite,
                membership = state.inputs.membership,
            ),
            optionsFor = { fieldId -> FieldOptions.of(fieldId, optionRows, catalog?.availableSources.orEmpty()) },
            showFavorite = true,
            playlists = collState.playlists.sortedBy { it.name.lowercase() }.map { CollectionRef(it.id, it.name) },
            pockets = collState.pockets.sortedBy { it.name.lowercase() }.map { CollectionRef(it.id, it.name) },
            onFilters = state::setFilters,
            onDismiss = onDismissFilter,
        )
    }
}

/** Toolbar-style pair (source-playlist detail has no overflow menu). */
@Composable
internal fun CollectionSortFilterButtons(
    state: CollectionSortState,
    onSort: () -> Unit,
    onFilter: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier) {
        IconButton(onClick = onSort, modifier = Modifier.testTag("collection-sort")) {
            Icon(Icons.Filled.SwapVert, contentDescription = "Sort")
        }
        IconButton(onClick = onFilter, modifier = Modifier.testTag("collection-filter")) {
            Icon(
                if (state.inputs.activeFilterCount > 0) Icons.Filled.FilterAlt else Icons.Filled.FilterList,
                contentDescription = "Filter",
            )
        }
    }
}

/** Menu-item pair for folding into a detail's existing ⋯ menu (pocket / playlist). */
@Composable
internal fun CollectionSortFilterMenuItems(
    state: CollectionSortState,
    dismiss: () -> Unit,
    onSort: () -> Unit,
    onFilter: () -> Unit,
) {
    val active = state.inputs.activeFilterCount
    DropdownMenuItem(
        text = { Text(if (state.inputs.sortKeys.isEmpty()) "Sort…" else "Sort (${state.inputs.sortKeys.size})…") },
        onClick = { dismiss(); onSort() },
        modifier = Modifier.testTag("collection-sort"),
    )
    DropdownMenuItem(
        text = { Text(if (active > 0) "Filter ($active)…" else "Filter…") },
        onClick = { dismiss(); onFilter() },
        modifier = Modifier.testTag("collection-filter"),
    )
}

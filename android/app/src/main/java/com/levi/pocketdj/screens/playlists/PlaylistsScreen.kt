package com.levi.pocketdj.screens.playlists

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.SongDrop
import com.levi.pocketdj.ui.dnd.songDropTarget
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.History
import androidx.compose.ui.platform.testTag
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.screens.collections.RemoveDuplicatesResultAlert
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.CollectionSortOrder
import com.levi.pocketdj.data.collections.CollectionSortable
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.browse.Fmt
import androidx.compose.material.icons.filled.GraphicEq
import com.levi.pocketdj.data.collections.NOW_PLAYING_PLAYLIST_ID
import com.levi.pocketdj.data.collections.NOW_PLAYING_SETLIST_ID
import com.levi.pocketdj.data.collections.Setlist
import androidx.compose.runtime.produceState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch

/** Which create dialog is open (§2.5 toolbar). */
private enum class CreateKind { FOLDER, POCKET, PLAYLIST }

/** A row a context menu is acting on. */
private data class RowRef(val kind: Kind, val id: String, val name: String) {
    enum class Kind { PLAYLIST, POCKET, FOLDER, SETLIST }
}

/**
 * The Playlists tab (specs/playlists-ui.md §2): Yours | Shared mode tabs (F3),
 * per-tab search, the persisted collection sort (F1), Your playlists / Pockets /
 * folder sections with collapse memory, the Shared per-source groups with
 * collapse-by-default + remembered expansions (F2), all create flows, and every
 * empty state.
 *
 * The integrator wires the four open callbacks to navigation destinations.
 */
@Composable
fun PlaylistsScreen(
    onOpenPlaylist: (playlistId: String) -> Unit,
    onOpenPocket: (pocketId: String) -> Unit,
    onOpenSourcePlaylist: (playlistId: String, sourceName: String) -> Unit,
    modifier: Modifier = Modifier,
    /** Opens a frozen Setlist (ANS-COL-3); null hides the Setlists section. */
    onOpenSetlist: ((setlistId: String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store = remember { graph.collections }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        graph.catalogRepository.loadIfNeeded()
        graph.ripsRepository.loadAtLaunch()
    }

    val state by store.state.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val catalogState by graph.catalogRepository.state.collectAsState()
    val catalog = catalogState.catalog

    // §9: UI state persisted OUTSIDE the collections doc, iOS key semantics.
    val mode = settings?.playlistsMode ?: "user"
    val sort = CollectionSortOrder.fromToken(settings?.collectionSort)
    val collapsedFolders = settings?.collapsedFolderIds ?: emptySet()
    val expandedSources = settings?.expandedSourceNames ?: emptySet()

    val recentlyLimit by remember {
        graph.settings.flow(com.levi.pocketdj.data.settings.ShellSettings.DEFAULT_RECENTLY_ADDED_COUNT)
            .map { com.levi.pocketdj.data.settings.ShellSettings.clampRecentlyAdded(it) }
    }.collectAsState(initial = com.levi.pocketdj.data.settings.ShellSettings.RECENTLY_ADDED_DEFAULT)
    val activityState by graph.collectionActivity.state.collectAsState()
    // Derived off-main + memoized on (catalog, activity revision, limit): null = no adds.
    val recentlyAddedCount by produceState<Int?>(null, catalog, activityState.revision, recentlyLimit) {
        value = if (catalog == null) null else withContext(Dispatchers.Default) {
            graph.collectionsGraph.recentlyAdded.songIds(catalog, activityState.events, recentlyLimit).size
        }
    }

    var query by rememberSaveable { mutableStateOf("") }

    // Dialog state.
    var createDialog by remember { mutableStateOf<CreateKind?>(null) }
    var renameItem by remember { mutableStateOf<RowRef?>(null) }
    var deleteItem by remember { mutableStateOf<RowRef?>(null) }
    var moveItem by remember { mutableStateOf<RowRef?>(null) }
    var addPocketToPlaylist by remember { mutableStateOf<RowRef?>(null) }
    val exporter = com.levi.pocketdj.screens.collections.rememberCollectionExporter()
    val startImport = com.levi.pocketdj.screens.collections.rememberCollectionImporter()
    var dedupeConfirm by rememberSaveable { mutableStateOf(false) }
    var dedupeResult by rememberSaveable { mutableStateOf<Int?>(null) }

    Column(modifier = modifier.fillMaxSize()) {
        // Mode tabs + toolbar (§2.1, §2.5 — import deferred §13).
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 4.dp),
        ) {
            SingleChoiceSegmentedButtonRow(modifier = Modifier.weight(1f)) {
                listOf("user" to "Yours", "shared" to "Shared").forEachIndexed { index, (token, label) ->
                    SegmentedButton(
                        selected = mode == token,
                        onClick = { scope.launch { graph.settings.setPlaylistsMode(token) } },
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                    ) { Text(label) }
                }
            }
            // Sort menu (F1) — one tap picks one order, ✓ on the active one.
            OverflowMenu(icon = Icons.Filled.SwapVert, contentDescription = "Sort") { dismiss ->
                CollectionSortOrder.entries.forEach { order ->
                    DropdownMenuItem(
                        text = { Text(order.label) },
                        leadingIcon = {
                            if (order == sort) {
                                Icon(Icons.Filled.Check, contentDescription = null)
                            }
                        },
                        onClick = {
                            dismiss()
                            scope.launch { graph.settings.setCollectionSort(order.token) }
                        },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("Remove duplicates in all collections…") },
                    onClick = { dismiss(); dedupeConfirm = true },
                )
            }
            IconButton(onClick = startImport, modifier = Modifier.testTag("collections-import")) {
                Icon(Icons.Filled.FileOpen, contentDescription = "Import")
            }
            IconButton(onClick = { createDialog = CreateKind.FOLDER }) {
                Icon(Icons.Filled.CreateNewFolder, contentDescription = "New folder")
            }
            IconButton(onClick = { createDialog = CreateKind.POCKET }) {
                Icon(Icons.Filled.Layers, contentDescription = "New pocket")
            }
            IconButton(onClick = { createDialog = CreateKind.PLAYLIST }) {
                Icon(Icons.Filled.Add, contentDescription = "New playlist")
            }
        }

        // Search — scoped to the active tab (§2.2).
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            singleLine = true,
            placeholder = {
                Text(if (mode == "user") "Search playlists and pockets" else "Search source playlists")
            },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (query.isNotEmpty()) {
                    IconButton(onClick = { query = "" }) {
                        Icon(Icons.Filled.Close, contentDescription = "Clear search")
                    }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 4.dp),
        )

        val trimmedQuery = query.trim()
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            if (mode == "user") {
                userTab(
                    onExport = exporter::export,
                    state = state,
                    store = store,
                    sort = sort,
                    query = trimmedQuery,
                    collapsedFolders = collapsedFolders,
                    recentlyAddedCount = recentlyAddedCount,
                    onOpenRecentlyAdded = {
                        onOpenSourcePlaylist(
                            com.levi.pocketdj.data.collections.RecentlyAdded.PLAYLIST_ID,
                            com.levi.pocketdj.data.collections.RecentlyAdded.NAME,
                        )
                    },
                    onToggleFolder = { id, collapsed ->
                        scope.launch { graph.settings.setFolderCollapsed(id, collapsed) }
                    },
                    onOpenPlaylist = onOpenPlaylist,
                    onOpenPocket = onOpenPocket,
                    onOpenSetlist = onOpenSetlist,
                    onCreatePlaylist = { createDialog = CreateKind.PLAYLIST },
                    onCreatePocket = { createDialog = CreateKind.POCKET },
                    onRename = { renameItem = it },
                    onDelete = { deleteItem = it },
                    onMove = { moveItem = it },
                    onAddPocketToPlaylist = { addPocketToPlaylist = it },
                )
            } else {
                sharedTab(
                    sources = catalog?.playlists.orEmpty(),
                    sourceOrder = catalog?.availableSources.orEmpty(),
                    sort = sort,
                    query = trimmedQuery,
                    expandedSources = expandedSources,
                    onToggleSource = { name, expanded ->
                        scope.launch { graph.settings.setSourceExpanded(name, expanded) }
                    },
                    onOpenSource = onOpenSourcePlaylist,
                )
            }
        }
    }

    // ---- dialogs -----------------------------------------------------------

    createDialog?.let { kind ->
        NameDialog(
            title = when (kind) {
                CreateKind.FOLDER -> "New Folder"
                CreateKind.POCKET -> "New Pocket"
                CreateKind.PLAYLIST -> "New Playlist"
            },
            confirmLabel = "Create",
            onDismiss = { createDialog = null },
            onConfirm = { name ->
                when (kind) {
                    CreateKind.FOLDER -> store.createFolder(name)
                    CreateKind.POCKET -> store.createPocket(name)
                    CreateKind.PLAYLIST -> store.createPlaylist(name)
                }
            },
        )
    }

    renameItem?.let { ref ->
        NameDialog(
            title = when (ref.kind) {
                RowRef.Kind.PLAYLIST -> "Rename playlist"
                RowRef.Kind.POCKET -> "Rename pocket"
                RowRef.Kind.FOLDER -> "Rename folder"
                RowRef.Kind.SETLIST -> "Rename set list"
            },
            confirmLabel = "Rename",
            initial = ref.name,
            onDismiss = { renameItem = null },
            onConfirm = { name ->
                when (ref.kind) {
                    RowRef.Kind.PLAYLIST -> store.renamePlaylist(ref.id, name)
                    RowRef.Kind.POCKET -> store.renamePocket(ref.id, name)
                    RowRef.Kind.FOLDER -> store.renameFolder(ref.id, name)
                    RowRef.Kind.SETLIST -> store.renameSetlist(ref.id, name)
                }
            },
        )
    }

    deleteItem?.let { ref ->
        ConfirmDialog(
            title = when (ref.kind) {
                RowRef.Kind.PLAYLIST -> "Delete this playlist?"
                RowRef.Kind.POCKET -> "Delete this pocket?"
                RowRef.Kind.FOLDER -> "Delete this folder?"
                RowRef.Kind.SETLIST -> "Delete this set list?"
            },
            text = when (ref.kind) {
                RowRef.Kind.PLAYLIST -> "This also deletes its set lists. This can't be undone."
                RowRef.Kind.POCKET ->
                    "Removes the pocket and unnests it from any parent. Its items aren't deleted. " +
                        "This can't be undone."
                RowRef.Kind.FOLDER ->
                    "The folder's playlists and pockets move back to the top level. This can't be undone."
                RowRef.Kind.SETLIST -> "This can't be undone."
            },
            confirmLabel = "Delete",
            onDismiss = { deleteItem = null },
            onConfirm = {
                when (ref.kind) {
                    RowRef.Kind.PLAYLIST -> store.deletePlaylist(ref.id)
                    RowRef.Kind.POCKET -> store.deletePocket(ref.id)
                    RowRef.Kind.FOLDER -> store.deleteFolder(ref.id)
                    RowRef.Kind.SETLIST -> store.deleteSetlist(ref.id)
                }
            },
        )
    }

    moveItem?.let { ref ->
        MoveToFolderDialog(
            folders = store.foldersOrdered(),
            currentFolderId = when (ref.kind) {
                RowRef.Kind.PLAYLIST -> store.playlist(ref.id)?.folderId
                else -> store.pocket(ref.id)?.folderId
            },
            onDismiss = { moveItem = null },
            onMove = { folderId ->
                when (ref.kind) {
                    RowRef.Kind.PLAYLIST -> store.setPlaylistFolder(ref.id, folderId)
                    else -> store.setPocketFolder(ref.id, folderId)
                }
            },
            onCreateAndMove = { name ->
                val folder = store.createFolder(name)
                when (ref.kind) {
                    RowRef.Kind.PLAYLIST -> store.setPlaylistFolder(ref.id, folder.id)
                    else -> store.setPocketFolder(ref.id, folder.id)
                }
            },
        )
    }

    if (dedupeConfirm) {
        ConfirmDialog(
            title = "Remove duplicates in all collections?",
            text = "Collapses the same song on the same album listed twice in any pocket or " +
                "playlist, keeping the copy that streams from Apple Music.",
            confirmLabel = "Remove",
            onDismiss = { dedupeConfirm = false },
            onConfirm = {
                dedupeConfirm = false
                dedupeResult = store.removeDuplicatesEverywhere()
            },
        )
    }
    RemoveDuplicatesResultAlert(dedupeResult) { dedupeResult = null }

    addPocketToPlaylist?.let { ref ->
        // Pocket ▸ "Add to playlist…" — inserts a pocket-REF node into the
        // playlist's default chapter (§2.8).
        AlertDialog(
            onDismissRequest = { addPocketToPlaylist = null },
            title = { Text("Add \"${ref.name}\" to playlist") },
            text = {
                if (state.playlists.isEmpty()) {
                    Text("No playlists yet — create one first.")
                } else {
                    Column {
                        sort.sorted(state.playlists).forEach { pl ->
                            Text(
                                pl.name,
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier
                                    .clickable {
                                        addPocketToPlaylist = null
                                        store.addPocketRef(ref.id, pl.id)
                                    }
                                    .fillMaxWidth()
                                    .padding(vertical = 10.dp),
                            )
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { addPocketToPlaylist = null }) { Text("Cancel") }
            },
        )
    }
}

// ---- User tab --------------------------------------------------------------

private fun LazyListScope.userTab(
    onExport: (com.levi.pocketdj.screens.collections.ExportRequest) -> Unit,
    state: CollectionsStore.State,
    store: CollectionsStore,
    sort: CollectionSortOrder,
    query: String,
    collapsedFolders: Set<String>,
    recentlyAddedCount: Int?,
    onOpenRecentlyAdded: () -> Unit,
    onToggleFolder: (id: String, collapsed: Boolean) -> Unit,
    onOpenPlaylist: (String) -> Unit,
    onOpenPocket: (String) -> Unit,
    onOpenSetlist: ((String) -> Unit)?,
    onCreatePlaylist: () -> Unit,
    onCreatePocket: () -> Unit,
    onRename: (RowRef) -> Unit,
    onDelete: (RowRef) -> Unit,
    onMove: (RowRef) -> Unit,
    onAddPocketToPlaylist: (RowRef) -> Unit,
) {
    fun playlistRow(pl: Playlist) {
        item(key = "pl-${pl.id}") {
            PlaylistRow(
                playlist = pl,
                store = store,
                onOpen = { onOpenPlaylist(pl.id) },
                onRename = { onRename(RowRef(RowRef.Kind.PLAYLIST, pl.id, pl.name)) },
                onMove = { onMove(RowRef(RowRef.Kind.PLAYLIST, pl.id, pl.name)) },
                onDelete = { onDelete(RowRef(RowRef.Kind.PLAYLIST, pl.id, pl.name)) },
                onExport = onExport,
                modifier = Modifier.songDropTarget { t ->
                    SongDrop.accept(listOf(t), resolves = store::songResolves) {
                        store.addSongs(it, AddTarget(AddTarget.Kind.PLAYLIST, pl.id))
                    }
                },
            )
        }
    }

    fun pocketRow(p: Pocket) {
        item(key = "pk-${p.id}") {
            PocketRow(
                pocket = p,
                store = store,
                onOpen = { onOpenPocket(p.id) },
                onRename = { onRename(RowRef(RowRef.Kind.POCKET, p.id, p.name)) },
                onMove = { onMove(RowRef(RowRef.Kind.POCKET, p.id, p.name)) },
                onAddToPlaylist = { onAddPocketToPlaylist(RowRef(RowRef.Kind.POCKET, p.id, p.name)) },
                onDelete = { onDelete(RowRef(RowRef.Kind.POCKET, p.id, p.name)) },
                onExport = onExport,
                modifier = Modifier.songDropTarget { t ->
                    SongDrop.accept(listOf(t), resolves = store::songResolves) {
                        store.addSongs(it, AddTarget(AddTarget.Kind.POCKET, p.id))
                    }
                },
            )
        }
    }

    // Setlists (ANS-COL-3, Q75): frozen takes, newest first; the reserved Now Playing set never listed.
    fun setlistRows(query: String) {
        if (onOpenSetlist == null) return
        val rows = listableSetlists(state.setlists, query)
        if (rows.isEmpty()) return
        item(key = "hdr-setlists") { SectionHeader("Setlists") }
        rows.forEach { sl ->
            item(key = "sl-${sl.id}") {
                val trackCount = sl.tracks.count { it.isText != true }
                CollectionRow(
                    icon = Icons.Filled.GraphicEq,
                    iconTint = MaterialTheme.colorScheme.tertiary,
                    name = setlistTitle(sl),
                    subtitle = "$trackCount ${if (trackCount == 1) "track" else "tracks"} · ${Fmt.duration(sl.totalMs)}",
                    onClick = { onOpenSetlist(sl.id) },
                    modifier = Modifier.testTag("setlist-row-${sl.id}"),
                    trailing = {
                        OverflowMenu { dismiss ->
                            DropdownMenuItem(
                                text = { Text("Rename") },
                                onClick = { dismiss(); onRename(RowRef(RowRef.Kind.SETLIST, sl.id, setlistTitle(sl))) },
                            )
                            DropdownMenuItem(
                                text = { Text("Delete") },
                                onClick = { dismiss(); onDelete(RowRef(RowRef.Kind.SETLIST, sl.id, setlistTitle(sl))) },
                            )
                        }
                    },
                )
            }
        }
    }

    // Searching replaces the list with FLATTENED results — folder nesting
    // collapses away, ordered by the active sort (§2.2).
    if (query.isNotEmpty()) {
        val folded = Fmt.fold(query)
        val matches: List<CollectionSortable> = sort.sorted(
            state.playlists.filter { Fmt.fold(it.name).contains(folded) } +
                state.pockets.filter { Fmt.fold(it.name).contains(folded) },
        )
        if (matches.isEmpty() && listableSetlists(state.setlists, query).isEmpty()) {
            item(key = "no-results") { SectionCaption("No results for \"$query\"") }
        } else {
            matches.forEach { m ->
                when (m) {
                    is Playlist -> playlistRow(m)
                    is Pocket -> pocketRow(m)
                }
            }
        }
        setlistRows(query)
        return
    }

    // Whole-tab empty state (§2.4).
    if (state.playlists.isEmpty() && state.pockets.isEmpty() && recentlyAddedCount == 0 &&
        listableSetlists(state.setlists, "").isEmpty()
    ) {
        item(key = "empty") {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp, vertical = 48.dp),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.QueueMusic,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(44.dp),
                )
                Spacer(Modifier.height(10.dp))
                Text("No collections yet", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(6.dp))
                Text(
                    "A playlist is an ordered template you can perform. " +
                        "A pocket is a reusable group of songs that mix well together.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(16.dp))
                Button(onClick = onCreatePlaylist) { Text("New Playlist") }
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = onCreatePocket) { Text("New Pocket") }
            }
        }
        return
    }

    // 0. Pinned virtual "Recently added" row (hidden when there are no adds).
    if (recentlyAddedCount != null && recentlyAddedCount > 0) {
        item(key = "hdr-recent") { SectionHeader("Recently added") }
        item(key = "row-recent") {
            androidx.compose.material3.ListItem(
                headlineContent = { Text("$recentlyAddedCount songs — newest first") },
                leadingContent = {
                    androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Filled.History, contentDescription = null)
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("recently-added-row")
                    .clickable(onClick = onOpenRecentlyAdded),
            )
        }
    }

    // 1. "Your playlists" — top-level, active sort (§2.4).
    item(key = "hdr-playlists") { SectionHeader("Your playlists") }
    val topPlaylists = sort.sorted(state.playlists.filter { it.folderId == null })
    when {
        state.playlists.isEmpty() ->
            item(key = "cap-playlists") { SectionCaption("No playlists yet — tap + to create one.") }
        topPlaylists.isEmpty() ->
            item(key = "cap-playlists") { SectionCaption("All your playlists are in folders below.") }
        else -> topPlaylists.forEach { playlistRow(it) }
    }

    // 2. "Pockets" — the section HIDES entirely at zero pockets (§2.4).
    if (state.pockets.isNotEmpty()) {
        item(key = "hdr-pockets") { SectionHeader("Pockets") }
        val topPockets = sort.sorted(state.pockets.filter { it.folderId == null })
        if (topPockets.isEmpty()) {
            item(key = "cap-pockets") { SectionCaption("All your pockets are in folders below.") }
        } else {
            topPockets.forEach { pocketRow(it) }
        }
    }

    // 3. One collapsible section per folder, name-ordered (§2.6).
    store.foldersOrdered().forEach { folder ->
        val members = state.playlists.count { it.folderId == folder.id } +
            state.pockets.count { it.folderId == folder.id }
        val collapsed = folder.id in collapsedFolders
        item(key = "fld-${folder.id}") {
            CollectionRow(
                icon = Icons.Filled.Folder,
                iconTint = MaterialTheme.colorScheme.onSurfaceVariant,
                name = folder.name,
                subtitle = null,
                onClick = { onToggleFolder(folder.id, !collapsed) },
                trailing = {
                    Text(
                        members.toString(),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Icon(
                        if (collapsed) Icons.Filled.ExpandMore else Icons.Filled.ExpandLess,
                        contentDescription = if (collapsed) "Expand folder" else "Collapse folder",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                    OverflowMenu { dismiss ->
                        DropdownMenuItem(
                            text = { Text("Rename folder") },
                            onClick = {
                                dismiss()
                                onRename(RowRef(RowRef.Kind.FOLDER, folder.id, folder.name))
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Delete folder") },
                            onClick = {
                                dismiss()
                                onDelete(RowRef(RowRef.Kind.FOLDER, folder.id, folder.name))
                            },
                        )
                    }
                },
            )
        }
        if (!collapsed) {
            val folderPlaylists = sort.sorted(state.playlists.filter { it.folderId == folder.id })
            val folderPockets = sort.sorted(state.pockets.filter { it.folderId == folder.id })
            if (folderPlaylists.isEmpty() && folderPockets.isEmpty()) {
                item(key = "fld-empty-${folder.id}") {
                    SectionCaption("Empty folder — move a playlist or pocket in with its ⋯ menu.")
                }
            } else {
                folderPlaylists.forEach { playlistRow(it) }
                folderPockets.forEach { pocketRow(it) }
            }
        }
    }

    // 4. Setlists.
    setlistRows("")
}

/** Setlists to list on the Collections tab: reserved Now Playing set hidden, newest first, optional name filter. */
internal fun listableSetlists(all: List<Setlist>, query: String): List<Setlist> {
    val folded = Fmt.fold(query.trim())
    return all.filter { it.id != NOW_PLAYING_SETLIST_ID && it.playlistId != NOW_PLAYING_PLAYLIST_ID }
        .filter { folded.isEmpty() || Fmt.fold(setlistTitle(it)).contains(folded) }
        .sortedByDescending { it.generatedAt }
}

internal fun setlistTitle(sl: Setlist): String = sl.name?.takeIf { it.isNotBlank() } ?: "Set list"

@Composable
private fun PlaylistRow(
    playlist: Playlist,
    store: CollectionsStore,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onMove: () -> Unit,
    onDelete: () -> Unit,
    onExport: (com.levi.pocketdj.screens.collections.ExportRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val stats = store.statsForPlaylist(playlist.id)
    CollectionRow(
        modifier = modifier,
        icon = Icons.AutoMirrored.Filled.QueueMusic,
        iconTint = MaterialTheme.colorScheme.primary,
        name = playlist.name,
        subtitle = "${plural(playlist.sequences.size, "chapter")} · ${stats.summary}",
        onClick = onOpen,
        trailing = {
            OverflowMenu { dismiss ->
                DropdownMenuItem(text = { Text("Rename") }, onClick = { dismiss(); onRename() })
                DropdownMenuItem(text = { Text("Move to folder…") }, onClick = { dismiss(); onMove() })
                DropdownMenuItem(
                    text = { Text("Export…") },
                    onClick = { dismiss(); onExport(com.levi.pocketdj.screens.collections.CollectionExportRequests.playlistZip(store, playlist.id, playlist.name)) },
                )
                DropdownMenuItem(
                    text = { Text("Export CSV") },
                    onClick = { dismiss(); onExport(com.levi.pocketdj.screens.collections.CollectionExportRequests.playlistCsv(store, playlist.id, playlist.name)) },
                )
                DropdownMenuItem(text = { Text("Delete") }, onClick = { dismiss(); onDelete() })
            }
        },
    )
}

@Composable
private fun PocketRow(
    pocket: Pocket,
    store: CollectionsStore,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onMove: () -> Unit,
    onAddToPlaylist: () -> Unit,
    onDelete: () -> Unit,
    onExport: (com.levi.pocketdj.screens.collections.ExportRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val stats = store.statsForPocket(pocket.id)
    CollectionRow(
        modifier = modifier,
        icon = Icons.Filled.Layers,
        iconTint = MaterialTheme.colorScheme.primary,
        name = pocket.name,
        subtitle = "${plural(pocket.memberCount, "item")} · ${stats.summary}",
        onClick = onOpen,
        trailing = {
            OverflowMenu { dismiss ->
                DropdownMenuItem(text = { Text("Rename") }, onClick = { dismiss(); onRename() })
                DropdownMenuItem(text = { Text("Move to folder…") }, onClick = { dismiss(); onMove() })
                DropdownMenuItem(
                    text = { Text("Add to playlist…") },
                    onClick = { dismiss(); onAddToPlaylist() },
                )
                DropdownMenuItem(
                    text = { Text("Export…") },
                    onClick = { dismiss(); onExport(com.levi.pocketdj.screens.collections.CollectionExportRequests.pocketZip(store, pocket.id, pocket.name)) },
                )
                DropdownMenuItem(
                    text = { Text("Export CSV") },
                    onClick = { dismiss(); onExport(com.levi.pocketdj.screens.collections.CollectionExportRequests.pocketCsv(store, pocket.id, pocket.name)) },
                )
                DropdownMenuItem(text = { Text("Delete") }, onClick = { dismiss(); onDelete() })
            }
        },
    )
}

// ---- Shared tab (F2) -------------------------------------------------------

private fun LazyListScope.sharedTab(
    sources: List<SourcePlaylist>,
    sourceOrder: List<String>,
    sort: CollectionSortOrder,
    query: String,
    expandedSources: Set<String>,
    onToggleSource: (name: String, expanded: Boolean) -> Unit,
    onOpenSource: (playlistId: String, sourceName: String) -> Unit,
) {
    fun sourceRow(sp: SourcePlaylist) {
        item(key = "src-${sp.sourceName}-${sp.playlist.id}") {
            CollectionRow(
                icon = Icons.AutoMirrored.Filled.List,
                iconTint = MaterialTheme.colorScheme.tertiary,
                name = sp.playlist.name,
                subtitle = null,
                onClick = { onOpenSource(sp.playlist.id, sp.sourceName) },
                trailing = {
                    CapsuleBadge(sp.sourceName)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        plural(sp.playlist.songIds.size, "song"),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(end = 12.dp),
                    )
                },
            )
        }
    }

    // Search replaces grouping with flattened source matches (§2.2).
    if (query.isNotEmpty()) {
        val folded = Fmt.fold(query)
        val matches = sort.sortedSourcePlaylists(
            sources.filter { Fmt.fold(it.playlist.name).contains(folded) },
        )
        if (matches.isEmpty()) {
            item(key = "no-results") { SectionCaption("No results for \"$query\"") }
        } else {
            matches.forEach { sourceRow(it) }
        }
        return
    }

    // Empty state (§2.7).
    if (sources.isEmpty()) {
        item(key = "empty") {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp, vertical = 48.dp),
            ) {
                Icon(
                    Icons.Filled.LibraryMusic,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(44.dp),
                )
                Spacer(Modifier.height(10.dp))
                Text("No source playlists", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(6.dp))
                Text(
                    "Playlists from your enabled sources (Apple Music, vinyl, imports…) appear " +
                        "here. Enable a source in Settings, or add playlists to one.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        return
    }

    item(key = "hdr-sources") { SectionHeader("From your sources") }

    // Groups by sourceName: availableSources first-seen order, then any
    // group not in that list appended alphabetically (§2.7).
    val groups = sources.groupBy { it.sourceName }
    val ordered = sourceOrder.filter { it in groups.keys } +
        (groups.keys - sourceOrder.toSet()).sorted()

    ordered.forEach { name ->
        val members = groups[name].orEmpty()
        // Collapse-by-default with remembered EXPANSIONS (inverse-key semantics).
        val expanded = name in expandedSources
        item(key = "srcgrp-$name") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clickable { onToggleSource(name, !expanded) }
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            ) {
                Icon(
                    Icons.Filled.Inventory2,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(12.dp))
                Text(
                    name,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    members.size.toString(),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Icon(
                    if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = if (expanded) "Collapse source" else "Expand source",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 6.dp),
                )
            }
        }
        if (expanded) {
            sort.sortedSourcePlaylists(members).forEach { sourceRow(it) }
        }
    }

    item(key = "src-footer") {
        SectionCaption(
            "Read-only playlists from your enabled sources. Play one, or duplicate it into " +
                "an editable playlist.",
        )
    }
}

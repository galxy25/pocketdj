package com.levi.pocketdj.screens.collections

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.FuzzyMatch
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The Add-to-Collection modal sheet (specs/playlists-ui.md §8): fuzzy search field → Recent
 * (+ Suggested for songs, via the nullable rec seam) → Pockets A–Z → Playlists A–Z (per-chapter
 * sub-rows, inline create) → song-only "From your sources" local-copy adds.
 *
 * A ✓ row is a TOGGLE: tapping it removes (pocket membership; playlist every chapter) and the
 * ✓ is the only feedback (no snackbar). Every add funnels through [AddToActions] → the store's
 * choke points, which record the MRU and log one `add` activity — EXCEPT source-playlist adds,
 * which deliberately do neither.
 *
 * [onAdded] fires after a successful ADD (never a remove / empty batch / source add);
 * [stayOpenAfterAdd] keeps the sheet up after an add. Defaults preserve the original behaviour.
 * [searchFirst] focuses the search field on open (the context menu's "More…").
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddToCollectionSheet(
    item: AddToItem,
    onDismiss: () -> Unit,
    searchFirst: Boolean = false,
    onAdded: ((AddTarget) -> Unit)? = null,
    stayOpenAfterAdd: Boolean = false,
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }

    // First touch of the lazy stores reads their JSON docs — keep it off-main.
    val store by produceState<CollectionsStore?>(initialValue = null) {
        value = withContext(Dispatchers.IO) { graph.collections }
    }

    var sourceResult by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag("add-to-collection-sheet"),
    ) {
        val s = store
        if (s == null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator() }
        } else {
            SheetContent(
                item = item,
                store = s,
                graph = graph,
                searchFirst = searchFirst,
                onAdded = onAdded,
                stayOpenAfterAdd = stayOpenAfterAdd,
                onSourceResult = { sourceResult = it },
                onDismiss = onDismiss,
            )
        }
    }

    // Source-playlist adds explain exactly what happened before closing.
    sourceResult?.let { message ->
        AlertDialog(
            onDismissRequest = {
                sourceResult = null
                onDismiss()
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        sourceResult = null
                        onDismiss()
                    },
                ) { Text("OK") }
            },
            text = { Text(message) },
        )
    }
}

@Composable
private fun SheetContent(
    item: AddToItem,
    store: CollectionsStore,
    graph: AppGraph,
    searchFirst: Boolean,
    onAdded: ((AddTarget) -> Unit)?,
    stayOpenAfterAdd: Boolean,
    onSourceResult: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val collState by store.state.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val sourcePlaylists = catalogState.catalog?.playlists.orEmpty()
    val actions = remember(item, store) { AddToActions(item, store) }
    var search by remember { mutableStateOf("") }
    val searching = search.isNotBlank()
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(searchFirst) { if (searchFirst) focusRequester.requestFocus() }

    var nothingToAdd by remember { mutableStateOf(false) }
    // A row tap: ✓ ⇒ remove (stay open); otherwise add, then onAdded / dismiss per the params.
    fun tap(target: AddTarget, dedupe: CollectionsStore.BatchDedupe = CollectionsStore.BatchDedupe.WHOLE_COLLECTION) {
        val member = actions.isMember(target)
        val outcome = if (member) {
            actions.remove(target)
            AddToSheetParams.tapOutcome(true, false, stayOpenAfterAdd)
        } else {
            AddToSheetParams.tapOutcome(false, actions.add(target, dedupe), stayOpenAfterAdd)
        }
        if (!member && item is AddToItem.Songs && !outcome.fireOnAdded) nothingToAdd = true
        if (outcome.fireOnAdded) onAdded?.invoke(target)
        if (outcome.dismiss) onDismiss()
    }

    val suggestSeam = graph.collectionsGraph.collectionSuggestions
    // Recent: targets that STILL RESOLVE, top 3; Suggested (song items only) above, deduped.
    val recents = actions.recentTargets(3)
    // Resolve the seam once per open, off the main thread (not on every recomposition/keystroke).
    val suggestedWire by produceState(emptyList<CollectionSuggestion>(), item, suggestSeam) {
        value = if (item is AddToItem.Song && suggestSeam != null) {
            withContext(Dispatchers.IO) { suggestSeam(item.id) }
        } else {
            emptyList()
        }
    }
    val suggested = if (item is AddToItem.Song) {
        actions.suggestedTargets(suggestedWire, excluding = recents, limit = 3)
    } else {
        emptyList()
    }
    fun label(t: AddTarget) = store.lastTargetLabel(t) ?: ""
    val shownSuggested = FuzzyMatch.rank(suggested, search, ::label)
    val shownRecents = FuzzyMatch.rank(recents, search, ::label)
    val pockets = FuzzyMatch.rank(
        collState.pockets.sortedBy { it.name.lowercase() }, search,
    ) { it.name }
    val playlists = FuzzyMatch.rank(
        collState.playlists.sortedBy { it.name.lowercase() }, search,
    ) { it.name }
    val sources = FuzzyMatch.rank(
        sourcePlaylists.sortedBy { it.playlist.name.lowercase() }, search,
    ) { it.playlist.name }
    val showSources = item is AddToItem.Song && sources.isNotEmpty()
    val noMatches = searching && shownSuggested.isEmpty() && shownRecents.isEmpty() &&
        pockets.isEmpty() && playlists.isEmpty() && !showSources

    if (nothingToAdd && item is AddToItem.Songs) {
        AlertDialog(
            onDismissRequest = { nothingToAdd = false },
            confirmButton = { TextButton(onClick = { nothingToAdd = false }) { Text("OK") } },
            title = { Text("Nothing to add") },
            text = { Text("All ${item.ids.size} selected songs are already in this list.") },
        )
    }
    Column(modifier = Modifier.fillMaxWidth().navigationBarsPadding()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp),
        ) {
            Text(
                "Add to…",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.testTag("add-to-done"),
            ) { Text("Done") }
        }
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            singleLine = true,
            placeholder = { Text("Filter playlists and pockets") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (search.isNotEmpty()) {
                    IconButton(onClick = { search = "" }, modifier = Modifier.testTag("add-search-clear")) {
                        Icon(Icons.Filled.Clear, contentDescription = "Clear filter")
                    }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .focusRequester(focusRequester)
                .testTag("add-search-field"),
        )
        LazyColumn(modifier = Modifier.fillMaxWidth()) {
            if (item is AddToItem.Songs) {
                item(key = "adding") {
                    Text(
                        "Adding ${item.ids.size} song${if (item.ids.size == 1) "" else "s"}",
                        style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier
                            .padding(horizontal = 20.dp, vertical = 8.dp)
                            .testTag("add-songs-count"),
                    )
                }
            }

            if (noMatches) {
                item(key = "no-matches") {
                    Text(
                        "No playlists or pockets match “${search.trim()}”.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .padding(horizontal = 20.dp, vertical = 12.dp)
                            .testTag("add-search-no-matches"),
                    )
                }
            }

            if (shownSuggested.isNotEmpty()) {
                item(key = "suggested-header") { SectionHeader("Suggested") }
                items(shownSuggested.size, key = { "sug-${shownSuggested[it].kind.token}-${shownSuggested[it].id}" }) { i ->
                    val target = shownSuggested[i]
                    TargetRow(
                        icon = target.kind.icon(),
                        label = label(target),
                        checked = actions.isMember(target),
                        trailing = Icons.AutoMirrored.Filled.PlaylistAdd,
                        testTag = "add-to-suggested-${target.id}",
                        onClick = { tap(target) },
                    )
                }
            }

            if (shownRecents.isNotEmpty()) {
                item(key = "recent-header") { SectionHeader("Recent") }
                items(shownRecents.size, key = { "recent-${shownRecents[it].kind.token}-${shownRecents[it].id}" }) { i ->
                    val target = shownRecents[i]
                    TargetRow(
                        icon = target.kind.icon(),
                        label = label(target),
                        checked = actions.isMember(target),
                        trailing = Icons.AutoMirrored.Filled.PlaylistAdd,
                        testTag = "add-to-recent-${target.id}",
                        onClick = { tap(target) },
                    )
                }
            }

            item(key = "pockets-header") { SectionHeader("Pockets") }
            items(pockets.size, key = { "pkt-${pockets[it].id}" }) { i ->
                val pocket = pockets[i]
                TargetRow(
                    icon = Icons.Filled.Layers,
                    label = pocket.name,
                    checked = actions.inPocket(pocket),
                    testTag = "add-to-pocket-${pocket.id}",
                    onClick = { tap(AddTarget(AddTarget.Kind.POCKET, pocket.id)) },
                )
            }
            item(key = "new-pocket") {
                InlineCreateRow(
                    placeholder = "New pocket",
                    testTag = "add-to-new-pocket",
                    onCreate = { name ->
                        val pocket = store.createPocket(name)
                        tap(AddTarget(AddTarget.Kind.POCKET, pocket.id))
                    },
                )
            }

            item(key = "playlists-header") { SectionHeader("Playlists") }
            for (playlist in playlists) {
                item(key = "pls-${playlist.id}") {
                    TargetRow(
                        icon = Icons.AutoMirrored.Filled.QueueMusic,
                        label = playlist.name,
                        checked = actions.inPlaylist(playlist),
                        testTag = "add-to-playlist-${playlist.id}",
                        onClick = { tap(AddTarget(AddTarget.Kind.PLAYLIST, playlist.id)) },
                    )
                }
                if (playlist.sequences.size > 1) {
                    items(playlist.sequences.size, key = { "seq-${playlist.id}-${playlist.sequences[it].nodeId}" }) { i ->
                        val seq = playlist.sequences[i]
                        TargetRow(
                            icon = Icons.AutoMirrored.Filled.QueueMusic,
                            label = seq.name ?: "Chapter",
                            checked = false,
                            indented = true,
                            testTag = "add-to-chapter-${seq.nodeId}",
                            onClick = {
                                // An explicit chapter row dedupes against THAT chapter only.
                                val t = AddTarget(AddTarget.Kind.PLAYLIST, playlist.id, sequenceId = seq.nodeId)
                                val added = actions.add(t, CollectionsStore.BatchDedupe.TARGET_CHAPTER)
                                val o = AddToSheetParams.tapOutcome(false, added, stayOpenAfterAdd)
                                if (!added && item is AddToItem.Songs) nothingToAdd = true
                                if (o.fireOnAdded) onAdded?.invoke(t)
                                if (o.dismiss) onDismiss()
                            },
                        )
                    }
                }
            }
            item(key = "new-playlist") {
                InlineCreateRow(
                    placeholder = "New playlist",
                    testTag = "add-to-new-playlist",
                    onCreate = { name ->
                        val playlist = store.createPlaylist(name)
                        tap(AddTarget(AddTarget.Kind.PLAYLIST, playlist.id, sequenceId = playlist.sequences.firstOrNull()?.nodeId))
                    },
                )
            }
            item(key = "playlists-footer") {
                SectionFooter("Tapping a playlist adds to its default chapter. Tap a ✓ to remove.")
            }

            // SONG adds only; hidden for albums / batches or when no source playlists match.
            if (showSources && item is AddToItem.Song) {
                item(key = "sources-header") { SectionHeader("From your sources") }
                items(sources.size, key = { "src-${sources[it].sourceName}-${sources[it].playlist.id}" }) { i ->
                    val source = sources[i]
                    val duplicate = store.existingDuplicate(source)
                    val inSource = item.id in source.playlist.songIds
                    val inCopy = duplicate != null && store.playlistContains(duplicate.id, item.id)
                    SourceRow(
                        source = source,
                        hasDuplicate = duplicate != null,
                        checked = inSource || inCopy,
                        onClick = {
                            val outcome = store.addSongToIndexPlaylist(item.id, source)
                            onSourceResult(sourceAddMessage(outcome, source))
                        },
                    )
                }
                item(key = "sources-footer") {
                    SectionFooter(
                        "Tapping a source playlist adds to your local copy. Source playlists " +
                            "can't be edited from this device, so the add stays on this device.",
                    )
                }
            }

            item(key = "bottom-pad") { Spacer(Modifier.height(16.dp)) }
        }
    }
}

/** The result-alert copy — Android-honest (no write-back, no follow line). */
private fun sourceAddMessage(
    outcome: CollectionsStore.IndexPlaylistAdd,
    source: SourcePlaylist,
): String = when {
    // A freshly-created duplicate is seeded WITH the source's songs, so it reports
    // both createdDuplicate AND alreadyPresent — the "made a copy" case must win.
    outcome.createdDuplicate -> "Made a local copy of “${source.playlist.name}” and added the song."
    outcome.alreadyPresent -> "Already in your copy of “${source.playlist.name}”."
    else -> "Added to your copy of “${source.playlist.name}”."
}

private fun AddTarget.Kind.icon(): ImageVector = when (this) {
    AddTarget.Kind.POCKET -> Icons.Filled.Layers
    AddTarget.Kind.PLAYLIST -> Icons.AutoMirrored.Filled.QueueMusic
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 20.dp, top = 14.dp, bottom = 4.dp),
    )
}

@Composable
private fun SectionFooter(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
    )
}

@Composable
private fun TargetRow(
    icon: ImageVector,
    label: String,
    checked: Boolean,
    testTag: String,
    onClick: () -> Unit,
    indented: Boolean = false,
    trailing: ImageVector? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .padding(start = if (indented) 44.dp else 20.dp, end = 20.dp)
            .padding(vertical = 10.dp)
            .testTag(testTag),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        when {
            checked -> Icon(
                Icons.Filled.Check,
                contentDescription = "Already added",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
            trailing != null -> Icon(
                trailing,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/** Row subtitle states the consequence BEFORE the tap (spec §8.2.4). */
@Composable
private fun SourceRow(
    source: SourcePlaylist,
    hasDuplicate: Boolean,
    checked: Boolean,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 8.dp)
            .testTag("add-to-source-${source.playlist.id}"),
    ) {
        Icon(
            Icons.AutoMirrored.Filled.QueueMusic,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.secondary,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                source.playlist.name,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                source.sourceName +
                    if (hasDuplicate) " · adds to your local copy" else " · makes a local copy",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (checked) {
            Icon(
                Icons.Filled.Check,
                contentDescription = "Already added",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/** Inline create-AND-add: text field + Add button (disabled while blank). */
@Composable
private fun InlineCreateRow(
    placeholder: String,
    testTag: String,
    onCreate: (String) -> Unit,
) {
    var text by remember { mutableStateOf("") }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 4.dp),
    ) {
        Icon(
            Icons.Filled.Add,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(12.dp))
        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            singleLine = true,
            placeholder = { Text(placeholder) },
            modifier = Modifier
                .weight(1f)
                .testTag(testTag),
        )
        TextButton(
            enabled = text.isNotBlank(),
            onClick = { onCreate(text.trim()) },
            modifier = Modifier.testTag("$testTag-create"),
        ) { Text("Add") }
    }
}

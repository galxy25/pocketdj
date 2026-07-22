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
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.CollectionsStore
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** What the sheet is adding — a catalog song or a whole album. */
sealed interface AddToItem {
    val id: String

    data class Song(override val id: String) : AddToItem
    data class Album(override val id: String) : AddToItem
}

/**
 * The Add-to-Collection modal sheet (specs/playlists-ui.md §8): Recent top-3
 * quick-add (F11) → Pockets (checkmark when member, inline create) → Playlists
 * (default chapter on tap, per-chapter sub-rows, inline create) → song-only
 * "From your sources" local-copy adds with Android-honest wording.
 *
 * Every add funnels through the store's choke points ([CollectionsStore.addSong]
 * / [CollectionsStore.addAlbum]) which record the MRU and log one `add`
 * activity event — EXCEPT source-playlist adds, which deliberately do neither
 * (iOS parity: they route through the low-level membership path).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddToCollectionSheet(
    item: AddToItem,
    onDismiss: () -> Unit,
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
    onSourceResult: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val collState by store.state.collectAsState()
    val catalogState by graph.catalogRepository.state.collectAsState()
    val sourcePlaylists = catalogState.catalog?.playlists.orEmpty()

    fun performAdd(target: AddTarget) {
        when (item) {
            is AddToItem.Song -> store.addSong(item.id, target)
            is AddToItem.Album -> store.addAlbum(item.id, target)
        }
        onDismiss()
    }

    // Recent quick-add: targets that STILL RESOLVE (deleted collections drop
    // out — the store keeps 10 so drop-outs backfill), capped at the top 3.
    val recents = collState.recentAddTargets
        .mapNotNull { target -> store.lastTargetLabel(target)?.let { target to it } }
        .take(3)

    LazyColumn(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding(),
    ) {
        item(key = "header") {
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
        }

        if (recents.isNotEmpty()) {
            item(key = "recent-header") { SectionHeader("Recent") }
            items(recents.size, key = { "recent-${recents[it].first.kind.token}-${recents[it].first.id}" }) { i ->
                val (target, label) = recents[i]
                TargetRow(
                    icon = target.kind.icon(),
                    label = label,
                    checked = false,
                    trailing = Icons.AutoMirrored.Filled.PlaylistAdd,
                    testTag = "add-to-recent-${target.id}",
                    onClick = { performAdd(target) },
                )
            }
        }

        item(key = "pockets-header") { SectionHeader("Pockets") }
        items(collState.pockets.size, key = { "pkt-${collState.pockets[it].id}" }) { i ->
            val pocket = collState.pockets[i]
            val member = when (item) {
                is AddToItem.Song -> item.id in pocket.songIds
                is AddToItem.Album -> item.id in pocket.albumIds
            }
            TargetRow(
                icon = Icons.Filled.Layers,
                label = pocket.name,
                checked = member,
                testTag = "add-to-pocket-${pocket.id}",
                onClick = { performAdd(AddTarget(AddTarget.Kind.POCKET, pocket.id)) },
            )
        }
        item(key = "new-pocket") {
            InlineCreateRow(
                placeholder = "New pocket",
                testTag = "add-to-new-pocket",
                onCreate = { name ->
                    val pocket = store.createPocket(name)
                    performAdd(AddTarget(AddTarget.Kind.POCKET, pocket.id))
                },
            )
        }

        item(key = "playlists-header") { SectionHeader("Playlists") }
        for (playlist in collState.playlists) {
            item(key = "pls-${playlist.id}") {
                TargetRow(
                    icon = Icons.AutoMirrored.Filled.QueueMusic,
                    label = playlist.name,
                    checked = playlistHas(playlist, item),
                    testTag = "add-to-playlist-${playlist.id}",
                    onClick = { performAdd(AddTarget(AddTarget.Kind.PLAYLIST, playlist.id)) },
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
                            performAdd(AddTarget(AddTarget.Kind.PLAYLIST, playlist.id, sequenceId = seq.nodeId))
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
                    performAdd(AddTarget(AddTarget.Kind.PLAYLIST, playlist.id))
                },
            )
        }
        item(key = "playlists-footer") {
            SectionFooter("Tapping a playlist adds to its default chapter.")
        }

        // SONG adds only; hidden for albums or when no source playlists exist.
        if (item is AddToItem.Song && sourcePlaylists.isNotEmpty()) {
            val ordered = sourcePlaylists.sortedBy { it.playlist.name.lowercase() }
            item(key = "sources-header") { SectionHeader("From your sources") }
            items(ordered.size, key = { "src-${ordered[it].sourceName}-${ordered[it].playlist.id}" }) { i ->
                val source = ordered[i]
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

/** The result-alert copy — Android-honest (no write-back, no follow line). */
private fun sourceAddMessage(
    outcome: CollectionsStore.IndexPlaylistAdd,
    source: SourcePlaylist,
): String = when {
    // A freshly-created duplicate is seeded WITH the source's songs, so it reports
    // both createdDuplicate AND alreadyPresent — the "made a copy" case must win
    // (checking alreadyPresent first would hide that a local copy was just made).
    outcome.createdDuplicate -> "Made a local copy of “${source.playlist.name}” and added the song."
    outcome.alreadyPresent -> "Already in your copy of “${source.playlist.name}”."
    else -> "Added to your copy of “${source.playlist.name}”."
}

private fun AddTarget.Kind.icon(): ImageVector = when (this) {
    AddTarget.Kind.POCKET -> Icons.Filled.Layers
    AddTarget.Kind.PLAYLIST -> Icons.AutoMirrored.Filled.QueueMusic
}

/** DIRECT membership walk of a playlist template (song/album leaves only). */
private fun playlistHas(playlist: Playlist, item: AddToItem): Boolean {
    fun walk(nodes: List<PlaylistNode>): Boolean = nodes.any { n ->
        when {
            item is AddToItem.Song && n.kind == PlaylistNode.Kind.SONG && n.songId == item.id -> true
            item is AddToItem.Album && n.kind == PlaylistNode.Kind.ALBUM && n.albumId == item.id -> true
            else -> n.children?.let { walk(it) } == true
        }
    }
    return walk(playlist.sequences)
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

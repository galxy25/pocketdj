package com.levi.pocketdj.screens.collections

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The long-press "Add to Playlist" submenu for every song/album row (iOS `AddToPlaylistMenu`):
 * the sheet's Suggested (song items, via the nullable rec seam) then Recent targets, up to five,
 * each a ✓ toggle (tap a ✓ row to remove) — then "More…", which hands off to the full sheet with
 * its search field focused. Compose has no nested menus, so it renders as a compact dialog.
 * Toggling closes the menu; the ✓ on the next open is the feedback (no snackbar).
 *
 * Callers own presentation: [onMore] should show [AddToCollectionSheet] with `searchFirst = true`.
 */
@Composable
fun AddToPlaylistMenu(
    item: AddToItem,
    onDismiss: () -> Unit,
    onMore: () -> Unit,
    /** Extra rows (label, action) appended after "More…" — e.g. Browse's Select / Copy. */
    extraActions: List<Pair<String, () -> Unit>> = emptyList(),
) {
    val context = LocalContext.current
    val graph = remember { AppGraph.get(context) }
    val store by produceState<com.levi.pocketdj.data.collections.CollectionsStore?>(null) {
        value = withContext(Dispatchers.IO) { graph.collections }
    }
    val s = store ?: return
    val collState by s.state.collectAsState()
    val actions = remember(item, s) { AddToActions(item, s) }
    val seam = graph.collectionsGraph.collectionSuggestions
    // Recomputed whenever the store state changes (recents / membership).
    val targets = remember(collState, item) { actions.quickTargets(AddToActions.QUICK_LIMIT, seam) }

    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag("ctx-add-to-playlist"),
        title = { Text("Add to Playlist") },
        text = {
            Column(Modifier.fillMaxWidth()) {
                targets.forEachIndexed { idx, target ->
                    MenuRow(
                        icon = if (target.kind == AddTarget.Kind.POCKET) Icons.Filled.Layers else Icons.AutoMirrored.Filled.QueueMusic,
                        label = s.lastTargetLabel(target).orEmpty(),
                        checked = actions.isMember(target),
                        testTag = "ctx-add-target-$idx",
                        onClick = {
                            actions.toggle(target)
                            onDismiss()
                        },
                    )
                }
                MenuRow(
                    icon = Icons.Filled.Search,
                    label = "More…",
                    checked = false,
                    testTag = "ctx-add-playlist-more",
                    onClick = onMore,
                )
                extraActions.forEachIndexed { i, (label, action) ->
                    MenuRow(
                        icon = Icons.Filled.Search,
                        label = label,
                        checked = false,
                        testTag = "ctx-extra-$i",
                        onClick = { action(); onDismiss() },
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun MenuRow(icon: ImageVector, label: String, checked: Boolean, testTag: String, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp)
            .testTag(testTag),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (checked) {
            Icon(Icons.Filled.Check, contentDescription = "In this collection", tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
        }
    }
}

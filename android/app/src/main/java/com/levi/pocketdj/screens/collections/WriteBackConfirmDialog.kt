package com.levi.pocketdj.screens.collections

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.levi.pocketdj.data.collections.CollectionsStore

/**
 * "Add to Apple Music?" (iOS RootView alert). A LARGE batch add to an Apple-Music-linked collection
 * parks its upstream leg here: Apple Music adds are append-only and not undoable from this app, so a
 * select-all-sized batch never writes upstream implicitly. The LOCAL add has already landed either
 * way. Mounted once at the shell root; the first answer clears the shared pending state.
 */
@Composable
fun WriteBackConfirmDialog(store: CollectionsStore) {
    val pending by store.pendingWriteBackBatch.collectAsState()
    val batch = pending ?: return
    AlertDialog(
        onDismissRequest = { store.discardPendingWriteBackBatch() },
        title = { Text("Add to Apple Music?") },
        text = {
            Text(
                "Also add these ${batch.count} songs to your Apple Music playlist " +
                    "“${batch.playlistName}”? PocketDJ can’t undo Apple Music adds.",
            )
        },
        confirmButton = {
            TextButton(
                onClick = { store.confirmPendingWriteBackBatch() },
                modifier = Modifier.testTag("writeback-confirm"),
            ) { Text("Add ${batch.count} songs") }
        },
        dismissButton = {
            TextButton(
                onClick = { store.discardPendingWriteBackBatch() },
                modifier = Modifier.testTag("writeback-discard"),
            ) { Text("Keep local only") }
        },
        modifier = Modifier.testTag("writeback-confirm-dialog"),
    )
}

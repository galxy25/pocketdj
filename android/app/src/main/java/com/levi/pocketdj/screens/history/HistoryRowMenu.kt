package com.levi.pocketdj.screens.history

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag

/** The actions on a History timeline row's long-press menu (iOS `rowMenu`). */
internal enum class HistoryRowAction(val label: String) {
    REWIND("Rewind to here"),
    ADD_TO("Add to…"),
    SHARE("Share"),
}

/**
 * Row context menu: Rewind to here (moved here from the removed Unified view), Add to… (the shared
 * AddTo sheet), Share. The host owns confirmation (a rewind ALWAYS confirms), the sheet, and the
 * share intent — this only reports which action was picked for which row.
 */
@Composable
internal fun HistoryRowMenu(
    expanded: Boolean,
    ref: PlayRef,
    onDismiss: () -> Unit,
    onAction: (HistoryRowAction) -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        HistoryRowAction.entries.forEach { action ->
            DropdownMenuItem(
                text = { Text(action.label) },
                leadingIcon = {
                    Icon(
                        when (action) {
                            HistoryRowAction.REWIND -> Icons.Filled.FastRewind
                            HistoryRowAction.ADD_TO -> Icons.Filled.AddCircleOutline
                            HistoryRowAction.SHARE -> Icons.Filled.Share
                        },
                        contentDescription = null,
                    )
                },
                onClick = {
                    onDismiss()
                    onAction(action)
                },
                modifier = Modifier.testTag("history-${action.name.lowercase()}-${ref.songId}"),
            )
        }
    }
}

package com.levi.pocketdj.screens.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * P1 sort sheet — the multi-key builder (specs/browse.md §6.5, iOS
 * `Views/SortSheet.swift`). Applied keys are shown top-down (top = primary);
 * each key toggles asc/desc, moves up/down to change priority, or is removed;
 * unused sortable fields are offered under "Add key". M3 modal bottom sheet,
 * styled to match [BrowseFilterSheet].
 *
 * Drag-reorder (the iOS affordance) is cut to explicit move up/down here — the
 * robust ModalBottomSheet equivalent; the engine order is identical either way.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BrowseSortSheet(
    kind: BrowseKind,
    sortKeys: List<SortKey>,
    onSortKeys: (List<SortKey>) -> Unit,
    onDismiss: () -> Unit,
) {
    val sortable = SortField.forKind(kind)
    val usedIds = sortKeys.map { it.field.id }.toSet()
    val unused = sortable.filter { it.id !in usedIds }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
                .padding(bottom = 24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    "Sort",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { onSortKeys(emptyList()) },
                    enabled = sortKeys.isNotEmpty(),
                ) {
                    Text("Clear all")
                }
            }

            if (sortKeys.isEmpty()) {
                Text(
                    "No sort. Default order is artist › title.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp),
                )
            } else {
                sortKeys.forEachIndexed { index, key ->
                    SortKeyRow(
                        position = index + 1,
                        key = key,
                        canMoveUp = index > 0,
                        canMoveDown = index < sortKeys.size - 1,
                        onToggleDir = {
                            onSortKeys(sortKeys.replaceAt(index, key.copy(ascending = !key.ascending)))
                        },
                        onMoveUp = { onSortKeys(sortKeys.moveItem(index, index - 1)) },
                        onMoveDown = { onSortKeys(sortKeys.moveItem(index, index + 1)) },
                        onRemove = { onSortKeys(sortKeys.removeAt(index)) },
                    )
                }
            }

            if (unused.isNotEmpty()) {
                Spacer(Modifier.height(16.dp))
                Text(
                    "Add key",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    unused.forEach { field ->
                        AssistChip(
                            onClick = { onSortKeys(sortKeys + SortKey(field)) },
                            label = { Text(field.label) },
                            leadingIcon = {
                                Icon(
                                    Icons.Filled.Add,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SortKeyRow(
    position: Int,
    key: SortKey,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onToggleDir: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        Text(
            "$position",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(18.dp),
        )
        Text(
            key.field.label,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onToggleDir) {
            Icon(
                if (key.ascending) Icons.Filled.ArrowUpward else Icons.Filled.ArrowDownward,
                contentDescription = if (key.ascending) "Ascending" else "Descending",
                tint = MaterialTheme.colorScheme.primary,
            )
        }
        IconButton(onClick = onMoveUp, enabled = canMoveUp) {
            Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "Move up")
        }
        IconButton(onClick = onMoveDown, enabled = canMoveDown) {
            Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Move down")
        }
        IconButton(onClick = onRemove) {
            Icon(Icons.Filled.Close, contentDescription = "Remove")
        }
    }
}

private fun <T> List<T>.replaceAt(index: Int, value: T): List<T> =
    toMutableList().also { it[index] = value }

private fun <T> List<T>.removeAt(index: Int): List<T> =
    toMutableList().also { it.removeAt(index) }

/** Move the item at [from] to [to]; a no-op when [to] is out of bounds. */
private fun <T> List<T>.moveItem(from: Int, to: Int): List<T> {
    if (to !in indices) return this
    return toMutableList().also { it.add(to, it.removeAt(from)) }
}

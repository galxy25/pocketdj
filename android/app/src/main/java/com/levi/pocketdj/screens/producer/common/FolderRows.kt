package com.levi.pocketdj.screens.producer.common

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.studio.model.StudioFolder

/** A folder row (name + count) with a rename/delete overflow. */
@Composable
fun FolderRow(
    folder: StudioFolder,
    count: Int,
    onOpen: () -> Unit,
    onRename: (String) -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    Row(
        modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 16.dp, vertical = 10.dp).testTag("folder-${folder.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Text(folder.name, Modifier.weight(1f).padding(start = 12.dp), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
        Text("$count", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Folder actions") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; renaming = true })
                DropdownMenuItem(text = { Text("Delete folder") }, onClick = { menu = false; onDelete() })
            }
        }
    }
    if (renaming) NameDialog("Rename folder", folder.name, "Rename", { renaming = false }) { renaming = false; onRename(it) }
}

/** "Move to" menu items: Unfiled + every folder (the current one is disabled). */
@Composable
fun MoveToItems(folders: List<StudioFolder>, currentFolderId: String?, onMove: (String?) -> Unit, onNewFolder: () -> Unit) {
    DropdownMenuItem(text = { Text("Move to Unfiled") }, enabled = currentFolderId != null, onClick = { onMove(null) },
        modifier = Modifier.testTag("move-to-unfiled"))
    folders.forEach { f ->
        DropdownMenuItem(text = { Text("Move to ${f.name}") }, enabled = f.id != currentFolderId, onClick = { onMove(f.id) },
            modifier = Modifier.testTag("move-to-${f.id}"))
    }
    DropdownMenuItem(text = { Text("New folder…") }, onClick = onNewFolder)
}

/** Single-field name prompt (new folder / rename). Blank input is rejected by disabling the confirm button. */
@Composable
fun NameDialog(title: String, initial: String, confirm: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(text, { text = it }, singleLine = true, modifier = Modifier.testTag("name-field")) },
        confirmButton = { TextButton(enabled = text.trim().isNotEmpty(), onClick = { onConfirm(text.trim()) }) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

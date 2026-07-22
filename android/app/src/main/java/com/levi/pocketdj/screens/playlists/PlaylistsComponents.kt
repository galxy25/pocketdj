package com.levi.pocketdj.screens.playlists

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.collections.PlaylistFolder
import com.levi.pocketdj.screens.browse.AlbumArt
import com.levi.pocketdj.screens.browse.Fmt
import com.levi.pocketdj.screens.browse.KeyChip

/**
 * Shared building blocks for the Playlists tab (specs/playlists-ui.md): name /
 * confirm dialogs (§3), the overflow row menu, the shared collection track row
 * (art via catalog lookup, dimmed when unplayable — sources-reality rule), the
 * move-to-folder picker (§2.8), and small caption/section helpers.
 */

/** "3 chapters" / "1 song" pluralizer used across subtitles. */
fun plural(count: Int, word: String): String = "$count $word" + if (count == 1) "" else "s"

/** Epoch ms → medium date ("Jul 21, 2026") for setlist rows/headers. */
fun dateLabel(epochMs: Double): String =
    java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM)
        .format(java.util.Date(epochMs.toLong()))

/**
 * Single-text-field create/rename dialog (§3): trimmed, empty ⇒ no-op (the
 * dialog just dismisses without calling [onConfirm]).
 */
@Composable
fun NameDialog(
    title: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
    initial: String = "",
    placeholder: String = "Name",
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                placeholder = { Text(placeholder) },
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val trimmed = text.trim()
                    onDismiss()
                    if (trimmed.isNotEmpty()) onConfirm(trimmed)
                },
            ) { Text(confirmLabel) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Destructive-action confirmation (§3) — the confirmed delete path. */
@Composable
fun ConfirmDialog(
    title: String,
    text: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = {
            TextButton(
                onClick = {
                    onDismiss()
                    onConfirm()
                },
            ) { Text(confirmLabel, color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * Trailing ⋯ button + anchored dropdown — the Android stand-in for iOS's row
 * context menu / swipe actions. [content] receives a `dismiss` to call from
 * every item's onClick.
 */
@Composable
fun OverflowMenu(
    modifier: Modifier = Modifier,
    icon: ImageVector = Icons.Filled.MoreVert,
    contentDescription: String = "More",
    content: @Composable androidx.compose.foundation.layout.ColumnScope.(dismiss: () -> Unit) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        IconButton(onClick = { expanded = true }) {
            Icon(
                icon,
                contentDescription = contentDescription,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            content { expanded = false }
        }
    }
}

/** Section header ("Your playlists", "Pockets", chapter names…). */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, trailing: String? = null) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(top = 14.dp, bottom = 4.dp),
    ) {
        Text(
            text,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )
        trailing?.let {
            Text(
                it,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** In-section dim caption ("No playlists yet — tap + to create one."). */
@Composable
fun SectionCaption(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

/** Small capsule badge ("pocket", "↔ bridge", chapter or source names). */
@Composable
fun CapsuleBadge(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 6.dp, vertical = 1.dp),
    )
}

/**
 * Generic collection row: leading icon, name, subtitle, trailing overflow
 * actions — playlists / pockets / folders / setlists at the top level all
 * render through it (§2.8).
 */
@Composable
fun CollectionRow(
    icon: ImageVector,
    iconTint: androidx.compose.ui.graphics.Color,
    name: String,
    subtitle: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    nameStyle: FontStyle = FontStyle.Normal,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .padding(start = 16.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                name,
                style = MaterialTheme.typography.bodyMedium,
                fontStyle = nameStyle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            subtitle?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        trailing?.invoke(this)
    }
}

/**
 * Shared collection TRACK row (§5.2, §6.1, §7.1): 40dp art via catalog lookup,
 * title/artist, BPM + key chip + duration, dimmed when [dimmed] (metadata-only
 * on Android — the honest unplayable presentation). Snapshot-friendly: all
 * display fields ride in directly so a frozen setlist row renders even when the
 * song vanished from the catalog.
 */
@Composable
fun CollectionTrackRow(
    title: String,
    subtitle: String?,
    album: IndexAlbum?,
    bpm: Double?,
    camelot: String?,
    lengthMs: Long?,
    dimmed: Boolean,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    badges: (@Composable RowScope.() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    val alpha = if (dimmed) 0.45f else 1f
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .let { base -> if (onClick != null) base.clickable(onClick = onClick) else base }
            .fillMaxWidth()
            .padding(start = 12.dp, end = 4.dp, top = 3.dp, bottom = 3.dp),
    ) {
        leading?.invoke()
        AlbumArt(album, modifier = Modifier.size(40.dp))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = alpha),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                subtitle?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                badges?.invoke(this)
            }
        }
        Spacer(Modifier.width(6.dp))
        Text(
            Fmt.bpm(bpm),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(30.dp),
        )
        KeyChip(null, camelot)
        Spacer(Modifier.width(6.dp))
        Text(
            Fmt.duration(lengthMs),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        trailing?.invoke(this)
    }
}

/** "(missing song)" degrade row — unresolvable and Studio ids alike (§5.2). */
@Composable
fun MissingItemRow(label: String = "(missing song)", modifier: Modifier = Modifier) {
    Text(
        label,
        style = MaterialTheme.typography.bodyMedium,
        fontStyle = FontStyle.Italic,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    )
}

/**
 * Move-to-folder picker (§2.8 context menu ▸ Move to folder): Top level /
 * each folder (✓ on the current one) / inline "New folder…" create-and-move.
 */
@Composable
fun MoveToFolderDialog(
    folders: List<PlaylistFolder>,
    currentFolderId: String?,
    onDismiss: () -> Unit,
    onMove: (folderId: String?) -> Unit,
    onCreateAndMove: (name: String) -> Unit,
) {
    var newName by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Move to folder") },
        text = {
            Column {
                FolderChoiceRow(
                    label = "Top level",
                    selected = currentFolderId == null,
                    onClick = {
                        onDismiss()
                        onMove(null)
                    },
                )
                folders.forEach { folder ->
                    FolderChoiceRow(
                        label = folder.name,
                        selected = currentFolderId == folder.id,
                        onClick = {
                            onDismiss()
                            onMove(folder.id)
                        },
                    )
                }
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = newName,
                        onValueChange = { newName = it },
                        singleLine = true,
                        placeholder = { Text("New folder…") },
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(
                        enabled = newName.isNotBlank(),
                        onClick = {
                            val trimmed = newName.trim()
                            onDismiss()
                            if (trimmed.isNotEmpty()) onCreateAndMove(trimmed)
                        },
                    ) { Text("Add") }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun FolderChoiceRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(onClick = onClick)
            .fillMaxWidth()
            .padding(vertical = 10.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        if (selected) {
            Icon(
                Icons.Filled.Check,
                contentDescription = "Current folder",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

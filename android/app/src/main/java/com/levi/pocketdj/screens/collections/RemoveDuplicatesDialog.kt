package com.levi.pocketdj.screens.collections

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable

/** Result-alert title for a "Remove duplicates" run (iOS `RemoveDuplicatesAlert.title`). */
fun removeDuplicatesTitle(removed: Int): String = when {
    removed <= 0 -> "No duplicates found"
    removed == 1 -> "Removed 1 duplicate"
    else -> "Removed $removed duplicates"
}

internal const val REMOVE_DUPLICATES_EXPLAINER =
    "Same song on the same album, listed twice (e.g. the featured artist in the title on one " +
        "copy, in the artist on the other). Where the copies differed, the one that streams " +
        "from Apple Music was kept."

/** Shared by the pocket / playlist ⋯ menus and the Collections tab. [removed] non-null ⇒ shown. */
@Composable
fun RemoveDuplicatesResultAlert(removed: Int?, onDismiss: () -> Unit) {
    if (removed == null) return
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(removeDuplicatesTitle(removed)) },
        text = { Text(REMOVE_DUPLICATES_EXPLAINER) },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
    )
}

package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Session-name rules (iOS `MixSessionStore.rename` is lenient; the UI never saves blank). */
object SessionHeaderRules {
    const val RESET_TITLE = "Start a new session?"
    const val RESET_MESSAGE = "The current session is saved to Sessions. The fresh session starts with no played tracks."

    /** null ⇒ keep the old name (blank / unchanged draft). */
    fun renamed(draft: String, current: String): String? =
        draft.trim().takeIf { it.isNotEmpty() && it != current }
}

/**
 * The renamable session-name capsule, in the CONTENT (a toolbar title can't host a long-press menu):
 * tap = rename, long-press = Rename… / New Session / All Sessions….
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionHeader(
    name: String,
    onRename: (String) -> Unit,
    onNewSession: () -> Unit,
    onAllSessions: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var renaming by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    Box(modifier) {
        Surface(
            shape = CircleShape, color = DeckColors.raised, border = BorderStroke(1.dp, DeckColors.border),
            modifier = Modifier
                .combinedClickable(onClick = { draft = name; renaming = true }, onLongClick = { menu = true })
                .testTag("mix-session-title"),
        ) {
            Row(Modifier.padding(horizontal = 14.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.GraphicEq, null, tint = DeckColors.accent, modifier = Modifier.size(18.dp))
                Text(
                    name, color = DeckColors.fg, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 6.dp),
                )
                Icon(Icons.Filled.Edit, null, tint = DeckColors.dim, modifier = Modifier.size(13.dp))
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Rename Session…") }, onClick = { menu = false; draft = name; renaming = true })
            DropdownMenuItem(text = { Text("New Session") }, onClick = { menu = false; onNewSession() })
            DropdownMenuItem(text = { Text("All Sessions…") }, onClick = { menu = false; onAllSessions() })
        }
    }
    if (renaming) AlertDialog(
        onDismissRequest = { renaming = false },
        title = { Text("Rename session") },
        text = {
            OutlinedTextField(draft, { draft = it }, singleLine = true, modifier = Modifier.testTag("mix-rename-field"))
        },
        confirmButton = {
            TextButton(
                onClick = { SessionHeaderRules.renamed(draft, name)?.let(onRename); renaming = false },
                modifier = Modifier.testTag("mix-rename-confirm"),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = { renaming = false }) { Text("Cancel") } },
    )
}

/** Reset (X) confirmation: "Start a new session?" -> "New session". */
@Composable
fun ResetSessionDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(SessionHeaderRules.RESET_TITLE) },
        text = { Text(SessionHeaderRules.RESET_MESSAGE) },
        confirmButton = {
            TextButton(onClick = onConfirm, modifier = Modifier.testTag("mix-reset-confirm")) { Text("New session") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

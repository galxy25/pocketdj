package com.levi.pocketdj.screens.games

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.games.friends.MwFLink
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Join Session sheet (iOS `MwFJoinSheet`). [link] is the pre-parsed link when opened from a tapped
 * URL (hides the paste field). The theme preview is debounced 300 ms and cleared on every edit so a
 * stale response for an older link can never label a different session.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MwFJoinSheet(graph: AppGraph, link: MwFLink?, onDismiss: () -> Unit) {
    val friends = graph.gamesGraph.friends
    val joining by friends.joining.collectAsState()
    val scope = rememberCoroutineScope()
    var pasted by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    var themePreview by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    val parsed: MwFLink? = link ?: MwFLink.parse(pasted)

    LaunchedEffect(Unit) {
        val name = runCatching { graph.servicesGraph.profile.name }.getOrDefault("")
        displayName = MwFScreenLogic.defaultNames(name).first
    }

    // Keyed on the pasted text: every edit cancels the in-flight fetch and clears the old theme first.
    LaunchedEffect(pasted, link) {
        themePreview = null
        if (link == null) delay(MwFScreenLogic.PREVIEW_DEBOUNCE_MS)
        val target = (link ?: MwFLink.parse(pasted)) ?: return@LaunchedEffect
        val pub = runCatching { graph.gamesGraph.mwfClient.publicState(target.stateUrl) }.getOrNull() ?: return@LaunchedEffect
        themePreview = pub.theme
    }

    val dismiss = { friends.clearPendingJoin(); onDismiss() }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp).testTag("mwf-join-sheet"),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Join Session", style = MaterialTheme.typography.titleLarge)
            if (link == null) {
                OutlinedTextField(
                    pasted, { pasted = it; error = null },
                    label = { Text("Session link") },
                    placeholder = { Text("https://jukebox.pocket-dj.com/mwf/…") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("mwf-join-link"),
                )
            }
            themePreview?.takeIf { it.isNotEmpty() }?.let {
                Text("Theme", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(it, style = MaterialTheme.typography.titleMedium, modifier = Modifier.testTag("mwf-join-theme"))
            }
            OutlinedTextField(
                displayName, { displayName = it }, label = { Text("Display name") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("mwf-join-name"),
            )
            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("mwf-join-error"))
            }
            Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = dismiss) { Text("Cancel") }
                Button(
                    enabled = parsed != null && !joining,
                    onClick = {
                        val target = parsed ?: return@Button
                        error = null
                        scope.launch {
                            error = friends.join(target, displayName)
                            if (error == null) onDismiss()
                        }
                    },
                    modifier = Modifier.testTag("mwf-join-submit"),
                ) { Text(if (joining) "Joining…" else "Join") }
            }
        }
    }
}

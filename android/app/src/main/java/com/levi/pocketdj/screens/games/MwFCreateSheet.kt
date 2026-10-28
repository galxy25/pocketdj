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
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.games.friends.MwFSettings
import com.levi.pocketdj.di.AppGraph
import kotlinx.coroutines.launch

/** New Session sheet (iOS `MwFCreateSheet`). The error is THIS sheet's own, never a shared field. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MwFCreateSheet(graph: AppGraph, onDismiss: () -> Unit) {
    val friends = graph.gamesGraph.friends
    val creating by friends.creating.collectAsState()
    val settings by graph.settings.settings.collectAsState(initial = null)
    val serverUrl = settings?.jukeboxServerUrl.orEmpty()
    val scope = rememberCoroutineScope()

    var sessionName by rememberSaveable { mutableStateOf("") }
    var theme by rememberSaveable { mutableStateOf("") }
    var displayName by rememberSaveable { mutableStateOf("") }
    var turnSeconds by rememberSaveable { mutableIntStateOf(120) }
    var outside by rememberSaveable { mutableStateOf(false) }
    var firstEnds by rememberSaveable { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        val name = runCatching { graph.servicesGraph.profile.name }.getOrDefault("")
        val (dn, sn) = MwFScreenLogic.defaultNames(name)
        if (displayName.isEmpty()) displayName = dn
        if (sessionName.isEmpty()) sessionName = sn
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp).testTag("mwf-create-sheet"),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("New Session", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                sessionName, { sessionName = it }, label = { Text("Session name") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("mwf-create-session-name"),
            )
            OutlinedTextField(
                theme, { theme = MwFScreenLogic.clampTheme(it) },
                label = { Text("Theme (what should friends suggest?)") },
                minLines = 2, maxLines = 4,
                supportingText = { Text("${theme.length}/${MwFScreenLogic.THEME_MAX}", modifier = Modifier.testTag("mwf-create-theme-count")) },
                modifier = Modifier.fillMaxWidth().testTag("mwf-create-theme"),
            )
            OutlinedTextField(
                displayName, { displayName = it }, label = { Text("Your display name") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().testTag("mwf-create-name"),
            )
            Text("Turns", style = MaterialTheme.typography.titleSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.testTag("mwf-create-turn")) {
                for ((secs, label) in MwFScreenLogic.TURN_CHOICES) {
                    FilterChip(selected = turnSeconds == secs, onClick = { turnSeconds = secs }, label = { Text(label) })
                }
            }
            SwitchRow("Accept suggestions outside turns", outside, { outside = it }, "mwf-create-outside")
            SwitchRow("Turn ends on first suggestion", firstEnds, { firstEnds = it }, "mwf-create-first")
            if (settings != null && serverUrl.isBlank()) {
                Text(
                    "No jukebox server configured — set one in Settings ▸ Jukebox Hero.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.testTag("mwf-create-no-server"),
                )
            }
            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("mwf-create-error"))
            }
            Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Button(
                    enabled = settings != null && MwFScreenLogic.canCreate(theme, serverUrl, creating),
                    onClick = {
                        error = null
                        scope.launch {
                            error = friends.create(
                                sessionName, theme, displayName,
                                MwFSettings(turnSeconds, outside, firstEnds),
                            )
                            if (error == null) onDismiss()
                        }
                    },
                    modifier = Modifier.testTag("mwf-create-submit"),
                ) { Text(if (creating) "Creating…" else "Create") }
            }
        }
    }
}

@Composable
internal fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit, tag: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked = checked, onCheckedChange = onChange, modifier = Modifier.testTag(tag))
    }
}

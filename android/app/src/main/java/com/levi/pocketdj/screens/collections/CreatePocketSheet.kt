package com.levi.pocketdj.screens.collections

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.data.pockets.PocketBriefParser
import com.levi.pocketdj.data.pockets.PocketBuilderService
import com.levi.pocketdj.data.pockets.PocketFitter

/** "Create pocket…": a typed or dictated brief ("90s chill hip hop") and a length. Submitting starts the async build. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreatePocketSheet(
    onDismiss: () -> Unit,
    onCreate: (brief: String, minutes: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    var brief by rememberSaveable { mutableStateOf("") }
    // The chosen length; a length spoken in the brief ("a 45 minute pocket") wins.
    var minutes by rememberSaveable { mutableIntStateOf(PocketFitter.DEFAULT_MINUTES) }
    val spokenMinutes = remember(brief) { PocketBriefParser.parse(brief).minutes }
    val submit = { if (brief.isNotBlank()) { onCreate(brief.trim(), spokenMinutes ?: minutes); onDismiss() } }

    val speech = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) {
            r.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.let { brief = it }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, modifier = modifier.testTag("create-pocket-sheet")) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Create pocket", style = MaterialTheme.typography.titleLarge)
            Text(
                "Describe it: a mood, genres, a decade or years. “90s chill hip hop”, “optimistic soul or funk, 1960–1989”.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = brief,
                onValueChange = { brief = it },
                placeholder = { Text("What should the pocket sound like?") },
                minLines = 2,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                trailingIcon = {
                    IconButton(onClick = {
                        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                            .putExtra(RecognizerIntent.EXTRA_PROMPT, "Describe your pocket")
                        try { speech.launch(intent) } catch (_: ActivityNotFoundException) { /* no recogniser: typing still works */ }
                    }) { Icon(Icons.Filled.Mic, contentDescription = "Dictate the brief") }
                },
                modifier = Modifier.fillMaxWidth().testTag("create-pocket-brief"),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(30, 60, 90, 120).forEach { m ->
                    FilterChip(selected = (spokenMinutes ?: minutes) == m, enabled = spokenMinutes == null, onClick = { minutes = m }, label = { Text("$m min") })
                }
            }
            if (spokenMinutes != null) {
                Text(
                    "Length taken from your description: $spokenMinutes min.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Button(
                onClick = { submit() },
                enabled = brief.isNotBlank(),
                modifier = Modifier.fillMaxWidth().testTag("create-pocket-go"),
            ) { Text("Create pocket") }
        }
    }
}

/** The Collections-tab status strip for the async build ([PocketBuilderService.phase]); renders nothing when idle. */
@Composable
fun CreatePocketBanner(
    phase: PocketBuilderService.Phase,
    onOpen: (pocketId: String) -> Unit,
    onAcknowledge: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (phase is PocketBuilderService.Phase.Idle) return
    Card(
        colors = CardDefaults.cardColors(
            containerColor = if (phase is PocketBuilderService.Phase.Failed) MaterialTheme.colorScheme.errorContainer
            else MaterialTheme.colorScheme.secondaryContainer,
        ),
        modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("create-pocket-banner"),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            when (phase) {
                is PocketBuilderService.Phase.Building -> {
                    CircularProgressIndicator(modifier = Modifier.padding(4.dp), strokeWidth = 2.dp)
                    Text("Building a pocket for “${phase.brief}”…", modifier = Modifier.weight(1f))
                }
                is PocketBuilderService.Phase.Done -> {
                    Text(
                        "Created “${phase.name}”: ${phase.songCount} songs, about ${phase.minutes} min.",
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = { onOpen(phase.pocketId); onAcknowledge() }) { Text("Open") }
                    IconButton(onClick = onAcknowledge) { Icon(Icons.Filled.Close, contentDescription = "Dismiss") }
                }
                is PocketBuilderService.Phase.Failed -> {
                    Text(phase.message, modifier = Modifier.weight(1f))
                    IconButton(onClick = onAcknowledge) { Icon(Icons.Filled.Close, contentDescription = "Dismiss") }
                }
                PocketBuilderService.Phase.Idle -> Unit
            }
        }
    }
}

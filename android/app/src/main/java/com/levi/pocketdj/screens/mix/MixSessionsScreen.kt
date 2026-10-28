package com.levi.pocketdj.screens.mix

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.di.AppGraph

/** MIX-15 OWNS this file: replace the body of [MixSessionsRoute] (MixRoutes.kt just delegates here). */
@Composable
fun MixSessionsRoute(onBack: () -> Unit) = SessionsStub(onBack)

/** Placeholder until MIX-15 (Sessions screen + replay): the session names, newest first. */
@Composable
private fun SessionsStub(onBack: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val store = androidx.compose.runtime.remember { AppGraph.get(ctx).mixGraph.mixSessions }
    val sessions by store.sessions.collectAsState()
    val player = androidx.compose.runtime.remember { AppGraph.get(ctx).mixGraph.recordingPlayer }
    val playingFile by player.playing.collectAsState()
    Column(Modifier.fillMaxSize().testTag("mix-sessions-screen")) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Text("Mix sessions", style = androidx.compose.material3.MaterialTheme.typography.titleLarge)
        }
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            items(sessions.sortedByDescending { it.startedAt }, key = { it.id }) { s ->
                Column(Modifier.padding(vertical = 10.dp)) {
                    Text(s.name)
                    s.recordingsList.forEach { r ->
                        val file = java.io.File(java.io.File(com.levi.pocketdj.mix.recording.SessionFolders.root(ctx.filesDir), s.id), r.fileName)
                        androidx.compose.material3.TextButton(
                            onClick = { player.toggle(file) },
                            modifier = Modifier.testTag("mix-recording-row"),
                        ) { Text((if (playingFile == file.path) "Stop " else "Play ") + "recording " + recordingClock(r.durationMs.toLong())) }
                    }
                }
            }
        }
    }
}

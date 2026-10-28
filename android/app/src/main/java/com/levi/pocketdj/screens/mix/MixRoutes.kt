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
import androidx.navigation.compose.composable
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.shell.NavEntry

/**
 * Route glue for the Mix tab. The shell's nav host calls [MixRoute] for the Mix destination (the one
 * shared-file edit MIX-14 makes) and passes its "All sessions" navigation in.
 */
object MixRoutes {
    /** Pushed Sessions list. MIX-15 replaces the body registered below with the real screen. */
    const val SESSIONS = "mix/sessions"

    val entries: List<NavEntry> = listOf(
        NavEntry(SESSIONS) { actions ->
            composable(SESSIONS) { SessionsStub(onBack = { actions.pop() }) }
        },
    )
}

@Composable
fun MixRoute(graph: AppGraph, onOpenSessions: () -> Unit, modifier: Modifier = Modifier) {
    MixScreen(graph, onOpenSessions, modifier)
}

/** Placeholder until MIX-15 (Sessions screen + replay): the session names, newest first. */
@Composable
private fun SessionsStub(onBack: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val store = androidx.compose.runtime.remember { AppGraph.get(ctx).mixGraph.mixSessions }
    val sessions by store.sessions.collectAsState()
    Column(Modifier.fillMaxSize().testTag("mix-sessions-screen")) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            Text("Mix sessions", style = androidx.compose.material3.MaterialTheme.typography.titleLarge)
        }
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            items(sessions.sortedByDescending { it.startedAt }, key = { it.id }) { s ->
                Text(s.name, Modifier.padding(vertical = 10.dp))
            }
        }
    }
}

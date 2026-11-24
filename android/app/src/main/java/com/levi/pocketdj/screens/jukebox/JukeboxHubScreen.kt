package com.levi.pocketdj.screens.jukebox

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.levi.pocketdj.ParityFlags
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.remote.RemoteShowcaseSeed
import com.levi.pocketdj.screens.remote.JoinOutcome
import com.levi.pocketdj.screens.remote.RemoteJoinCode
import com.levi.pocketdj.screens.remote.RemoteScreen
import com.levi.pocketdj.screens.remote.RemoteStarters
import com.levi.pocketdj.shell.JukeboxPanelMode
import com.levi.pocketdj.shell.JukeboxPanelModeStore
import com.levi.pocketdj.shell.RemotePanelRequests
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/**
 * The Jukebox panel (iOS `JukeboxHubView`, 1.0.5): a Jukebox Hero | Remote switch pinned above the two surfaces, so the
 * child's scroll runs under it. The choice persists as `jukeboxPanelMode` ("Jukebox Hero" / "Remote"). A session going
 * active flips the panel to Remote; `pocketdj://remote[/join/<code>]` and the retired "Remote" section token land on it.
 * The switch (and the Remote half) stay hidden until `ParityFlags.REMOTE`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JukeboxHubScreen(modifier: Modifier = Modifier, onOpenJoin: (String) -> Unit = {}) {
    val context = LocalContext.current
    val graph = remember(context) { AppGraph.get(context) }
    val scope = rememberCoroutineScope()
    val controller = graph.remoteGraph.controller
    val storedRaw by graph.settings.flow(JukeboxPanelModeStore.KEY).collectAsState(initial = JukeboxPanelMode.HERO.raw)
    val seedRunning by RemoteShowcaseSeed.running.collectAsState()
    val remoteAvailable = ParityFlags.REMOTE || seedRunning
    val mode = JukeboxPanelModeStore.effective(JukeboxPanelMode.fromRaw(storedRaw), remoteAvailable)

    fun setMode(m: JukeboxPanelMode) { scope.launch { graph.settings.set(JukeboxPanelModeStore.KEY, m.raw) } }

    // A session arriving while the panel shows Hero flips it to Remote.
    LaunchedEffect(controller, remoteAvailable) {
        if (!remoteAvailable) return@LaunchedEffect
        // drop(1): the StateFlow replays its current value; iOS onChange fires on transitions only, never on appear.
        controller.isActive.drop(1).collect { active ->
            val next = JukeboxPanelModeStore.afterSessionChange(JukeboxPanelMode.fromRaw(graph.settings.get(JukeboxPanelModeStore.KEY)), active)
            if (next.raw != graph.settings.get(JukeboxPanelModeStore.KEY)) setMode(next)
        }
    }

    // Deep links and the debug showcase seed.
    val request by RemotePanelRequests.pending.collectAsState()
    LaunchedEffect(request) {
        val req = request ?: return@LaunchedEffect
        // Consume first: a join that is cancelled mid-flight (tab switch) must not replay on the next composition.
        // The key changes to null on consume, so the rest runs NonCancellable to finish the join.
        RemotePanelRequests.consume(req)
        kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
        if (req.showcase && !controller.isActive.value) {
            val songs = graph.catalogRepository.state.value.catalog?.songsById?.values?.toList().orEmpty()
            RemoteShowcaseSeed.start(controller, songs)
        }
        if (ParityFlags.REMOTE || RemoteShowcaseSeed.isRunning) {
            setMode(JukeboxPanelMode.REMOTE)
            val code = req.joinCode?.let(RemoteJoinCode::parse)
            if (code != null && !controller.isActive.value) {
                val outcome = runCatching { RemoteStarters.current.joinWithCode(code) }.getOrNull()
                if (outcome is JoinOutcome.Failed) controller.setStatus("Couldn’t join the session: ${outcome.message}")
            }
        }
        }
    }

    Column(modifier.fillMaxSize().testTag("jukebox-hub")) {
        if (remoteAvailable) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("jukebox-panel-switch")) {
                JukeboxPanelMode.entries.forEachIndexed { i, m ->
                    SegmentedButton(
                        selected = mode == m,
                        onClick = { setMode(m) },
                        shape = SegmentedButtonDefaults.itemShape(i, JukeboxPanelMode.entries.size),
                        modifier = Modifier.testTag("jukebox-panel-${m.name.lowercase()}"),
                    ) { Text(m.label) }
                }
            }
        }
        Box(Modifier.weight(1f)) {
            when (mode) {
                JukeboxPanelMode.HERO -> JukeboxScreen(onOpenJoin = onOpenJoin)
                JukeboxPanelMode.REMOTE -> RemoteScreen()
            }
        }
    }
}

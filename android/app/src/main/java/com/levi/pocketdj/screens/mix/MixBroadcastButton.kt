package com.levi.pocketdj.screens.mix

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CellTower
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.levi.pocketdj.data.jukebox.JukeboxGraph
import com.levi.pocketdj.data.jukebox.JukeboxSettings
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.navigation.PocketDjDestination
import com.levi.pocketdj.shell.NavRequestBus
import com.levi.pocketdj.shell.ShellRoute
import kotlinx.coroutines.launch

/** What a tap on the Mix antenna does (iOS `MixView.broadcastButton`). Pure so it is unit-testable. */
enum class MixBroadcastAction {
    /** A session is live: the tap just opens the Jukebox. */
    OPEN,

    /** No session and the broker is configured: create one with the default name, then open. */
    CREATE_THEN_OPEN,

    /** No session and no broker URL: open the Jukebox, whose create view explains the Settings step. */
    OPEN_UNCONFIGURED,
    ;

    companion object {
        fun decide(sessionLive: Boolean, starting: Boolean, brokerConfigured: Boolean): MixBroadcastAction = when {
            sessionLive || starting -> OPEN
            brokerConfigured -> CREATE_THEN_OPEN
            else -> OPEN_UNCONFIGURED
        }
    }
}

/** Antenna next to Record: one tap to broadcast the Mix to a jukebox. Glows while a session is live. */
@Composable
fun MixBroadcastButton(graph: AppGraph, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val jukebox = JukeboxGraph.get(context)
    val repo = jukebox.repository
    val state by repo.state.collectAsState()
    val scope = rememberCoroutineScope()
    val live = state.session != null
    IconButton(
        onClick = {
            scope.launch {
                repo.ensureBootstrapped()
                val s = repo.state.value
                val settings = graph.settings.current()
                when (
                    MixBroadcastAction.decide(
                        sessionLive = s.session != null,
                        starting = s.starting,
                        brokerConfigured = settings.jukeboxServerUrl.isNotBlank(),
                    )
                ) {
                    MixBroadcastAction.CREATE_THEN_OPEN -> {
                        val name = JukeboxSettings.defaultSessionName(
                            graph.settings.get(com.levi.pocketdj.onboarding.OnboardingPrefs.PROFILE_NAME),
                        )
                        repo.start(name, settings.jukeboxTokensRequiredByDefault, timeless = false)
                    }
                    else -> Unit
                }
                NavRequestBus.post(ShellRoute.Tab(PocketDjDestination.Jukebox))
            }
        },
        modifier = modifier.testTag("mix-broadcast").semantics {
            contentDescription = if (live) "Broadcasting — open jukebox" else "Broadcast this mix to a jukebox"
        },
    ) {
        Icon(
            Icons.Filled.CellTower,
            contentDescription = null,
            tint = if (live) MaterialTheme.colorScheme.primary else DeckColors.fg,
        )
    }
}

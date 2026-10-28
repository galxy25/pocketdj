package com.levi.pocketdj.screens.games

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.levi.pocketdj.di.AppGraph

/**
 * Entry for the Games tab destination. Later game packages pass their openers here (the card
 * taps); until a game exists its callback is null and the card is inert.
 */
@Composable
fun GamesRoute(
    graph: AppGraph,
    modifier: Modifier = Modifier,
    onOpenPuzzle: (() -> Unit)? = null,
    onOpenInThePocket: (() -> Unit)? = null,
) {
    var showPuzzle by rememberSaveable { mutableStateOf(false) }
    var showInThePocket by rememberSaveable { mutableStateOf(false) }
    val friends = graph.gamesGraph.friends
    var sessionId by rememberSaveable { mutableStateOf<String?>(null) }
    var showCreate by rememberSaveable { mutableStateOf(false) }
    var showJoin by rememberSaveable { mutableStateOf(false) }
    val pendingJoin by friends.pendingJoin.collectAsState()
    val pendingOpen by friends.pendingOpenId.collectAsState()
    // A create/join success or a tapped link raises the open signal; take it atomically, reset the
    // Games stack (iOS path = NavigationPath()), then route: known id pushes, unknown leaves the Join sheet.
    LaunchedEffect(pendingOpen) {
        friends.consumePendingOpenId()?.let { id ->
            showPuzzle = false
            showInThePocket = false
            sessionId = routeOpenedSession(id) { friends.entry(it) != null }
        }
    }
    // A round survives leaving the screen (app-scoped engine); back from setup/summary closes it.
    if (showPuzzle) {
        BackHandler {
            val engine = graph.gamesGraph.puzzleEngine
            if (engine.currentPhase == com.levi.pocketdj.data.games.puzzle.PuzzleRoundState.Phase.FINISHED) engine.reset()
            showPuzzle = false
        }
        CollectorsPuzzleScreen(graph, onClose = { showPuzzle = false }, modifier = modifier)
        return
    }
    // The store is app-scoped, so a round keeps tracking after back; the screen saves feedback on leave.
    if (showInThePocket) {
        BackHandler { showInThePocket = false }
        InThePocketScreen(graph, modifier = modifier)
        return
    }
    sessionId?.let { id ->
        BackHandler { sessionId = null }
        MwFSessionScreen(graph, id, onClose = { sessionId = null }, modifier = modifier)
        return
    }
    if (showCreate) MwFCreateSheet(graph, onDismiss = { showCreate = false })
    if (showJoin) MwFJoinSheet(graph, link = null, onDismiss = { showJoin = false })
    pendingJoin?.let { link -> MwFJoinSheet(graph, link = link, onDismiss = { friends.clearPendingJoin() }) }
    GamesScreen(
        friends = friends,
        onNewSession = { showCreate = true },
        onJoinSession = { showJoin = true },
        onOpenSession = { sessionId = it },
        store = graph.gamesGraph.scoreboard,
        modifier = modifier,
        deleteScope = graph.appScope,
        onOpenPuzzle = onOpenPuzzle ?: { showPuzzle = true },
        onOpenInThePocket = onOpenInThePocket ?: { showInThePocket = true },
    )
}

/** Pure routing rule for an opened-session signal: known id -> push it; unknown -> null (Join sheet shows). */
internal fun routeOpenedSession(id: String, isKnown: (String) -> Boolean): String? = if (isKnown(id)) id else null

package com.levi.pocketdj.screens.games

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
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
    var showInThePocket by rememberSaveable { mutableStateOf(false) }
    // The store is app-scoped, so a round keeps tracking after back; the screen saves feedback on leave.
    if (showInThePocket) {
        BackHandler { showInThePocket = false }
        InThePocketScreen(graph, modifier = modifier)
        return
    }
    GamesScreen(
        store = graph.gamesGraph.scoreboard,
        modifier = modifier,
        deleteScope = graph.appScope,
        onOpenPuzzle = onOpenPuzzle ?: { showPuzzle = true },
        onOpenInThePocket = onOpenInThePocket ?: { showInThePocket = true },
    )
}

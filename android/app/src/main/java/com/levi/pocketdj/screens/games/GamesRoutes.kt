package com.levi.pocketdj.screens.games

import androidx.compose.runtime.Composable
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
    GamesScreen(
        store = graph.gamesGraph.scoreboard,
        modifier = modifier,
        onOpenPuzzle = onOpenPuzzle,
        onOpenInThePocket = onOpenInThePocket,
    )
}

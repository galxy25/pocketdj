package com.levi.pocketdj.screens.history.wheel

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import com.levi.pocketdj.data.pockets.wheel.PocketMomentKey
import com.levi.pocketdj.data.pockets.wheel.PocketRunStore
import com.levi.pocketdj.data.pockets.wheel.PocketWheelBestMatchSummary
import com.levi.pocketdj.di.PocketsGraph
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * What the wheel's buttons do (iOS `PocketWheelActions`) - supplied by the app graph. A null closure hides/disables
 * the matching control, so the wheel renders standalone (previews, tests).
 */
data class PocketWheelActions(
    /** The centre play button's caption + colour, when a best match exists. */
    val bestMatch: PocketWheelBestMatchSummary? = null,
    val playBest: (() -> Unit)? = null,
    /** Long-press alternatives on the centre play button ("Not this?"). */
    val alternatives: List<PocketWheelBestMatchSummary> = emptyList(),
    val playAlternative: ((PocketWheelBestMatchSummary) -> Unit)? = null,
    /** Play this pocket on a cell's card. */
    val playMoment: ((PocketMomentKey) -> Unit)? = null,
    /** A run is playing: played-through / total and its moment. */
    val runProgress: RunProgress? = null,
    /** Pause the playing run (the centre button shows pause while a run is playing). */
    val pauseRun: (() -> Unit)? = null,
    /** Clear the playing pocket from playback (ends the run + stops its queue) so another can start. */
    val clearRun: (() -> Unit)? = null,
    /** Past runs of a moment (the card's "learning" strip). */
    val runHistory: ((PocketMomentKey) -> List<PocketRunStore.PocketRunHistoryRow>)? = null,
) {
    data class RunProgress(val done: Int, val total: Int, val key: PocketMomentKey?)

    companion object {
        val NONE = PocketWheelActions()

        /** The run's progress for the centre ring; null when no run (a finished, undismissed run is not "playing"). */
        fun progressOf(run: PocketRunStore.RunState?): RunProgress? =
            run?.takeIf { !it.finished }?.let { RunProgress(it.playedThrough, PocketRunStore.TARGET, it.momentKey?.let(PocketMomentKey::fromToken)) }
    }
}

/**
 * The live actions for the app graph: best match + alternatives from the controller, run progress / clear from the
 * run store. Starting a pocket runs NonCancellable so leaving the screen never cancels a build half-way.
 */
@Composable
fun rememberPocketWheelActions(graph: PocketsGraph, onPause: (() -> Unit)? = null): PocketWheelActions {
    val controller = graph.wheelController
    val store = graph.runStore
    val scope = rememberCoroutineScope()
    val result by controller.result.collectAsState()
    val active by store.active.collectAsState()
    return remember(result, active, onPause) {
        PocketWheelActions(
            bestMatch = controller.bestSummary,
            playBest = { scope.launch { runCatching { withContext(NonCancellable) { controller.playBest() } } } },
            alternatives = controller.alternativeSummaries,
            playAlternative = { a -> scope.launch { runCatching { withContext(NonCancellable) { controller.playAlternative(a) } } } },
            playMoment = { k -> scope.launch { runCatching { withContext(NonCancellable) { controller.playMoment(k) } } } },
            runProgress = PocketWheelActions.progressOf(active),
            pauseRun = onPause,
            clearRun = { store.stop() },
            runHistory = { k -> store.runHistory(k) },
        )
    }
}

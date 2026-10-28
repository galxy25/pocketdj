package com.levi.pocketdj.data.stats

import com.levi.pocketdj.playback.PlayAdvancedAway
import com.levi.pocketdj.playback.PlayEventBus
import com.levi.pocketdj.playback.PlayStarted
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/**
 * Feeds [PlayStatsStore] from the core play-event seam: a track start is a play (tagged
 * `appleCounted` when the Apple Music backend was sounding), an advance-away under 50% played
 * is a skip. The 30 s re-count window in the store absorbs double hooks.
 */
class PlayStatsRecorder(
    private val store: PlayStatsStore,
    private val appleStreaming: () -> Boolean = { false },
) {
    fun onStarted(e: PlayStarted) = store.notePlayed(e.songId, e.atMs, appleCounted = appleStreaming())

    fun onAdvancedAway(e: PlayAdvancedAway) {
        if (isSkip(e.positionMs, e.durationMs)) store.noteSkipped(e.songId)
    }

    fun start(
        scope: CoroutineScope,
        started: Flow<PlayStarted> = PlayEventBus.events,
        away: Flow<PlayAdvancedAway> = PlayEventBus.advancedAway,
    ): Job = scope.launch {
        launch { started.collect { onStarted(it) } }
        launch { away.collect { onAdvancedAway(it) } }
    }

    companion object {
        /** SkipTracker verdict: known position AND duration, and under half played. */
        fun isSkip(positionMs: Long?, durationMs: Long?): Boolean =
            positionMs != null && durationMs != null && durationMs > 0 && positionMs * 2 < durationMs
    }
}

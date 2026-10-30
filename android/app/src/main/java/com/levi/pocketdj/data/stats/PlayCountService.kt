package com.levi.pocketdj.data.stats

import com.levi.pocketdj.data.recs.ZoneEngine

/**
 * Thin facade over [PlayStatsStore] (iOS `PlayCountService`): the For You screens read cumulative
 * per-song play/skip counts from here instead of rebuilding them from the (windowed) history log.
 * Snapshots are plain maps, so callers take them OFF Main and hand the pure engine value types.
 */
class PlayCountService(private val store: PlayStatsStore) {
    class Snapshot(
        val plays: Map<String, Int>,
        val skips: Map<String, Int>,
        val lastPlayedMs: Map<String, Double>,
    ) {
        /** GLOBAL dampened skip pressure (a skip is evidence about the song, not one tile). */
        val skipPenalty: Map<String, Double> get() = skipPenaltiesOf(plays, skips)
    }

    fun snapshot(): Snapshot = Snapshot(store.playCountsSnapshot(), store.skipCountsSnapshot(), store.lastPlayedSnapshot())

    companion object {
        fun skipPenaltiesOf(plays: Map<String, Int>, skips: Map<String, Int>): Map<String, Double> =
            ZoneEngine.Feedback.skipPenalties(plays, skips)

        /** Inject the skip penalty into a feedback projection (iOS `withSkips`). */
        fun withSkips(fb: ZoneEngine.Feedback, penalty: Map<String, Double>): ZoneEngine.Feedback =
            fb.copy(skipPenalty = penalty)
    }
}

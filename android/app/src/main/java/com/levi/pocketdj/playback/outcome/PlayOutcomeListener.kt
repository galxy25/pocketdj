package com.levi.pocketdj.playback.outcome

import com.levi.pocketdj.shell.PlayOutcomeListener

/**
 * Fan-out of "how did that play end" to every registered [PlayOutcomeListener]
 * (FeatureModule.playOutcomeListeners: skip tracker, history, pocket game). The sequencer is the
 * producer on natural end (completed, fraction 1.0) and on a user advance-away when the listened
 * fraction is known. A throwing listener never reaches the sequencer or starves the others.
 */
class PlayOutcomeRegistry(private val listeners: () -> List<PlayOutcomeListener>) {
    fun emit(songId: String, wasSkipped: Boolean, listenedFraction: Double) {
        val f = listenedFraction.coerceIn(0.0, 1.0)
        for (l in listeners()) {
            runCatching { l.onOutcome(songId, wasSkipped, f) }
        }
    }
}

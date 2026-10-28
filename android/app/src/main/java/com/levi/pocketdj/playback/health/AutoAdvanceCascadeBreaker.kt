package com.levi.pocketdj.playback.health

/**
 * The AUTO-ADVANCE CASCADE BREAKER (iOS `AutoAdvanceCascadeBreaker`). When the sequencer auto-advances
 * (dead source, a stream that never started, a failed item) several times IN A ROW and none of those tracks
 * produced real audio, something outside the queue is wrong - a dead zone, a server that cannot deliver -
 * and advancing again just burns through the queue. Stop instead: pause on the current row, keep the queue
 * position, tell the listener.
 *
 * Any user transport (skip, previous, jump, play-now, play) or a track that DID play resets it.
 */
class AutoAdvanceCascadeBreaker {
    var quickAdvances: Int = 0
        private set

    /**
     * An auto-advance is about to happen off a track that played [audibleSeconds]. Returns true when the
     * breaker TRIPS: the caller must not advance.
     */
    fun shouldHalt(afterAudibleSeconds: Double): Boolean {
        if (afterAudibleSeconds >= MIN_AUDIBLE_SECONDS) {
            quickAdvances = 0
            return false
        }
        quickAdvances += 1
        if (quickAdvances >= LIMIT) {
            quickAdvances = 0
            return true
        }
        return false
    }

    /** The listener acted (or a track played properly) - the run is no longer a cascade. */
    fun reset() {
        quickAdvances = 0
    }

    companion object {
        /** Consecutive quick auto-advances that trip the breaker (the Nth is not performed). */
        const val LIMIT = 3

        /** Audible seconds below which an auto-advanced track counts as "quick" (never heard). */
        const val MIN_AUDIBLE_SECONDS = 5.0

        const val GENERIC_NOTICE = "Playback paused — the last few tracks didn’t play"
        const val APPLE_MUSIC_NOTICE = "Playback paused — Apple Music was interrupted"
    }
}

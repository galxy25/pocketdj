package com.levi.pocketdj.playback.sequencer

/**
 * THE edition decision for a queued row (iOS `editionDecider`), applied once at `play()` over the
 * whole queue. Default [Unchanged] is today's behaviour exactly. A real decider returns the item
 * with `variant` / `resolveId` stamped (never for `editionLocked` rows).
 */
fun interface EditionDecider {
    /** [cleanOnly]: the run's origin collection carries the clean-only flag. */
    fun decide(item: QueueItem, cleanOnly: Boolean): QueueItem

    /** O(1) probe: could [decide] substitute anything right now? Lets play() skip the full map. */
    fun isActive(): Boolean = true

    /** False while the data [decide] needs (the catalog) has not loaded: a re-decide would be wrong, not just late. */
    fun isReady(): Boolean = true

    companion object {
        val Unchanged = object : EditionDecider {
            override fun decide(item: QueueItem, cleanOnly: Boolean): QueueItem = item
            override fun isActive(): Boolean = false
        }
    }
}

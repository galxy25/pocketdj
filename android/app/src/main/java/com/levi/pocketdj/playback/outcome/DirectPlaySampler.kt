package com.levi.pocketdj.playback.outcome

/**
 * Q89c: feeds [SkipTracker] for audio the sequencer does NOT own (a Browse single / album queue played straight
 * into ExoPlayer). The sequencer feeds the tracker for its own rows; without this the direct plays were armed by
 * the History choke point but never sampled or classified, so their `listenedFraction` / outcome stayed unknown.
 *
 * Driven by a 1 Hz [tick] of "what ExoPlayer holds right now":
 *  - same song: [SkipTracker.samplePosition];
 *  - a different song replaced it: natural end (it was at its end / ENDED was seen) -> [SkipTracker.noteNaturalEnd];
 *    otherwise the listener advanced away -> [SkipTracker.noteAdvanceAway] (<50 % = skipped);
 *  - nothing held (stop / the sequencer or Mix took over): [SkipTracker.checkpoint] only - never a skip.
 * Pure over its tracker: no Android types, JVM-testable.
 */
class DirectPlaySampler(private val tracker: SkipTracker) {
    private class Track(val songId: String) {
        var positionMs = 0L
        var durationMs: Long? = null
        var ended = false
    }

    private var active: Track? = null
    private val lock = Any()

    /** Song id currently being sampled (test/diagnostic). */
    val activeSongId: String? get() = synchronized(lock) { active?.songId }

    /**
     * One sample. [mediaId] null = the direct engine holds nothing for us (stopped, or another owner fronts the
     * session). [ended] = the engine reports STATE_ENDED for [mediaId].
     */
    fun tick(mediaId: String?, positionMs: Long, durationMs: Long?, ended: Boolean = false) {
        // Tracker calls take the tracker's own lock and may run store side effects: keep them outside ours.
        var followUp: (() -> Unit)? = null
        synchronized(lock) {
            val cur = active
            if (mediaId == null) {
                if (cur != null) {
                    active = null
                    followUp = { tracker.checkpoint() }
                }
                return@synchronized
            }
            if (cur == null || cur.songId != mediaId) {
                followUp = if (cur != null) departed(cur) else null
                active = Track(mediaId).also { it.positionMs = positionMs; it.durationMs = durationMs?.takeIf { d -> d > 0 } }
                return@synchronized
            }
            cur.positionMs = positionMs
            if (durationMs != null && durationMs > 0) cur.durationMs = durationMs
            val id = cur.songId
            val pos = cur.positionMs
            val dur = cur.durationMs
            val firstEnd = ended && !cur.ended
            if (ended) cur.ended = true
            followUp = {
                tracker.samplePosition(id, pos, dur)
                if (firstEnd) tracker.noteNaturalEnd(id)
            }
        }
        followUp?.invoke()
    }

    /** A new direct play is about to replace whatever was held (called BEFORE the new media is set). */
    fun noteReplacing() {
        val f = synchronized(lock) {
            val cur = active ?: return
            active = null
            departed(cur)
        }
        f?.invoke()
    }

    /** Stop / teardown: land the final fraction without classifying. */
    fun noteStopped() {
        val had = synchronized(lock) { (active != null).also { active = null } }
        if (had) tracker.checkpoint()
    }

    /** What to tell the tracker about [t] leaving the engine for something else. */
    private fun departed(t: Track): () -> Unit {
        val dur = t.durationMs
        val nearEnd = dur != null && t.positionMs >= dur - NEAR_END_MS
        return if (t.ended || nearEnd) {
            { tracker.samplePosition(t.songId, t.positionMs, dur); tracker.noteNaturalEnd(t.songId) }
        } else {
            { tracker.noteAdvanceAway(t.songId, t.positionMs, dur) }
        }
    }

    companion object {
        /** A 1 Hz sample can miss the last second of a gapless auto-transition: within this of the end = it ended. */
        const val NEAR_END_MS = 2_000L
    }
}

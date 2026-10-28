package com.levi.pocketdj.playback.outcome

import com.levi.pocketdj.data.edition.SongVariant

/**
 * Classifies each playback as SKIPPED or not - the one place the "<50 % played" rule lives (port of
 * iOS `SkipTracker.swift`; decision D9). The sequencer only reports WHAT HAPPENED; the verdict is here.
 *
 * THE RULE: a playback is a SKIP when the listener ADVANCES AWAY (skipNext, jump to another row,
 * play-now of a different song, a fresh play over a running set, AM systemSkip) with LESS THAN HALF
 * played (position / duration < 0.5, STRICT; exactly 50 % is not a skip). Natural end, repeat, dead
 * source advance, previous, pause and stop never call [noteAdvanceAway]. Unknown duration => not a skip.
 *
 * ONE-DEEP [previous] STASH: a row play over a running set re-arms the tracker on the NEW event
 * before the OLD song's advance-away is delivered; arming stashes the replaced track so that late
 * verdict classifies it. The stash dies at the next arm - a verdict can only be one track late.
 *
 * HIGH-WATER MARK: fed by ~1 Hz [samplePosition] for the CURRENT song only; beats a clobbered live read
 * (AM systemSkip zeroes the clock before the end callback). Bias after a seek-back is NOT-skip.
 *
 * Thread-safe (bus collectors and the Main-thread sequencer both call in).
 */
class SkipTracker(
    /** Marks the history event skipped (`PlayHistoryStore.markSkipped`). */
    private val markSkipped: (eventId: String) -> Unit,
    /** Max-merging played-fraction sink (`PlayHistoryStore.noteListened`). */
    private val noteListened: (eventId: String, fraction: Double) -> Unit,
    /** Cumulative per-song skip count sink (play-count service); optional. */
    private val noteSkip: ((songId: String) -> Unit)? = null,
    /** Fan-out of every advance-away verdict (PlayOutcomeRegistry.emit). */
    private val onVerdict: ((songId: String, wasSkipped: Boolean, fraction: Double) -> Unit)? = null,
) {
    private class Previous(
        val eventId: String,
        val songId: String,
        var classified: Boolean,
        val maxPositionMs: Long,
        val lastKnownDurationMs: Long?,
    )

    private val lock = Any()
    private var currentEventIdValue: String? = null
    private var currentSongIdValue: String? = null
    private var classified = false
    private var maxPositionMs = 0L
    private var lastKnownDurationMs: Long? = null
    private var previous: Previous? = null

    /** History event id of the CURRENTLY-PLAYING track - the History view's live-row key. */
    val currentEventId: String? get() = synchronized(lock) { currentEventIdValue }
    val currentSongId: String? get() = synchronized(lock) { currentSongIdValue }

    /** A new track started (the history event was just appended). */
    fun noteTrackStarted(eventId: String, songId: String) = synchronized(lock) {
        arm(eventId, songId, classified = false)
    }

    /**
     * Live playback moved onto an EXISTING event (the 30 s window collapsed a replay). Re-arms like a
     * start with a fresh high-water mark, except an already-skipped event resumes CLASSIFIED so a second
     * skip of the same collapsed listen can't double the count.
     */
    fun noteTrackResumed(eventId: String, songId: String, wasSkipped: Boolean) = synchronized(lock) {
        arm(eventId, songId, classified = wasSkipped)
    }

    /**
     * The CURRENT track restarted from 0:00 with no new history record (repeat-one, a repeat pass, a
     * duplicate consecutive row). Reports pass 1's fraction, then re-zeroes the mark. Other ids are stale
     * signals racing a track change - dropped.
     */
    fun noteTrackRestarted(songId: String) = synchronized(lock) {
        val current = currentSongIdValue ?: return@synchronized
        if (SongVariant.baseId(songId) != SongVariant.baseId(current)) return@synchronized
        reportCurrentFraction()
        maxPositionMs = 0
    }

    /** The current track played through (natural end): its final fraction is 1.0. Never a skip. */
    fun noteNaturalEnd(songId: String) = synchronized(lock) {
        val current = currentSongIdValue ?: return@synchronized
        val eid = currentEventIdValue ?: return@synchronized
        if (SongVariant.baseId(songId) != SongVariant.baseId(current)) return@synchronized
        report(eid, 1.0)
    }

    /** Report the current fraction WITHOUT classifying (background / stop exits that never advance away). */
    fun checkpoint() = synchronized(lock) { reportCurrentFraction() }

    /** ~1 Hz position sample; samples for any OTHER song are dropped. */
    fun samplePosition(songId: String, positionMs: Long, durationMs: Long?) = synchronized(lock) {
        val current = currentSongIdValue ?: return@synchronized
        if (SongVariant.baseId(songId) != SongVariant.baseId(current)) return@synchronized
        maxPositionMs = maxOf(maxPositionMs, positionMs)
        if (durationMs != null && durationMs > 0) lastKnownDurationMs = durationMs
    }

    /**
     * The listener advanced away from [songId]. [positionMs] null = the clock is gone, use the samples.
     * Current track first; a non-matching report falls to the one-deep stash; anything else is dropped.
     */
    fun noteAdvanceAway(songId: String, positionMs: Long?, durationMs: Long?) {
        val verdict = synchronized(lock) {
            val base = SongVariant.baseId(songId)
            val cur = currentSongIdValue
            val curEid = currentEventIdValue
            val prev = previous
            if (cur != null && SongVariant.baseId(cur) == base) {
                if (curEid == null || classified) return
                classified = true
                classify(curEid, cur, maxOf(positionMs ?: 0L, maxPositionMs), durationMs ?: lastKnownDurationMs)
            } else if (prev != null && SongVariant.baseId(prev.songId) == base && !prev.classified) {
                prev.classified = true
                classify(
                    prev.eventId, prev.songId,
                    maxOf(positionMs ?: 0L, prev.maxPositionMs), durationMs ?: prev.lastKnownDurationMs,
                )
            } else {
                null
            }
        }
        if (verdict != null) {
            runCatching { onVerdict?.invoke(verdict.songId, verdict.skipped, verdict.fraction) }
        }
    }

    private class Verdict(val songId: String, val skipped: Boolean, val fraction: Double)

    private fun reportCurrentFraction() {
        val eid = currentEventIdValue ?: return
        val dur = lastKnownDurationMs ?: return
        if (dur <= 0 || maxPositionMs <= 0) return
        report(eid, maxPositionMs.toDouble() / dur)
    }

    private fun report(eventId: String, fraction: Double) {
        noteListened(eventId, fraction.coerceIn(0.0, 1.0))
    }

    private fun arm(eventId: String, songId: String, classified: Boolean) {
        // The outgoing track's listen is final once something replaces it.
        reportCurrentFraction()
        val eid = currentEventIdValue
        val sid = currentSongIdValue
        if (eid != null && sid != null && eid != eventId) {
            previous = Previous(eid, sid, this.classified, maxPositionMs, lastKnownDurationMs)
        }
        currentEventIdValue = eventId
        currentSongIdValue = songId
        this.classified = classified
        maxPositionMs = 0
        lastKnownDurationMs = null
    }

    private fun classify(eventId: String, songId: String, positionMs: Long, durationMs: Long?): Verdict? {
        if (durationMs == null || durationMs <= 0) return null
        val fraction = positionMs.toDouble() / durationMs
        report(eventId, fraction)
        val skipped = fraction < 0.5
        if (skipped) {
            markSkipped(eventId)
            noteSkip?.invoke(songId)
        }
        return Verdict(songId, skipped, fraction.coerceIn(0.0, 1.0))
    }
}

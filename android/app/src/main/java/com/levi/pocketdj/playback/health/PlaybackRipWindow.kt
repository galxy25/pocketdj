package com.levi.pocketdj.playback.health

/**
 * The RIP-AHEAD WINDOW of a playback session (iOS `PlaybackRipWindow`; Levi 2026-10-13: "we should only
 * stream ahead say the next 10 songs"). A PLAYBACK-originated rip may only be requested for the playing row
 * and the next [AHEAD] rows. Every such id this session actually got QUEUED is tracked here; when the
 * playhead moves, the queue is edited, or the session stops, the tracked ids that fell out of the window are
 * cancelled on the server (`POST /rip-cancel`) - except the playing row, a row the listener HEARD
 * (>= [HEARD_SECONDS] audible: [keep]), and anything a user surface asked for (the caller filters those).
 *
 * Plain bookkeeping so it is unit-testable without a server or a player.
 */
class PlaybackRipWindow {
    private val _requested = linkedSetOf<String>()

    /** Rip ids (base or variant ids, exactly as POSTed) this session queued and may still cancel. */
    val requested: Set<String> get() = _requested

    /** This session got [id] queued on the server. */
    fun record(id: String) {
        _requested.add(id)
    }

    /** The listener heard [ids] (one row's base + resolve id): never cancel their rips. */
    fun keep(ids: Set<String>) {
        _requested.removeAll(ids)
    }

    /** Drop and RETURN (sorted) every tracked id outside [window]. The caller cancels what comes back. */
    fun evict(window: Set<String>): List<String> {
        val out = _requested.filter { it !in window }.sorted()
        _requested.removeAll(out.toSet())
        return out
    }

    /** The session ends: drop and RETURN (sorted) everything tracked except [playing]. */
    fun endSession(playing: Set<String>): List<String> {
        val out = _requested.filter { it !in playing }.sorted()
        _requested.clear()
        return out
    }

    /** A row of the queue as the window sees it. */
    data class Row(val id: String, val resolveId: String = id)

    companion object {
        /** How many rows AFTER the playing one may have a playback rip requested. */
        const val AHEAD = 10

        /** Audible seconds after which a row counts as heard (its rip is never cancelled). */
        const val HEARD_SECONDS = 30.0

        /**
         * The ids inside the window for a queue at [index]: the playing row + the next [AHEAD]. Each row
         * contributes BOTH its base id and its resolve id.
         */
        fun windowIds(rows: List<Row>, index: Int): Set<String> {
            if (index < 0 || index >= rows.size) return emptySet()
            val out = linkedSetOf<String>()
            for (r in rows.subList(index, minOf(rows.size, index + 1 + AHEAD))) {
                out.add(r.id)
                out.add(r.resolveId)
            }
            return out
        }

        /** Whether a playback rip for [id] may be requested at all right now. */
        fun allows(id: String, rows: List<Row>, index: Int): Boolean = id in windowIds(rows, index)
    }
}

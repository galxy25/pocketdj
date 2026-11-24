package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.durable.SessionSnapshot
import com.levi.pocketdj.playback.durable.SessionSourceRef
import com.levi.pocketdj.playback.sequencer.RepeatMode

/**
 * The HOST's authoritative session state (iOS `RemoteQueueModel`), a pure value with no player and no
 * transport. Every command from every participant is applied HERE; speakers reconcile against the result.
 * Rows are addressed by rid. [revision] bumps only when [apply] really changed something.
 */
data class RemoteQueueModel(
    var rows: List<RemoteRow> = emptyList(),
    var index: Int = 0,
    var isPlaying: Boolean = false,
    /** Song-relative position at [anchor] (a shared-clock ms instant). */
    var positionMs: Long = 0,
    var anchor: Double = 0.0,
    var repeatMode: RepeatMode = RepeatMode.OFF,
    var shuffleEnabled: Boolean = false,
    /** The pre-shuffle upcoming order (rids), restored when shuffle turns off. */
    var canonicalUpcoming: List<String>? = null,
    var revision: Int = 0,
    /** Origin name shown on the remote surface. */
    var sourceName: String? = null,
) {
    val currentRow: RemoteRow? get() = rows.getOrNull(index)
    val upcoming: List<RemoteRow> get() = if (index + 1 < rows.size) rows.subList(index + 1, rows.size) else emptyList()

    fun position(now: Double): Long =
        if (!isPlaying) positionMs else maxOf(0L, positionMs + roundAway(now - anchor))

    /** Re-anchor the running position at [now] (before any change to play state / track). */
    private fun freeze(now: Double) {
        positionMs = position(now)
        anchor = now
    }

    private fun startTrack(i: Int, now: Double) {
        index = i
        positionMs = 0
        anchor = now
    }

    /**
     * Apply one command. Returns true (and bumps [revision]) when anything changed. [shuffler] is injectable so
     * tests pin the permutation.
     */
    fun apply(
        command: RemoteCommand,
        now: Double,
        shuffler: (List<RemoteRow>) -> List<RemoteRow> = { it.shuffled() },
    ): Boolean {
        val before = copy()
        when (command) {
            is RemoteCommand.Play -> {
                if (command.rows.isEmpty()) return false
                rows = command.rows
                canonicalUpcoming = null
                shuffleEnabled = false
                startTrack(maxOf(0, minOf(command.startIndex, command.rows.size - 1)), now)
                isPlaying = true
            }
            is RemoteCommand.PlayNow -> {
                if (command.rows.isEmpty()) return false
                if (rows.isEmpty()) {
                    rows = command.rows
                    startTrack(0, now)
                } else {
                    rows = rows.take(index + 1) + command.rows + rows.drop(index + 1)
                    startTrack(index + 1, now)
                }
                isPlaying = true
            }
            RemoteCommand.PlayPause -> {
                if (currentRow == null) return false
                freeze(now)
                isPlaying = !isPlaying
            }
            is RemoteCommand.SetPlaying -> {
                if (currentRow == null || command.on == isPlaying) return false
                freeze(now)
                isPlaying = command.on
            }
            is RemoteCommand.Seek -> {
                if (currentRow == null) return false
                positionMs = maxOf(0L, command.ms)
                anchor = now
            }
            RemoteCommand.SkipNext -> advance(now)
            is RemoteCommand.Advanced -> {
                if (currentRow?.rid != command.fromRid) return false
                if (repeatMode == RepeatMode.ONE) {
                    positionMs = 0
                    anchor = now
                } else {
                    advance(now)
                }
            }
            RemoteCommand.SkipPrevious -> {
                if (currentRow == null) return false
                if (position(now) > 3_000 || (index == 0 && repeatMode != RepeatMode.ALL)) {
                    // Previous restarts the track first (the lock-screen rule).
                    positionMs = 0
                    anchor = now
                } else {
                    startTrack(if (index == 0) rows.size - 1 else index - 1, now)
                }
            }
            is RemoteCommand.JumpTo -> {
                val i = rows.indexOfFirst { it.rid == command.rid }
                if (i < 0 || i == index) return false
                startTrack(i, now)
                isPlaying = true
            }
            is RemoteCommand.EnqueueNext -> {
                if (command.rows.isEmpty()) return false
                if (rows.isEmpty()) return apply(RemoteCommand.Play(command.rows, 0), now, shuffler)
                rows = rows.take(index + 1) + command.rows + rows.drop(index + 1)
                canonicalUpcoming = canonicalUpcoming?.let { command.rows.map { r -> r.rid } + it }
            }
            is RemoteCommand.Append -> {
                if (command.rows.isEmpty()) return false
                if (rows.isEmpty()) return apply(RemoteCommand.Play(command.rows, 0), now, shuffler)
                rows = rows + command.rows
                canonicalUpcoming = canonicalUpcoming?.let { it + command.rows.map { r -> r.rid } }
            }
            is RemoteCommand.Remove -> {
                // Only an UPCOMING row: the current row is skipped, never removed.
                val i = rows.indexOfFirst { it.rid == command.rid }
                if (i < 0 || i <= index) return false
                rows = rows.toMutableList().also { it.removeAt(i) }
                canonicalUpcoming = canonicalUpcoming?.filter { it != command.rid }
            }
            is RemoteCommand.Move -> {
                val i = rows.indexOfFirst { it.rid == command.rid }
                if (i < 0 || i <= index) return false
                val list = rows.toMutableList()
                val row = list.removeAt(i)
                val dest = index + 1 + maxOf(0, minOf(command.toUpcomingOffset, list.size - index - 1))
                list.add(dest, row)
                rows = list
            }
            is RemoteCommand.Reorder -> {
                val upcomingRids = upcoming.map { it.rid }.toSet()
                val wanted = command.rids.filter { it in upcomingRids }
                val wantedSet = wanted.toSet()
                val slots = rows.indices.filter { it > index && rows[it].rid in wantedSet }
                if (slots.size != wanted.size) return false
                val byRid = HashMap<String, RemoteRow>()
                for (r in rows) byRid.putIfAbsent(r.rid, r)
                val list = rows.toMutableList()
                for ((slot, rid) in slots.zip(wanted)) byRid[rid]?.let { list[slot] = it }
                rows = list
            }
            is RemoteCommand.SetRepeat -> repeatMode = command.mode
            is RemoteCommand.SetShuffle -> {
                if (command.on == shuffleEnabled) return false
                shuffleEnabled = command.on
                val head = if (rows.isEmpty()) emptyList() else rows.take(index + 1)
                val tail = upcoming.toList()
                if (command.on) {
                    canonicalUpcoming = tail.map { it.rid }
                    rows = head + shuffler(tail)
                } else {
                    val order = canonicalUpcoming
                    if (order != null) {
                        val byRid = HashMap<String, RemoteRow>()
                        for (r in tail) byRid.putIfAbsent(r.rid, r)
                        val restored = order.mapNotNull { byRid[it] }.toMutableList()
                        val known = order.toSet()
                        restored += tail.filter { it.rid !in known } // added while shuffled
                        rows = head + restored
                        canonicalUpcoming = null
                    }
                }
            }
        }
        if (this == before) return false
        revision = before.revision + 1
        return true
    }

    /**
     * Next row, wrapping under repeat-all; past the last row the set stops on its last track (paused at 0),
     * the sequencer's end-of-set behaviour.
     */
    private fun advance(now: Double) {
        if (currentRow == null) return
        if (index + 1 < rows.size) {
            startTrack(index + 1, now)
        } else if (repeatMode == RepeatMode.ALL && rows.isNotEmpty()) {
            startTrack(0, now)
        } else {
            positionMs = 0
            anchor = now
            isPlaying = false
        }
    }

    /**
     * The windowed wire state for [revision]. [behind]/[ahead] shrink the window when the encoded state would
     * exceed the transport's size budget.
     */
    fun state(
        hostId: String,
        mode: RemoteSessionMode,
        sessionId: String,
        now: Double,
        behind: Int = WINDOW_BEHIND,
        ahead: Int = WINDOW_AHEAD,
        sessionActive: Boolean? = null,
    ): RemotePlaybackState {
        val lo = maxOf(0, index - behind)
        val hi = minOf(rows.size, index + 1 + ahead)
        val window = if (lo < hi) rows.subList(lo, hi).toList() else emptyList()
        val snap = SessionSnapshot(
            sessionId = sessionId,
            source = SessionSourceRef(kind = "remote", id = null, name = sourceName),
            queue = window.map { it.row },
            index = index - lo,
            positionMs = position(now),
            isPlaying = isPlaying,
            repeatMode = repeatMode.token,
            shuffleEnabled = shuffleEnabled,
            updatedAt = now,
        )
        return RemotePlaybackState(
            revision = revision, hostId = hostId, mode = mode, snapshot = snap,
            rowIds = window.map { it.rid }, windowStart = lo, totalCount = rows.size,
            anchorSharedTime = now, sessionActive = sessionActive,
        )
    }

    companion object {
        /** Rows before / after the current one carried in a state broadcast. */
        const val WINDOW_BEHIND = 20
        const val WINDOW_AHEAD = 200

        /** The smallest ahead-window the size-budget trimmer may shrink to. */
        const val MIN_WINDOW_AHEAD = 10

        /**
         * Adopt a received state as the starting model (a hand-over: the new host only knows the window).
         * [now] is on the NEW host's clock; [positionNow] the position estimated for it.
         */
        fun adopting(s: RemotePlaybackState, positionNow: Long, now: Double): RemoteQueueModel {
            val rows = s.rows
            return RemoteQueueModel(
                rows = rows,
                index = maxOf(0, minOf(s.snapshot.index, maxOf(0, rows.size - 1))),
                isPlaying = s.isPlaying,
                positionMs = positionNow,
                anchor = now,
                repeatMode = s.repeatMode,
                shuffleEnabled = s.shuffleEnabled,
                revision = s.revision,
                sourceName = s.snapshot.source.name,
            )
        }
    }
}

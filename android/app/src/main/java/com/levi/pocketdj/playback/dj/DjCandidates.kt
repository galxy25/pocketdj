package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.REPLACE_NEXT_MIN_RUNWAY_SECONDS
import java.util.UUID

/**
 * Pure helpers for the planner driver (iOS `SetlistPlayer.djCandidate` / `djRowFixed`): turning queue rows into
 * [DjSetPlanner.Candidate]s and deciding which rows the selector must leave where they are.
 */
object DjCandidates {
    /** How many upcoming rows one plan re-orders (the rest of a huge queue keeps its order). */
    const val PLAN_WINDOW = 40

    /**
     * Rows linked into an album run, as iOS djAlbumLinkedRows: pairs (i, i+1) are checked while i+1 <= [hi] (so the pair
     * straddling the window edge counts), and only positions inside the window (< [hi]) are returned.
     */
    fun albumLinked(start: Int, hi: Int, size: Int, runs: (Int) -> Boolean): Set<Int> {
        val out = HashSet<Int>()
        var i = start
        while (i + 1 < minOf(size, hi + 1)) {
            if (runs(i)) { if (i < hi) out.add(i); if (i + 1 < hi) out.add(i + 1) }
            i++
        }
        return out
    }

    /** AGING: a row pushed later this many times holds its place from then on. */
    const val MAX_DEFERRALS = 12

    /** Catalog facts of one song (iOS `DJMode.SongFacts`). [artists] are credited-artist keys (artist spacing). */
    data class Facts(
        val bpm: Double? = null,
        val camelot: String? = null,
        val genre: String? = null,
        val year: Int? = null,
        val artists: Set<String> = emptySet(),
    )

    /** What the rip server / buffer lane / album timeline say about one row, right now. */
    data class RowSignals(
        /** A playback rip is in flight (moving the row out of the rip window would cancel the capture). */
        val ripInFlight: Boolean = false,
        /** The Now Playing buffer lane is fetching this song. */
        val laneFetching: Boolean = false,
        /** A buffer stream is still downloading (not failed, not complete). */
        val bufferStreaming: Boolean = false,
        /** The row is a complete local file, or is becoming one: it will play locally. */
        val willPlayLocally: Boolean = false,
        /** The row belongs to a vinyl album run (the side plays through in record order). */
        val albumLinked: Boolean = false,
    )

    /** The row's per-instance uid as the planner's UUID (queue uids are UUID strings; anything else hashes stably). */
    fun uuidOf(uid: String): UUID = runCatching { UUID.fromString(uid) }.getOrElse { UUID.nameUUIDFromBytes(uid.toByteArray()) }

    /**
     * May the selector move the row? Never: the next-up pick, a row aged out ([MAX_DEFERRALS]), an album-run block, a row
     * the rip server / buffer lane is working on, or the NEXT row once it is local / buffering, mid-transition, of unknown
     * length or inside the 30 s runway ([runwaySeconds] = what the current row has left). Same order as iOS.
     */
    fun rowFixed(
        item: QueueItem,
        isNext: Boolean,
        signals: RowSignals,
        transitioning: Boolean,
        runwaySeconds: Double?,
    ): Boolean {
        if (isNext && item.djUserNext) return true
        if (item.djDeferrals >= MAX_DEFERRALS) return true
        if (signals.albumLinked || signals.ripInFlight || signals.laneFetching || signals.bufferStreaming) return true
        if (!isNext) return false
        if (transitioning || signals.willPlayLocally) return true
        val left = runwaySeconds ?: return true
        return left < REPLACE_NEXT_MIN_RUNWAY_SECONDS
    }

    /** One queue row as a planner candidate. [membership] is song -> collection ids (empty = no collection similarity). */
    fun candidate(
        item: QueueItem,
        facts: Facts?,
        membership: Map<String, Set<String>>,
        fixed: Boolean,
        anchor: Boolean = false,
    ): DjSetPlanner.Candidate {
        val c = DjSetPlanner.candidate(
            uid = uuidOf(item.uid), songId = item.id,
            bpm = facts?.bpm, camelot = facts?.camelot, rawGenre = facts?.genre, year = facts?.year,
            collections = if (membership.isEmpty()) emptySet() else membership[SongVariant.baseId(item.id)].orEmpty(),
            fixed = fixed, artists = facts?.artists.orEmpty(),
        )
        return c.copy(deferrals = item.djDeferrals, anchor = anchor)
    }
}

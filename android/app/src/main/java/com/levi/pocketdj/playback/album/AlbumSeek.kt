package com.levi.pocketdj.playback.album

import com.levi.pocketdj.data.edition.SongVariant

/** Where the song the deck is on lives inside the loaded side file (absolute file ms); [endMs] null = plays to the file's end. */
data class SongSpan(val startMs: Long, val endMs: Long?)

/** What the session player needs to translate the engine's file-relative clock: the loaded item's clip start + the song's span. */
data class RunClock(val clipStartMs: Long, val span: SongSpan)

/** The loaded album run's clock, or null when the engine holds no run item (every other row keeps the engine's own clock). */
fun interface RunClockSource {
    fun current(): RunClock?
}

/**
 * SONG-RELATIVE CLOCKS, pure (P2-ALB-5). A vinyl side is ONE engine item, so the engine's own position/duration are
 * file-relative (`clip start + item position`). Every consumer (lock screen, Auto, widget, skip tracker, snapshot) wants
 * the CURRENT SONG's clock: `fileMs - songStart` (clamped >= 0, so a lead-in shows 0:00) over `songEnd - songStart`.
 * The same maps run in reverse for a remote `seekTo`.
 */
object AlbumSeek {
    /** Song-relative position of the playhead [itemPosMs] (item-relative) of an item clipped at [clipStartMs]. */
    fun relativePosition(itemPosMs: Long, clipStartMs: Long, span: SongSpan): Long =
        (clipStartMs + itemPosMs - span.startMs).coerceAtLeast(0L)

    /**
     * Song-relative duration: `end - start` when the song's end is known, else the file's remaining length from the
     * song's start ([itemDurationMs] is item-relative; null/non-positive = unknown -> null).
     */
    fun relativeDuration(itemDurationMs: Long?, clipStartMs: Long, span: SongSpan): Long? {
        span.endMs?.let { return (it - span.startMs).coerceAtLeast(0L) }
        val d = itemDurationMs?.takeIf { it > 0 } ?: return null
        return (clipStartMs + d - span.startMs).coerceAtLeast(0L)
    }

    /**
     * A remote seek to song-relative [relMs] -> item position. Clamped to the song (never past its end, never before
     * its start) and to >= 0 in the item (an item cannot seek before its clip).
     */
    fun toItemPosition(relMs: Long, clipStartMs: Long, span: SongSpan): Long {
        var rel = relMs.coerceAtLeast(0L)
        span.endMs?.let { rel = rel.coerceAtMost((it - span.startMs).coerceAtLeast(0L)) }
        return (span.startMs + rel - clipStartMs).coerceAtLeast(0L)
    }

    /**
     * The queue index of the occurrence of [songId] NEAREST to [ref], preferring a FORWARD occurrence on a tie (the DJ
     * usually taps a row later in the set). Port of iOS `nearestOccurrence`; null when the song isn't queued.
     */
    fun nearestOccurrence(queueIds: List<String>, songId: String, ref: Int): Int? {
        val base = SongVariant.baseId(songId)
        var best: Int? = null
        for (i in queueIds.indices) {
            if (queueIds[i] != songId && SongVariant.baseId(queueIds[i]) != base) continue
            val b = best
            if (b == null) { best = i; continue }
            val di = kotlin.math.abs(i - ref)
            val db = kotlin.math.abs(b - ref)
            if (di < db || (di == db && i >= ref)) best = i
        }
        return best
    }

    /** iOS `cueNextStart`'s lifetime. */
    const val CUE_TTL_MS = 30_000L

    /**
     * One-shot cue for the NEXT fresh start (the album waveform scrubs an album that isn't playing yet, then starts it):
     * when that start lands on [songId] it begins [atMs] into the song. Consumed by ANY fresh start (matched or not),
     * and expires after [CUE_TTL_MS].
     */
    class StartCue(private val clockMs: () -> Long = System::currentTimeMillis) {
        private var songId: String? = null
        private var atMs: Long = 0
        private var armedAt: Long = 0

        @Synchronized fun arm(songId: String, atMs: Long) { this.songId = songId; this.atMs = atMs; armedAt = clockMs() }

        /** The cue offset for a fresh start on [startingId]; null = none. Always consumes a pending cue. */
        @Synchronized fun consume(startingId: String): Long? {
            val id = songId ?: return null
            songId = null
            if (clockMs() - armedAt >= CUE_TTL_MS || atMs <= 0) return null
            return atMs.takeIf { SongVariant.baseId(id) == SongVariant.baseId(startingId) }
        }
    }
}

package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.edition.SongVariant

/**
 * Where an ANALOG song's window ends inside its shared album file (iOS `SetlistPlayer.sharedFileEndBoundaryMs`).
 * A per-song digital file never gets a window (`startMs` null => null: it has its own natural end).
 *
 * With the side's [AlbumFileTimeline] the song ends at its own end on the record (edited exactly; else detected end +
 * [AlbumFileTimeline.FADE_GRACE_MS], never past the next song's start), not at `startMs + catalog length`, which rarely
 * matches a pressing and cut songs off mid-phrase. Without a timeline: the old `startMs + length`.
 */
object AnalogWindow {
    /** How a song sits in an in-order run of its record (P2-ALB-4): `next` = the next song on the file when it is also the next row. */
    data class Run(val next: AlbumFileTimeline.Segment? = null, val fromPrevious: Boolean = false)

    /**
     * Absolute end (ms) of [songId]'s window in the shared file; null = none (play to the file's natural end, or no
     * window at all when [startMs] is null).
     */
    fun endMs(
        songId: String,
        startMs: Long?,
        timeline: AlbumFileTimeline?,
        run: Run? = null,
        lengthMs: Long? = null,
    ): Long? {
        if (startMs == null) return null
        val base = SongVariant.baseId(songId)
        if (timeline != null && timeline.segment(base)?.startMs == startMs) {
            run?.next?.let { return it.startMs }
            if (run?.fromPrevious == true && timeline.isLast(base)) return null
            return timeline.endMs(base)
        }
        val len = lengthMs?.takeIf { it > 0 } ?: return null
        return startMs + len
    }

    /** Window length (end - start) for the DSP engine; [lengthMs] when no end is known (0 if neither). */
    fun lengthMs(songId: String, startMs: Long?, timeline: AlbumFileTimeline?, lengthMs: Long?, run: Run? = null): Long {
        val end = endMs(songId, startMs, timeline, run, lengthMs)
        if (end != null && startMs != null && end > startMs) return end - startMs
        return lengthMs ?: 0L
    }
}

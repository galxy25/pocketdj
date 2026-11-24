package com.levi.pocketdj.playback.album

import com.levi.pocketdj.data.collections.CollectionMembership
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.rips.AlbumFileTimeline
import com.levi.pocketdj.data.rips.AnalogWindow
import com.levi.pocketdj.playback.sequencer.QueueItem

/** The layout of the shared album file [songId] plays from (user boundary edits applied); null = not a slice of a side. */
fun interface AlbumTimelineSource {
    fun timeline(songId: String): AlbumFileTimeline?
}

/**
 * ALBUM RUN, pure (iOS `SetlistPlayer.albumRun` / `albumLeadIn` / `glideInSameFile` decisions). A vinyl side is ONE
 * ExoPlayer item; when the queue plays the record in order the file just keeps playing and the sequencer only moves the
 * deck's identity from song to song at each next start.
 */
object AlbumRun {
    /**
     * How far past the next song's start the playhead may sit for the boundary to GLIDE onto it in place (the boundary
     * lands a tick late). A playhead further BEFORE the next start than this (a side flip / long gap after the song's
     * end) is skipped with an in-place seek.
     */
    const val GLIDE_TOLERANCE_MS = 3_000L

    /** What the engine is asked to load for a run item (see [plan]). */
    data class Plan(
        /** The song's own start in the file (identity for boundary and position math). */
        val songStartMs: Long,
        /** Where the ONE item starts: 0 for a lead-in, else [songStartMs]. */
        val clipStartMs: Long,
        /** The item's clip end; null = END_OF_SOURCE (the side plays out; boundaries are armed, not clipped). */
        val clipEndMs: Long?,
        /** File position (ms) at which to arm the end-of-song boundary; null = none (plays to the file's end). */
        val boundaryFileMs: Long?,
        val leadIn: Boolean,
        val run: AnalogWindow.Run,
    )

    /**
     * Port of iOS `albumRun`: how the row at [pos] sits in an in-order run of its record. `next` = the next song on the
     * file when that is also queue[pos+1] (compared by base id) and the row won't replay (repeat ONE / a per-row repeat
     * count break the run); `fromPrevious` = queue[pos-1] is the record's previous song.
     */
    fun albumRun(queue: List<QueueItem>, pos: Int, tl: AlbumFileTimeline, repeatOne: Boolean): AnalogWindow.Run {
        val it = queue.getOrNull(pos) ?: return AnalogWindow.Run()
        val base = SongVariant.baseId(it.id)
        val replays = repeatOne || CollectionMembership.normalizedRepeat(it.repeatCount) > 1
        var next: AlbumFileTimeline.Segment? = null
        if (!replays) {
            val seg = tl.next(base)
            val following = queue.getOrNull(pos + 1)
            if (seg != null && following != null && !following.cleanOnlySkip && SongVariant.baseId(following.id) == seg.songId) next = seg
        }
        val prevSeg = tl.previous(base)
        val before = queue.getOrNull(pos - 1)
        val fromPrevious = pos > 0 && prevSeg != null && before != null && SongVariant.baseId(before.id) == prevSeg.songId
        return AnalogWindow.Run(next, fromPrevious)
    }

    /**
     * Port of iOS `albumLeadIn`: the record's FIRST song, starting fresh (never a resume / cue / repeat pass) with the
     * album queued to play through, starts at the file's 0:00 instead of its detected start.
     */
    fun leadIn(
        songId: String,
        startMs: Long,
        tl: AlbumFileTimeline,
        run: AnalogWindow.Run,
        fresh: Boolean,
        resumeAtMs: Long?,
    ): Boolean {
        if (!fresh || resumeAtMs != null || startMs <= 0) return false
        val first = tl.segments.firstOrNull() ?: return false
        return first.songId == SongVariant.baseId(songId) && first.startMs == startMs && run.next != null
    }

    /**
     * The run-item load plan for the row at [pos] starting at [startMs] in its shared file, or null when the row is not
     * part of an in-order run (then it keeps its own clip window, exactly as before). A row is in a run when its next
     * queued row is the record's next song, or it is the record's last song reached through the album (plays to the
     * file's end).
     */
    fun plan(
        queue: List<QueueItem>,
        pos: Int,
        tl: AlbumFileTimeline?,
        startMs: Long?,
        repeatOne: Boolean,
        fresh: Boolean,
        resumeAtMs: Long?,
    ): Plan? {
        if (tl == null || startMs == null) return null
        val it = queue.getOrNull(pos) ?: return null
        val base = SongVariant.baseId(it.id)
        if (tl.segment(base)?.startMs != startMs) return null
        val run = albumRun(queue, pos, tl, repeatOne)
        val lastThroughAlbum = run.fromPrevious && tl.isLast(base)
        if (run.next == null && !lastThroughAlbum) return null
        val lead = leadIn(it.id, startMs, tl, run, fresh, resumeAtMs)
        return Plan(
            songStartMs = startMs,
            clipStartMs = if (lead) 0L else startMs,
            clipEndMs = null,
            boundaryFileMs = run.next?.startMs,
            leadIn = lead,
            run = run,
        )
    }

    /**
     * Where the song at [pos] (just moved onto in place, starting at [startMs]) ends in the loaded file: the next song's
     * start in a run, its own end on the record otherwise, null when it plays to the file's end (the last song reached
     * through the album, or a song the timeline has no end for). Port of iOS `sharedFileEndBoundaryMs`.
     */
    fun boundaryMs(
        queue: List<QueueItem>,
        pos: Int,
        tl: AlbumFileTimeline,
        startMs: Long,
        repeatOne: Boolean,
        lengthMs: Long?,
    ): Long? {
        val it = queue.getOrNull(pos) ?: return null
        val run = albumRun(queue, pos, tl, repeatOne)
        return AnalogWindow.endMs(it.id, startMs, tl, run, lengthMs)
    }

    /** True when [next] (the row after [from]) continues [from]'s run: the preloader must never preload it. */
    fun isRunContinuation(queue: List<QueueItem>, pos: Int, tl: AlbumFileTimeline?, repeatOne: Boolean): Boolean =
        tl != null && albumRun(queue, pos, tl, repeatOne).next != null

    /** What a natural boundary does to the loaded file. */
    sealed interface GlideStep {
        /** Retarget in place; the playhead is already at the next start. */
        data object Retarget : GlideStep

        /** A gap (run-out / side flip) before the next start: seek the SAME item to [toFileMs] FIRST, then retarget. */
        data class SeekThenRetarget(val toFileMs: Long) : GlideStep
    }

    /**
     * Port of the position test in iOS `glideInSameFile`: the playhead [posFileMs] must lie in
     * `[curStartMs, nextStartMs + GLIDE_TOLERANCE_MS]`; a gap > tolerance before the next start is skipped with a seek.
     * Null = decline (the normal reload start runs).
     */
    fun glideStep(posFileMs: Long, curStartMs: Long, nextStartMs: Long): GlideStep? {
        if (posFileMs < curStartMs || posFileMs > nextStartMs + GLIDE_TOLERANCE_MS) return null
        return if (nextStartMs - posFileMs > GLIDE_TOLERANCE_MS) GlideStep.SeekThenRetarget(nextStartMs) else GlideStep.Retarget
    }

    /**
     * ⏭/⏮ in place: the target song must be a segment of the SAME file the loaded run item plays, and its start must
     * lie at or after the item's clip start (an item cannot seek before its clip). Returns the file position to seek to.
     */
    fun jumpTargetMs(targetSongId: String, tl: AlbumFileTimeline?, clipStartMs: Long): Long? {
        val seg = tl?.segment(SongVariant.baseId(targetSongId)) ?: return null
        return seg.startMs.takeIf { it >= clipStartMs }
    }
}

package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.AudioTrack
import com.levi.pocketdj.data.catalog.AudioTrackEdit
import com.levi.pocketdj.data.catalog.AlbumEdit
import com.levi.pocketdj.data.catalog.SongEdit
import com.levi.pocketdj.data.rips.AlbumFileTimeline
import kotlin.math.abs

/**
 * Pure model behind the album waveform editor (iOS `Views/AlbumWaveformEditor.swift`): starts / total / ends, handle
 * hit-testing, the boundary clamp, the save math (deltas only, one [AudioTrackEdit] per RAW segment) and the readout
 * strings. No Compose, no Android types: everything here is JVM-testable.
 */
internal object AlbumBoundaryEdits {
    /** Two songs can never be closer than this (a boundary can't be dragged past its neighbour). */
    const val MIN_GAP_MS = 1_000L

    /** A handle is grabbed when the touch is within this many px of it. */
    const val HANDLE_REACH_PX = 22f

    /** An end-of-side guess when nothing else is known: the last start plus this much. */
    const val RUN_OUT_MS = 240_000L

    /**
     * Per-song starts in track order: the user's edit / manifest start (what playback seeks to), else the indexer's
     * detected segment (only when segments pair 1:1 with the track list). null when any song has no known start.
     */
    fun starts(trackList: List<String>, segments: List<AudioTrack>?, effectiveStart: (String) -> Long?): List<Long>? {
        if (trackList.isEmpty()) return null
        val segs = segments.orEmpty()
        val out = ArrayList<Long>(trackList.size)
        for ((i, id) in trackList.withIndex()) {
            val s = effectiveStart(id) ?: (if (segs.size == trackList.size) segs[i].startMs else null) ?: return null
            out.add(s)
        }
        return out
    }

    /** The side's total length: the loaded file's real duration, else the indexer's length, else past the last segment. */
    fun totalMs(starts: List<Long>, loadedDurationMs: Long?, audioDurationSec: Double?, segments: List<AudioTrack>?): Long {
        if (loadedDurationMs != null && loadedDurationMs > 0) return loadedDurationMs
        if (audioDurationSec != null && audioDurationSec > 0) return (audioDurationSec * 1000).toLong()
        val lastEnd = segments?.lastOrNull()?.endMs ?: 0L
        return maxOf(lastEnd, (starts.lastOrNull() ?: 0L) + RUN_OUT_MS)
    }

    /** Where song [i] stops playing: its edited / detected(+grace) end, never past the next start; the side's end otherwise. */
    fun endMs(
        i: Int,
        trackList: List<String>,
        starts: List<Long>,
        total: Long,
        exactEnd: Map<String, Long>,
        detectedEnd: Map<String, Long>,
        key: String = "",
    ): Long {
        if (i >= trackList.size) return total
        val next = if (i + 1 < starts.size) starts[i + 1] else total
        val tl = AlbumFileTimeline(
            key = key,
            segments = trackList.zip(starts).map { (id, s) -> AlbumFileTimeline.Segment(id, s) },
            exactEndMs = exactEnd,
            detectedEndMs = detectedEnd,
        )
        return minOf(tl.endMs(trackList[i]) ?: next, total)
    }

    /** The song whose region holds [ms] (the lead-in groove belongs to the first). */
    fun indexAt(ms: Long, starts: List<Long>): Int = starts.indexOfLast { it <= ms }.coerceAtLeast(0)

    /** The nearest handle within [HANDLE_REACH_PX] of [px]; boundary [starts].size is the side's end. */
    fun nearestHandle(px: Float, starts: List<Long>, sideEnd: Long, total: Long, width: Float): Int? {
        if (total <= 0) return null
        val all = starts + sideEnd
        val xs = all.map { it.toFloat() / total * width }
        val best = xs.indices.minByOrNull { abs(xs[it] - px) } ?: return null
        return best.takeIf { abs(xs[best] - px) <= HANDLE_REACH_PX }
    }

    /** Keep boundary [i] between its neighbours by [MIN_GAP_MS] (iOS `clamp`). */
    fun clamp(i: Int, ms: Long, starts: List<Long>, sideEnd: Long, total: Long): Long {
        val lo = if (i == 0) 0L else if (i - 1 < starts.size) starts[i - 1] + MIN_GAP_MS else 0L
        val hi = when {
            i + 1 < starts.size -> starts[i + 1] - MIN_GAP_MS
            i < starts.size -> sideEnd - MIN_GAP_MS
            else -> total
        }
        return ms.coerceIn(lo, maxOf(lo, hi))
    }

    /** px -> ms over the full side. */
    fun msAt(px: Float, width: Float, total: Long): Long =
        ((px.coerceIn(0f, width) / width) * total).toLong()

    /** A pan whose vertical travel exceeds its horizontal one is a page scroll (iOS `panIsVertical`): it neither scrubs nor plays. */
    fun isVerticalPan(dx: Float, dy: Float): Boolean = abs(dy) > abs(dx)

    /**
     * Rebuild the album's edit with boundary [index] moved to [ms] (iOS `saveBoundary`). One [AudioTrackEdit] per RAW
     * segment: an existing delta is carried by `trackNumber`, else positionally when it has none; `deltas[i].startMs`
     * and `deltas[i-1].endMs` hold [ms] (null when equal to raw); `index == segments.size` sets the last segment's end.
     * `audioTracks` becomes null when every delta is empty. Returns null when there are no raw segments.
     */
    fun saveBoundary(existing: AlbumEdit?, rawSegments: List<AudioTrack>, index: Int, ms: Long): AlbumEdit? {
        if (rawSegments.isEmpty()) return null
        val edit = existing ?: AlbumEdit()
        val old = edit.audioTracks.orEmpty()
        val deltas: MutableList<AudioTrackEdit> = rawSegments.mapIndexed { j, seg ->
            val n = seg.trackNumber
            val byNumber = if (n != null) old.firstOrNull { it.trackNumber == n } else null
            when {
                byNumber != null -> byNumber
                j < old.size && old[j].trackNumber == null -> old[j].copy(trackNumber = seg.trackNumber)
                else -> AudioTrackEdit(trackNumber = seg.trackNumber)
            }
        }.toMutableList()
        if (index < rawSegments.size) {
            deltas[index] = deltas[index].copy(startMs = ms.takeUnless { it == rawSegments[index].startMs })
            if (index > 0) deltas[index - 1] = deltas[index - 1].copy(endMs = ms.takeUnless { it == rawSegments[index - 1].endMs })
        } else {
            val last = rawSegments.lastIndex
            deltas[last] = deltas[last].copy(endMs = ms.takeUnless { it == rawSegments[last].endMs })
        }
        return edit.copy(audioTracks = deltas.takeIf { d -> d.any { !it.isEmpty } })
    }

    /** `SongEdit.name` is a delta: null when the new name equals the raw one. Blank names change nothing (null). */
    fun renamed(existing: SongEdit?, rawName: String, newName: String): SongEdit? {
        val name = newName.trim()
        if (name.isEmpty()) return null
        return (existing ?: SongEdit()).copy(name = name.takeUnless { it == rawName })
    }

    /** Editing needs the RAW detected segments to pair 1:1 with the track list. */
    fun editable(rawSegmentCount: Int, trackCount: Int): Boolean = rawSegmentCount == trackCount && trackCount > 0

    // ---- strings (iOS parity) ---------------------------------------------------------------------------------------

    /** m:ss.t */
    fun clock(ms: Long): String {
        val t = maxOf(0L, ms) / 100
        return "%d:%02d.%d".format(t / 600, (t / 10) % 60, t % 10)
    }

    /** "1s" / "0.1s" */
    fun step(ms: Int): String = if (ms >= 1000) "${ms / 1000}s" else "0.${ms / 100}s"

    /** Nudge button label: "+1s", "−0.1s" (U+2212 minus like iOS). */
    fun nudgeLabel(deltaMs: Int): String = if (deltaMs > 0) "+${step(deltaMs)}" else "−${step(-deltaMs)}"

    fun readout(dragging: Pair<Int, Long>?, scrubMs: Long?, startsCount: Int, total: Long, titleAt: (Long) -> String): String {
        if (dragging != null) return "${if (dragging.first == startsCount) "End" else "Boundary"} ${clock(dragging.second)}"
        if (scrubMs != null) return "${clock(scrubMs)} · ${titleAt(scrubMs)}"
        return "$startsCount tracks · ${clock(total)}"
    }

    fun hint(editable: Boolean): String =
        if (editable) "Tap to play from any point · drag a dot to move a song boundary · double-tap a song to rename it"
        else "Tap to play from any point · double-tap a song to rename it"

    fun nudgeLabelFor(isEnd: Boolean, title: String, currentMs: Long): String =
        "${if (isEnd) "End of side" else "Start of $title"} · ${clock(currentMs)}"
}

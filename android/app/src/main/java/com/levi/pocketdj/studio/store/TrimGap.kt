package com.levi.pocketdj.studio.store

import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioFactory
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Scissor-trim pure core (iOS `StudioStore.trimGap`). */
object TrimGap {
    /**
     * Cut `[cutStartMs, cutEndMs)` out of one track's [clips], leaving a SILENT gap (nothing slides left).
     * Disjoint clips are kept whole; a straddling clip keeps a head and/or tail piece; the tail windows the
     * SAME file (`fileStartMs` slides forward by the cut end minus the clip start). A middle split mints a new
     * id for the tail; a head- or tail-only trim keeps the clip's identity.
     */
    fun trimGap(
        clips: List<StudioClip>, cutStartMs: Int, cutEndMs: Int,
        newId: () -> String = { StudioFactory.newClipId() },
    ): List<StudioClip> = StudioStore.trimGap(clips, cutStartMs, cutEndMs, newId)

    /** A 4-bar region (default cut band) seeded at [cursorMs], clamped into the timeline and beat-snapped. */
    fun seedRegion(cursorMs: Int, lengthMs: Int, bpm: Double): Pair<Int, Int> {
        val bar4 = if (bpm > 0) ((60_000.0 / bpm) * 4).toInt() else 2_000
        val len = max(0, lengthMs)
        var start = min(max(0, cursorMs), max(0, len - 1))
        var end = min(start + bar4, len)
        if (end <= start) { start = 0; end = min(bar4, max(1, len)) }
        val s = ArrangerMath.snapMs(start, bpm)
        return s to max(s + 1, ArrangerMath.snapMs(end, bpm))
    }
}

/**
 * One scissor-trim session (iOS `TracksView` trim state, made testable): a STAGED clip map per track, an undo
 * stack of prior maps, a track selection (ALL by default, LOCKED once a cut is staged) and the cut region.
 * Nothing touches the store until [save]; [cancel] is a pure revert (zero writes). Not thread-safe (UI thread).
 */
class TrimSession private constructor(
    private val trackOrder: List<String>,
    initial: Map<String, List<StudioClip>>,
    selected: Set<String>,
    region: Pair<Int, Int>,
) {
    private var staged: Map<String, List<StudioClip>> = initial
    private val history = ArrayList<Map<String, List<StudioClip>>>()
    private var _selected: Set<String> = selected
    private var _region: Pair<Int, Int> = region
    private var _closed = false

    val selected: Set<String> get() = _selected
    val regionStartMs: Int get() = _region.first
    val regionEndMs: Int get() = _region.second
    val canUndo: Boolean get() = history.isNotEmpty()
    val closed: Boolean get() = _closed

    /** The selection is locked once a cut is staged (changing it would strand/drop staged edits). */
    val selectionLocked: Boolean get() = history.isNotEmpty()

    /** A cut needs a region AND at least one selected track. */
    val canCut: Boolean get() = !_closed && _region.second > _region.first && _selected.isNotEmpty()

    /** Save needs at least one staged cut. */
    val canSave: Boolean get() = !_closed && history.isNotEmpty() && _selected.isNotEmpty()

    /** The lane's live working copy while trimming (falls back to nothing for an unknown track). */
    fun clipsFor(trackId: String): List<StudioClip> = staged[trackId].orEmpty()

    fun setRegion(startMs: Int, endMs: Int) { _region = max(0, startMs) to max(0, endMs) }

    fun allSelected(): Boolean = trackOrder.isNotEmpty() && _selected.size == trackOrder.size

    fun selectAll() { if (!selectionLocked) _selected = trackOrder.toSet() }

    /** Toggle one track; a no-op while locked. */
    fun setSelected(trackId: String, on: Boolean) {
        if (selectionLocked || trackId !in trackOrder) return
        _selected = if (on) _selected + trackId else _selected - trackId
    }

    /** Selector label: "All tracks" / the single track's name / "N tracks" / "No tracks". */
    fun selectionLabel(nameOf: (String) -> String): String {
        val n = _selected.size
        return when {
            n == 0 -> "No tracks"
            allSelected() -> "All tracks"
            n == 1 -> nameOf(_selected.first()).ifBlank { "Track" }
            else -> "$n tracks"
        }
    }

    /** Apply the region as a cut on every selected track's staged clips (pushing the prior map for Undo). */
    fun cut(newId: () -> String = { StudioFactory.newClipId() }): Boolean {
        if (!canCut) return false
        history += staged
        val next = staged.toMutableMap()
        for (tid in _selected) next[tid] = TrimGap.trimGap(staged[tid].orEmpty(), regionStartMs, regionEndMs, newId)
        staged = next
        return true
    }

    fun undo(): Boolean {
        if (_closed || history.isEmpty()) return false
        staged = history.removeAt(history.lastIndex)
        return true
    }

    /**
     * Commit each selected track through [StudioStore.commitTrimmedTrack] (dedupes a shared tail to its own file
     * + cleans orphans). False (and no write) when nothing is staged. Closes the session.
     */
    fun save(store: StudioStore, arrangementId: String): Boolean {
        if (!canSave) { _closed = true; return false }
        for (tid in trackOrder) if (tid in _selected) {
            // The grid analyzer may have written grids since begin(): keep the store's current grid for an unchanged clip (same id + file).
            val current = store.arrangement(arrangementId)?.tracks?.firstOrNull { it.id == tid }?.clips.orEmpty().associateBy { it.id }
            val merged = staged[tid].orEmpty().map { c ->
                val cur = current[c.id]
                if (c.grid == null && cur?.grid != null && cur.fileName == c.fileName) c.copy(grid = cur.grid) else c
            }
            store.commitTrimmedTrack(arrangementId, tid, merged)
        }
        _closed = true
        return true
    }

    /** Discard everything. Zero store writes. */
    fun cancel() { _closed = true; history.clear() }

    companion object {
        /** Open a session on [arr]: ALL tracks selected + staged, a 4-bar region seeded at the cursor. Null when empty. */
        fun begin(arr: StudioArrangement, cursorMs: Int): TrimSession? {
            if (arr.tracks.isEmpty()) return null
            val order = arr.tracks.map { it.id }
            val cur = ArrangerMath.effectiveCursorMs(cursorMs, arr.lengthMs)
            return TrimSession(order, arr.tracks.associate { it.id to it.clips }, order.toSet(), TrimGap.seedRegion(cur, arr.lengthMs, arr.bpm))
        }
    }
}

package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.demux.BeatDetect
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioGrid
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Background, on-device BEAT-GRID analysis for the arranger's Beat Match mode (iOS
 * `StudioArrangerGridAnalyzer`). Each clip's baked audio is analyzed off the main thread with the same
 * [BeatDetect] the sample/slice editors use, producing a [StudioGrid] (bpm + downbeat) cached on the clip.
 * Beat Match warps every clip so its detected tempo equals the arrangement bpm and snaps starts to the
 * grid; until every clip is analyzed the Beat Match control stays disabled ("Beat grid under
 * construction", `StudioArrangement.beatGridReady`).
 *
 * Idempotent + lazy: only clips with `grid == null` are analyzed, and each result is written back AFTER
 * re-checking the clip still exists and still needs a grid (a delete/trim between kickoff and write-back
 * must not resurrect it). A detection that returns null (too short / quiet / aperiodic) or an unresolvable
 * file stores the zero-bpm [UNANALYZABLE] sentinel so a single bad clip can't wedge the "ready" gate
 * forever; Beat Match simply leaves such clips un-warped (`ArrangerBeatMatch.rate` treats bpm <= 0 as 1x).
 */
class ArrangerGridAnalyzer(
    private val arrangement: (String) -> StudioArrangement?,
    private val setGrid: (arrangementId: String, trackId: String, clipId: String, grid: StudioGrid) -> Unit,
    /** Canonical PCM of a clip file name, null when the file can't be resolved/decoded. */
    private val decode: suspend (fileName: String) -> PcmBuffer?,
    private val detect: (PcmBuffer) -> StudioGrid? = { BeatDetect.detectGrid(it) },
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    private val inFlight = HashSet<String>()

    /** Analyze every not-yet-analyzed clip of [arrangementId]; returns how many grids were written. Safe to call repeatedly. */
    suspend fun ensureGrids(arrangementId: String): Int {
        val arr = arrangement(arrangementId) ?: return 0
        // Snapshot the work up front so no stale arrangement value is held across the awaits.
        val jobs = arr.tracks.flatMap { t -> t.clips.filter { it.grid == null }.map { Job(t.id, it.id, it.fileName) } }
        var written = 0
        for (job in jobs) {
            if (!claim(job.clipId)) continue                    // an overlapping run is already on it
            try {
                if (!needsGrid(arrangementId, job)) continue   // analyzed by an overlapping run since the snapshot
                val pcm = decode(job.fileName)
                val grid = if (pcm == null) null else withContext(dispatcher) { runCatching { detect(pcm) }.getOrNull() }
                // Re-check existence before the write: the clip may have been deleted/trimmed mid-analysis.
                if (!needsGrid(arrangementId, job)) continue
                setGrid(arrangementId, job.trackId, job.clipId, grid ?: UNANALYZABLE)
                written++
            } finally { release(job.clipId) }
        }
        return written
    }

    private data class Job(val trackId: String, val clipId: String, val fileName: String)

    private fun needsGrid(arrangementId: String, job: Job): Boolean {
        val clip = arrangement(arrangementId)?.tracks?.firstOrNull { it.id == job.trackId }?.clips?.firstOrNull { it.id == job.clipId }
        return clip != null && clip.grid == null
    }

    private fun claim(id: String) = synchronized(inFlight) { inFlight.add(id) }
    private fun release(id: String) { synchronized(inFlight) { inFlight.remove(id) } }

    companion object {
        /** "Analyzed, no usable tempo": bpm 0 means Beat Match leaves the clip at its natural rate. */
        val UNANALYZABLE = StudioGrid(bpm = 0.0)

        /** True when [grid] is the sentinel (or otherwise carries no usable tempo). */
        fun isUsable(grid: StudioGrid?) = grid != null && grid.bpm > 0

        /** UI gate copy: why Beat Match is disabled, or null when it can be toggled. */
        fun underConstructionMessage(arr: StudioArrangement): String? =
            if (arr.allClips.isNotEmpty() && !arr.beatGridReady) "Beat grid under construction…" else null
    }
}

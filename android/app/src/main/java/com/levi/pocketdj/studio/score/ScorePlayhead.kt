package com.levi.pocketdj.studio.score

import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlin.math.max
import kotlin.math.min

/**
 * Where playback sits in a score and what has already sounded (iOS `ScorePlaybackState`). [currentOnset16ths] is the onset of the
 * note SOUNDING or, once it ended, the LAST that sounded; null until the playhead reaches the first note.
 */
data class ScorePlaybackState(val cursor16ths: Double, val currentOnset16ths: Int?, val isSounding: Boolean) {
    fun isPlayed(onset16ths: Int): Boolean = currentOnset16ths?.let { onset16ths < it } ?: false
    fun isCurrent(onset16ths: Int): Boolean = onset16ths == currentOnset16ths

    companion object { val IDLE = ScorePlaybackState(0.0, null, false) }
}

/** Pure time -> playback-state math. `timeline` once per event stream, `state` per playhead read (binary search). */
object ScorePlayhead {
    data class Slot(val onset16ths: Int, val end16ths: Int)

    /** Upper clamp for every ms -> 16ths conversion (about 87 h at 120 BPM). */
    const val MAX_CURSOR_16THS = 10_000_000.0
    /** Ceiling for every 16ths -> ms conversion (24 h). */
    const val MAX_CURSOR_MS = 86_400_000.0

    fun cursor16ths(ms: Int, bpm: Double): Double {
        val raw = ms / ScoreQuantizer.sixteenthMs(bpm)
        if (!raw.isFinite()) return 0.0
        return min(max(raw, 0.0), MAX_CURSOR_16THS)
    }

    fun ms(fractional16ths: Double, bpm: Double): Int {
        if (!fractional16ths.isFinite()) return 0
        val raw = min(max(fractional16ths, 0.0), MAX_CURSOR_16THS) * ScoreQuantizer.sixteenthMs(bpm)
        if (!raw.isFinite()) return 0
        return roundHalfAway(min(max(raw, 0.0), MAX_CURSOR_MS)).toInt()
    }

    /** Same-onset notes collapse into ONE slot (as the quantizer merges them); a slot ends at its longest member's RAW end (min one 16th). */
    fun timeline(events: List<StudioNoteEvent>, bpm: Double): List<Slot> {
        val ends = HashMap<Int, Int>()
        for (e in events) {
            val on = roundHalfAway(cursor16ths(max(0, e.onMs), bpm)).toInt()
            val off = max(on + 1, roundHalfAway(cursor16ths(max(0, e.offMs), bpm)).toInt())
            ends[on] = max(ends[on] ?: 0, off)
        }
        return ends.keys.sorted().map { Slot(it, ends[it] ?: (it + 1)) }
    }

    /** Playback state at [atMs] (score clock); null => idle. [slots] MUST be onset-ordered. */
    fun state(atMs: Int?, slots: List<Slot>, bpm: Double): ScorePlaybackState {
        if (atMs == null) return ScorePlaybackState.IDLE
        val cursor = cursor16ths(atMs, bpm)
        var lo = 0; var hi = slots.size - 1; var found = -1
        while (lo <= hi) {
            val mid = lo + (hi - lo) / 2
            if (slots[mid].onset16ths.toDouble() <= cursor) { found = mid; lo = mid + 1 } else hi = mid - 1
        }
        if (found < 0) return ScorePlaybackState(cursor, null, false)
        val slot = slots[found]
        return ScorePlaybackState(cursor, slot.onset16ths, cursor < slot.end16ths.toDouble())
    }
}

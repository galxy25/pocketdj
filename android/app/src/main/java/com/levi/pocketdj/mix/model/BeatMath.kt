package com.levi.pocketdj.mix.model

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

/** Beat grid: all positions Int ms from the song's 0:00; [beatsMs] may be empty (synthesize from bpm). */
data class BeatGrid(val bpm: Double, val firstDownbeatMs: Int, val beatsMs: List<Int>)

data class LastBeat(val beatMs: Int, val isDownbeat: Boolean)
data class SliceBounds(val startMs: Int, val endMs: Int, val lengthMs: Int)

/** Schoolbook rounding (half away from zero), matching Swift `.rounded()`. */
internal fun roundAway(x: Double): Double = if (x < 0) -floor(-x + 0.5) else floor(x + 0.5)

/** Port of Support/BeatMath.swift: pure beat-grid math shared by pulse, slicing and FX modulation. */
object BeatMath {
    /** +/- tolerance (ms) for near-membership of a beat in downbeatsMs. */
    const val DOWNBEAT_TOLERANCE_MS = 30

    /** Most recent beat at/just before [atMs] on the REAL grid; null before first beat / empty grid. */
    fun lastBeat(beatsMs: List<Int>, downbeatsMs: List<Int>?, atMs: Double): LastBeat? {
        if (beatsMs.isEmpty()) return null
        var lo = 0
        var hi = beatsMs.size
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (beatsMs[mid].toDouble() <= atMs) lo = mid + 1 else hi = mid
        }
        if (lo == 0) return null
        val bms = beatsMs[lo - 1]
        return LastBeat(bms, isDownbeat(bms, downbeatsMs))
    }

    /** Near-membership (+/- tolerance) of [beatMs] in the measured downbeats. */
    fun isDownbeat(beatMs: Int, downbeatsMs: List<Int>?): Boolean {
        val d = downbeatsMs
        if (d.isNullOrEmpty()) return false
        var lo = 0
        var hi = d.size
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (d[mid] < beatMs) lo = mid + 1 else hi = mid
        }
        return listOf(lo - 1, lo).any { it >= 0 && it < d.size && abs(d[it] - beatMs) <= DOWNBEAT_TOLERANCE_MS }
    }

    /**
     * Beat-aligned loop-slice boundaries: from the nearest beat >= [anchorMs] walk [beats] beats.
     * Real grid walks actual timestamps (extending past the end at constant spacing); empty grid
     * synthesizes a lattice from firstDownbeatMs. null when no usable grid or beats <= 0.
     */
    fun sliceBoundaries(anchorMs: Int, beats: Double, grid: BeatGrid): SliceBounds? {
        if (!(beats > 0)) return null
        val real = grid.beatsMs
        if (real.isNotEmpty()) {
            val step: Double? = if (grid.bpm > 0) 60000.0 / grid.bpm
            else if (real.size >= 2) (real[real.size - 1] - real[0]).toDouble() / (real.size - 1).toDouble()
            else null
            var lo = 0
            var hi = real.size
            while (lo < hi) {
                val mid = (lo + hi) / 2
                if (real[mid] < anchorMs) lo = mid + 1 else hi = mid
            }
            val last = real.size - 1
            fun beatAt(n: Int): Double? {
                val idx = lo + n
                if (idx < real.size) return real[idx].toDouble()
                val st = step ?: return null
                if (lo >= real.size) {
                    val base = real[last].toDouble()
                    val k = max(1, ceil((anchorMs.toDouble() - base) / st).toInt())
                    return base + (k + n).toDouble() * st
                }
                return real[last].toDouble() + (idx - last).toDouble() * st
            }
            val start = beatAt(0) ?: return null
            val whole = floor(beats).toInt()
            val frac = beats - whole.toDouble()
            val end: Double = if (frac == 0.0) {
                beatAt(whole) ?: return null
            } else {
                val a = beatAt(whole) ?: return null
                val b = beatAt(whole + 1) ?: return null
                a + frac * (b - a)
            }
            val s = roundAway(start).toInt()
            val e = roundAway(end).toInt()
            return SliceBounds(s, e, e - s)
        }
        if (!(grid.bpm > 0)) return null
        val step = 60000.0 / grid.bpm
        val n = max(0, ceil((anchorMs.toDouble() - grid.firstDownbeatMs.toDouble()) / step).toInt())
        val start = grid.firstDownbeatMs.toDouble() + n.toDouble() * step
        val len = roundAway(beats * step).toInt()
        val s = roundAway(start).toInt()
        return SliceBounds(s, s + len, len)
    }

    /** Up to [count] slice START points partitioning [0, durationMs); beat-snapped when a grid exists. */
    fun sliceStarts(count: Int, grid: BeatGrid?, durationMs: Int): List<Int> {
        val n = max(1, minOf(count, 8))
        if (durationMs <= 0) return listOf(0)
        val targets = (0 until n).map { it * durationMs / n }
        val beats = grid?.let { beatLattice(it, durationMs) }
        if (beats.isNullOrEmpty()) return targets
        val out = targets.map { t -> beats.minByOrNull { abs(it - t) } ?: t }.toMutableList()
        out[0] = 0
        return out.toSet().sorted()
    }

    /**
     * Fractional position (0 <= phase < 1) through a modulation cycle of [cycleBeats] at source
     * time [atMs], anchored on a bar downbeat. Extends past either end of the measured grid at the
     * grid's own spacing; constant lattice when no measured grid. null if nothing to lock to.
     */
    fun cyclePhase(
        atMs: Double, beatsMs: List<Int>?, downbeatsMs: List<Int>?,
        bpm: Double, firstDownbeatMs: Int, cycleBeats: Double, offset: Double = 0.0,
    ): Double? {
        if (!(cycleBeats > 0)) return null
        val beatPos: Double
        if (!beatsMs.isNullOrEmpty()) {
            val real = beatsMs
            val step: Double = if (bpm > 0) 60000.0 / bpm
            else if (real.size >= 2) (real[real.size - 1] - real[0]).toDouble() / (real.size - 1).toDouble()
            else 500.0
            var lo = 0
            var hi = real.size
            while (lo < hi) {
                val mid = (lo + hi) / 2
                if (real[mid].toDouble() <= atMs) lo = mid + 1 else hi = mid
            }
            val idx: Double = if (lo == 0) {
                (atMs - real[0].toDouble()) / step
            } else if (lo >= real.size) {
                (real.size - 1).toDouble() + (atMs - real[real.size - 1].toDouble()) / step
            } else {
                val a = real[lo - 1].toDouble()
                val b = real[lo].toDouble()
                (lo - 1).toDouble() + (atMs - a) / max(b - a, 1.0)
            }
            var anchor = 0.0
            if (!downbeatsMs.isNullOrEmpty()) {
                var dlo = 0
                var dhi = downbeatsMs.size
                while (dlo < dhi) {
                    val mid = (dlo + dhi) / 2
                    if (downbeatsMs[mid].toDouble() <= atMs) dlo = mid + 1 else dhi = mid
                }
                if (dlo > 0) {
                    val dms = downbeatsMs[dlo - 1]
                    var blo = 0
                    var bhi = real.size
                    while (blo < bhi) {
                        val mid = (blo + bhi) / 2
                        if (real[mid] < dms) blo = mid + 1 else bhi = mid
                    }
                    for (c in listOf(blo - 1, blo)) {
                        if (c >= 0 && c < real.size && abs(real[c] - dms) <= DOWNBEAT_TOLERANCE_MS) {
                            anchor = c.toDouble()
                            break
                        }
                    }
                }
            }
            beatPos = idx - anchor
        } else {
            if (!(bpm > 0)) return null
            beatPos = (atMs - firstDownbeatMs.toDouble()) / (60000.0 / bpm)
        }
        val raw = beatPos / cycleBeats + offset
        return raw - floor(raw)
    }

    private fun beatLattice(g: BeatGrid, durationMs: Int): List<Int>? {
        if (g.beatsMs.isNotEmpty()) return g.beatsMs.filter { it >= 0 && it < durationMs }
        if (!(g.bpm > 0)) return null
        val step = 60_000.0 / g.bpm
        var x = g.firstDownbeatMs.toDouble()
        while (x - step >= 0) x -= step
        val out = ArrayList<Int>()
        while (x < durationMs.toDouble()) {
            if (x >= 0) out.add(roundAway(x).toInt())
            x += step
        }
        return out
    }
}

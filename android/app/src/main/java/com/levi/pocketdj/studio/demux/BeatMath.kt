package com.levi.pocketdj.studio.demux

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/** A beat grid in the shape the slice math consumes (all positions Int ms from the item's own 0:00). */
data class BeatGrid(val bpm: Double, val firstDownbeatMs: Int, val beatsMs: List<Int> = emptyList())

data class LastBeat(val beatMs: Int, val isDownbeat: Boolean)
data class SliceBounds(val startMs: Int, val endMs: Int, val lengthMs: Int)

/**
 * Port of Support/BeatMath.swift: ONE shared beat-grid implementation (pulse, slicer, tests).
 * `beatsMs` is the REAL measured grid; when absent a constant lattice is synthesised from bpm +
 * firstDownbeatMs.
 */
object BeatMath {
    /** +/- tolerance for near-membership of a beat in `downbeatsMs` (well under half the shortest IBI). */
    const val DOWNBEAT_TOLERANCE_MS = 30

    /** Most recent beat at/before [atMs] on the REAL grid (binary search); null before the first beat or when empty. */
    fun lastBeat(beatsMs: List<Int>, downbeatsMs: List<Int>?, atMs: Double): LastBeat? {
        if (beatsMs.isEmpty()) return null
        var lo = 0; var hi = beatsMs.size
        while (lo < hi) { val mid = (lo + hi) / 2; if (beatsMs[mid].toDouble() <= atMs) lo = mid + 1 else hi = mid }
        if (lo == 0) return null
        val b = beatsMs[lo - 1]
        return LastBeat(b, isDownbeat(b, downbeatsMs))
    }

    fun isDownbeat(beatMs: Int, downbeatsMs: List<Int>?): Boolean {
        val d = downbeatsMs ?: return false
        if (d.isEmpty()) return false
        var lo = 0; var hi = d.size
        while (lo < hi) { val mid = (lo + hi) / 2; if (d[mid] < beatMs) lo = mid + 1 else hi = mid }
        return listOf(lo - 1, lo).any { it >= 0 && it < d.size && abs(d[it] - beatMs) <= DOWNBEAT_TOLERANCE_MS }
    }

    /**
     * Beat-aligned loop-slice boundaries: start at the nearest beat >= [anchorMs], walk [beats] beats.
     * Real grid => sum of real intervals (extended past the end on 60000/bpm); empty grid => constant
     * lattice at firstDownbeatMs with length exactly beats*60000/bpm. Null when no usable grid or beats<=0.
     */
    fun sliceBoundaries(anchorMs: Int, beats: Double, grid: BeatGrid): SliceBounds? {
        if (beats <= 0) return null
        val real = grid.beatsMs
        if (real.isNotEmpty()) {
            val step: Double? = if (grid.bpm > 0) 60000.0 / grid.bpm
            else if (real.size >= 2) (real.last() - real.first()).toDouble() / (real.size - 1) else null
            var lo = 0; var hi = real.size
            while (lo < hi) { val mid = (lo + hi) / 2; if (real[mid] < anchorMs) lo = mid + 1 else hi = mid }
            val last = real.size - 1
            fun beatAt(n: Int): Double? {
                val idx = lo + n
                if (idx < real.size) return real[idx].toDouble()
                val st = step ?: return null
                if (lo >= real.size) {
                    val base = real[last].toDouble()
                    val k = maxOf(1, ceil((anchorMs - base) / st).toInt())
                    return base + (k + n) * st
                }
                return real[last] + (idx - last) * st
            }
            val start = beatAt(0) ?: return null
            val whole = floor(beats).toInt()
            val frac = beats - whole
            val end = if (frac == 0.0) beatAt(whole) ?: return null else {
                val a = beatAt(whole) ?: return null
                val b = beatAt(whole + 1) ?: return null
                a + frac * (b - a)
            }
            val s = jround(start); val e = jround(end)
            return SliceBounds(s, e, e - s)
        }
        if (grid.bpm <= 0) return null
        val step = 60000.0 / grid.bpm
        val n = maxOf(0, ceil((anchorMs - grid.firstDownbeatMs.toDouble()) / step).toInt())
        val start = grid.firstDownbeatMs + n * step
        val len = jround(beats * step)
        val s = jround(start)
        return SliceBounds(s, s + len, len)
    }

    /**
     * Up to [count] (cap 8) slice START points partitioning [0, durationMs): even chop, snapped to the
     * nearest beat when a grid exists. Pad 0 is always 0; de-duped + sorted.
     */
    fun sliceStarts(count: Int, grid: BeatGrid?, durationMs: Int): List<Int> {
        val n = maxOf(1, minOf(count, 8))
        if (durationMs <= 0) return listOf(0)
        val targets = (0 until n).map { it * durationMs / n }
        val beats = grid?.let { beatLattice(it, durationMs) }
        if (beats.isNullOrEmpty()) return targets
        val out = targets.map { t -> beats.minByOrNull { abs(it - t) } ?: t }.toMutableList()
        out[0] = 0
        return out.toSet().sorted()
    }

    /** Beat positions in [0, durationMs): the measured grid, else a constant lattice phased on firstDownbeatMs. */
    fun beatLattice(g: BeatGrid, durationMs: Int): List<Int>? {
        if (g.beatsMs.isNotEmpty()) return g.beatsMs.filter { it >= 0 && it < durationMs }
        if (g.bpm <= 0) return null
        val step = 60000.0 / g.bpm
        var x = g.firstDownbeatMs.toDouble()
        while (x - step >= 0) x -= step
        val out = ArrayList<Int>()
        while (x < durationMs) { if (x >= 0) out.add(jround(x)); x += step }
        return out
    }

    /**
     * Shift a grid by [offsetMs] (a carve starting at offsetMs inside the source): positions move to the
     * sample's own 0:00 and only beats inside [0, lengthMs) survive. A constant grid re-phases.
     */
    fun shifted(grid: BeatGrid, offsetMs: Int, lengthMs: Int): BeatGrid {
        if (grid.beatsMs.isNotEmpty()) {
            return BeatGrid(grid.bpm, shiftPhase(grid.firstDownbeatMs, offsetMs, grid.bpm),
                grid.beatsMs.map { it - offsetMs }.filter { it >= 0 && it < lengthMs })
        }
        return BeatGrid(grid.bpm, shiftPhase(grid.firstDownbeatMs, offsetMs, grid.bpm))
    }

    /** firstDownbeat after moving 0:00 forward by [offsetMs]; wraps onto the next lattice beat if negative. */
    fun shiftPhase(firstDownbeatMs: Int, offsetMs: Int, bpm: Double): Int {
        val v = firstDownbeatMs - offsetMs
        if (v >= 0 || bpm <= 0) return maxOf(0, v)
        val step = 60000.0 / bpm
        return jround(v + ceil(-v / step) * step).coerceAtLeast(0)
    }


    /**
     * The grid a track carve inherits. FULL sidecar grid: song-relative beats offset-shifted into
     * region-relative ms keeping ONLY beats inside [regionStart, regionEnd]; first kept downbeat (else
     * first kept beat) becomes firstDownbeatMs; bpm = sidecar bpm, else median-interval bpm, else
     * [fallbackBpm], else 120. No beats => constant grid from [scalarBpm] (manifest bpm, else catalog),
     * else null (tap-tempo later).
     */
    fun inheritedGrid(
        beatsMs: List<Int>, downbeatsMs: List<Int>, sidecarBpm: Double?,
        regionStartMs: Int, regionEndMs: Int, fallbackBpm: Double?, scalarBpm: Double?,
    ): BeatGrid? {
        if (beatsMs.isNotEmpty()) {
            val kept = beatsMs.filter { it >= regionStartMs && it <= regionEndMs }.map { it - regionStartMs }
            if (kept.isNotEmpty()) {
                val keptDown = downbeatsMs.filter { it >= regionStartMs && it <= regionEndMs }.map { it - regionStartMs }
                val firstDown = keptDown.firstOrNull() ?: kept.first()
                val bpm = sidecarBpm ?: medianBpm(kept) ?: fallbackBpm ?: 120.0
                return BeatGrid(bpm, firstDown, kept)
            }
        }
        val b = scalarBpm
        return if (b != null && b > 0) BeatGrid(b, 0, emptyList()) else null
    }

    /** Median-interval BPM (one ragged interval must not skew it); null for < 2 beats. */
    fun medianBpm(beats: List<Int>): Double? {
        if (beats.size < 2) return null
        val diffs = beats.zipWithNext { a, b -> (b - a).toDouble() }.filter { it > 0 }.sorted()
        if (diffs.isEmpty()) return null
        val m = diffs[diffs.size / 2]
        return if (m > 0) 60000.0 / m else null
    }

    private fun jround(x: Double): Int = Math.round(x).toInt()
}

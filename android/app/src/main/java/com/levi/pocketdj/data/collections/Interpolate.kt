package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.browse.Camelot
import com.levi.pocketdj.screens.browse.Genre
import kotlin.math.floor

/**
 * Harmonic interpolation — port of iOS `Performance/Interpolate.swift`
 * (specs/realize-play.md §4.6). realize()'s autofill uses this to splice smooth
 * transitions into temporal gaps: [interpolatePath] lays down target points
 * between two anchors, [nearestCandidate] snaps the closest real catalog song
 * onto a target. Pure + deterministic.
 */

/** One sampled point along the bridge between two anchors. */
data class TargetPoint(
    /** Linear-interpolated (null when either anchor has no bpm). */
    val bpm: Double?,
    /** Stepped toward the target along the SHORTER wheel arc (null if missing). */
    val camelot: String?,
    /** Genre top-level category in force at this point (null if unknown). */
    val category: String?,
    /** Position along the bridge, in (0, 1). */
    val ratio: Double,
)

object Interpolate {
    /** Fallback duration (ms) a candidate contributes — mirrors [RealizeEngine.DEFAULT_TRACK_MS]. */
    const val DEFAULT_CANDIDATE_MS = 210_000L

    fun candidateMs(song: IndexSong): Long {
        val l = song.length
        return if (l != null && l > 0) l else DEFAULT_CANDIDATE_MS
    }

    /**
     * The 24 contiguous wheel positions ordered by [Camelot.rank]:
     * 1A (rank 2), 1B (3), 2A (4) … 12B (25). Index = rank − 2.
     */
    val CAMELOT_KEYS: List<String> = (1..12).flatMap { listOf("${it}A", "${it}B") }

    private const val WHEEL = 24

    /**
     * Step from `fromRank` toward `toRank` around the 24-slot wheel by `ratio`,
     * choosing the SHORTER direction. JS `Math.round` (halves toward +∞ =
     * `floor(x + 0.5)`) is replicated so a negative delta steps identically to
     * the PWA/iOS.
     */
    private fun stepCamelot(fromRank: Int, toRank: Int, ratio: Double): String {
        val fromIdx = fromRank - 2
        val toIdx = toRank - 2
        var delta = (toIdx - fromIdx) % WHEEL
        if (delta < 0) delta += WHEEL // 0..WHEEL-1
        if (delta > WHEEL / 2) delta -= WHEEL // shorter arc: -WHEEL/2 .. WHEEL/2
        val stepped = fromIdx + floor(delta * ratio + 0.5).toInt()
        val idx = ((stepped % WHEEL) + WHEEL) % WHEEL
        return CAMELOT_KEYS[idx]
    }

    /** Top-level category, or null when unknown ("Other" surfaces as null). */
    private fun categoryOf(genre: String?): String? {
        val cat = Genre.category(genre)
        return if (cat == Genre.OTHER) null else cat
    }

    /**
     * Build `steps` target points bridging two anchor songs. Point i (0-based):
     * ratio = (i+1)/(steps+1); bpm linear lerp (null unless both anchors have
     * bpm); camelot stepped along the shorter arc; category = from's while
     * ratio < 0.5 else to's. `steps <= 0` yields [].
     */
    fun interpolatePath(
        from: IndexSong,
        to: IndexSong,
        steps: Int,
        fromGenre: String?,
        toGenre: String?,
    ): List<TargetPoint> {
        if (steps <= 0) return emptyList()

        val fromBpm = from.bpm
        val toBpm = to.bpm
        val bpmOk = fromBpm != null && toBpm != null

        val fromRank = Camelot.rank(from.camelot)
        val toRank = Camelot.rank(to.camelot)
        val wheelOk = fromRank != null && toRank != null

        val fromCategory = categoryOf(fromGenre)
        val toCategory = categoryOf(toGenre)

        return (0 until steps).map { i ->
            val ratio = (i + 1).toDouble() / (steps + 1).toDouble()
            TargetPoint(
                bpm = if (bpmOk) fromBpm!! + (toBpm!! - fromBpm) * ratio else null,
                camelot = if (wheelOk) stepCamelot(fromRank!!, toRank!!, ratio) else null,
                category = if (ratio < 0.5) fromCategory else toCategory,
                ratio = ratio,
            )
        }
    }

    /**
     * Pick the catalog song closest to `target`. Eligibility: not in `used`,
     * BOTH bpm and camelot present, `candidateMs <= maxMs`. Score =
     * wKey·camelotDistance + wBpm·bpmDistance + wGenre·genreDistance with null
     * axes dropped (NO renormalization here). Deterministic: ties resolve to
     * the FIRST candidate encountered.
     */
    fun nearestCandidate(
        target: TargetPoint,
        candidates: List<IndexSong>,
        used: Set<String>,
        genreOf: (IndexSong) -> String?,
        weights: HarmonicWeights? = null,
        maxMs: Long? = null,
    ): IndexSong? {
        val wKey = weights?.key ?: 1.0
        val wBpm = weights?.bpm ?: 1.0
        val wGenre = weights?.genre ?: 1.0
        val cap = maxMs ?: Long.MAX_VALUE

        var best: IndexSong? = null
        var bestScore = Double.POSITIVE_INFINITY
        for (c in candidates) {
            if (c.id in used) continue
            if (c.bpm == null || c.camelot == null) continue // must be beat+key mixable
            if (candidateMs(c) > cap) continue // won't fit the budget

            val cam = Harmonics.camelotDistance(target.camelot, c.camelot)
            val bpm = Harmonics.bpmDistance(target.bpm, c.bpm)
            val gen = Harmonics.genreDistance(target.category, genreOf(c))

            var score = wGenre * gen
            if (cam != null) score += wKey * cam
            if (bpm != null) score += wBpm * bpm

            if (score < bestScore) {
                bestScore = score
                best = c
            }
        }
        return best
    }
}

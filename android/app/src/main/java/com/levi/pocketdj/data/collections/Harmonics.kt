package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.browse.Camelot
import com.levi.pocketdj.screens.browse.Genre
import kotlin.math.abs
import kotlin.math.min

/**
 * Harmonic-distance toolkit — port of iOS `Performance/Harmonics.swift`
 * (specs/realize-play.md §4.6). Every distance is NULL-SAFE: camelot/bpm return
 * null when data is missing; the categorical axes always return a finite value.
 * [Harmonics.harmonicDistance] DROPS nil axes and renormalizes the remaining
 * weights, so the blend stays in [0, 1] regardless of metadata coverage.
 *
 * Camelot parsing/ranking and genre categorization are shared with Browse
 * ([Camelot]/[Genre]) rather than duplicated.
 */
data class HarmonicWeights(
    val key: Double,
    val bpm: Double,
    val genre: Double,
    val artist: Double,
    val sentiment: Double,
)

/** key + bpm dominate; need not sum to 1 — harmonicDistance normalizes. */
val DEFAULT_WEIGHTS = HarmonicWeights(key = 0.35, bpm = 0.3, genre = 0.2, artist = 0.05, sentiment = 0.1)

object Harmonics {
    /** Max camelot-step distance (6 hours apart + mode mismatch) — normalizes into [0,1]. */
    const val MAX_CAMELOT_STEPS = 7.0

    /** Spread (in BPM) at which two tempos are maximally far. */
    private const val BPM_SPREAD = 30.0

    /** Decompose a Camelot code into wheel hour (1..12) + mode (major = B). */
    private fun camelotParts(code: String?): Pair<Int, Boolean>? {
        val rank = Camelot.rank(code) ?: return null
        // rank = hour*2 + (B?1:0). B is odd, A even.
        return (rank shr 1) to ((rank and 1) == 1)
    }

    private fun hourGap(a: Int, b: Int): Int {
        val raw = abs(a - b)
        return min(raw, 12 - raw)
    }

    /**
     * Camelot-wheel distance in steps (0..7), null if either key is unparseable:
     * same code → 0; adjacent hour same mode → 1; relative major/minor → 1;
     * else shortest hour gap + 1 if modes differ.
     */
    fun camelotDistance(a: String?, b: String?): Double? {
        val pa = camelotParts(a) ?: return null
        val pb = camelotParts(b) ?: return null
        if (pa.first == pb.first && pa.second == pb.second) return 0.0
        val gap = hourGap(pa.first, pb.first)
        val modesDiffer = pa.second != pb.second
        if (gap == 1 && !modesDiffer) return 1.0
        if (gap == 0 && modesDiffer) return 1.0
        return (gap + if (modesDiffer) 1 else 0).toDouble()
    }

    /**
     * Tempo distance normalized to [0,1], null-safe + half/double-time aware:
     * folds `b` toward `a` by ×2 or ÷2 (≤ 4 times) while that shrinks the gap.
     */
    fun bpmDistance(bpmA: Double?, bpmB: Double?): Double? {
        if (bpmA == null || bpmB == null) return null
        val a: Double = bpmA
        val b: Double = bpmB
        if (!a.isFinite() || !b.isFinite() || a <= 0 || b <= 0) return null
        var folded: Double = b
        var gap = abs(a - folded)
        for (i in 0 until 4) {
            var improved = false
            if (folded < a) {
                val up = folded * 2
                if (abs(a - up) < gap) {
                    folded = up
                    gap = abs(a - folded)
                    improved = true
                }
            } else if (folded > a) {
                val down = folded / 2
                if (abs(a - down) < gap) {
                    folded = down
                    gap = abs(a - folded)
                    improved = true
                }
            }
            if (!improved) break
        }
        val norm = gap / BPM_SPREAD
        return norm.coerceIn(0.0, 1.0)
    }

    /** 0 if both land in the same top-level [Genre] category, else 1. */
    fun genreDistance(a: String?, b: String?): Double =
        if (Genre.category(a) == Genre.category(b)) 0.0 else 1.0

    /** 1 − Jaccard(lowercased keyword sets). Either set empty/null → 0.5 (neutral). */
    fun sentimentDistance(a: List<String>?, b: List<String>?): Double {
        if (a.isNullOrEmpty() || b.isNullOrEmpty()) return 0.5
        val sa = a.mapTo(HashSet()) { it.lowercase().trim() }
        val sb = b.mapTo(HashSet()) { it.lowercase().trim() }
        val inter = sa.count { it in sb }
        val union = sa.size + sb.size - inter
        if (union == 0) return 0.5
        return 1.0 - inter.toDouble() / union.toDouble()
    }

    /** 0 if the same artist (case-insensitive, trimmed) and non-empty, else 1. */
    fun artistDistance(a: String?, b: String?): Double {
        val na = (a ?: "").lowercase().trim()
        val nb = (b ?: "").lowercase().trim()
        return if (na == nb && na.isNotEmpty()) 0.0 else 1.0
    }

    /**
     * Weighted harmonic distance between two songs, in [0,1]. Nil axes dropped +
     * remaining weights renormalized; all-nil/zero-weight → 0.5. Genre is passed
     * explicitly because the native catalog carries it on the album.
     */
    fun harmonicDistance(
        a: IndexSong,
        b: IndexSong,
        genreA: String? = null,
        genreB: String? = null,
        weights: HarmonicWeights = DEFAULT_WEIGHTS,
    ): Double {
        val camRaw = camelotDistance(a.camelot, b.camelot)
        val bpmRaw = bpmDistance(a.bpm, b.bpm)

        val axes = listOf(
            weights.key to camRaw?.let { it / MAX_CAMELOT_STEPS },
            weights.bpm to bpmRaw,
            weights.genre to genreDistance(genreA, genreB),
            weights.artist to artistDistance(a.artist, b.artist),
            weights.sentiment to sentimentDistance(a.sentimentKeywords, b.sentimentKeywords),
        )

        var weighted = 0.0
        var activeWeight = 0.0
        for ((weight, dist) in axes) {
            if (dist == null || !dist.isFinite() || weight <= 0) continue
            weighted += weight * dist
            activeWeight += weight
        }
        if (activeWeight == 0.0) return 0.5
        return (weighted / activeWeight).coerceIn(0.0, 1.0)
    }
}

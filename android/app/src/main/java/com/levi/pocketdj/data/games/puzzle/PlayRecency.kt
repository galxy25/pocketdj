package com.levi.pocketdj.data.games.puzzle

import kotlin.math.max
import kotlin.math.pow

/**
 * THE one place that answers "how recently was this song played?" — port of iOS
 * `State/PlayRecency.swift`. A SEPARATE axis from lifetime play count (the two are
 * only r = 0.45 correlated on the owner's library), and a smooth exponential decay
 * rather than a "last 30 days" cliff (the median played song was last played 5.8
 * years ago; a cliff scores 99.5% of the library identically zero).
 */
object PlayRecency {
    /** Half-life of the recency signal: a play is worth half as much two years later. */
    const val HALF_LIFE_DAYS: Double = 730.0

    /**
     * How far a full-strength recency signal may multiply a Gem Collector pool weight.
     * `1 + 8·r` tops out at ×9, matched to the play-count bias's dynamic range.
     */
    const val GAIN: Double = 8.0

    private const val MS_PER_DAY = 86_400_000.0

    /**
     * Exponential decay by age in days: 1.0 at age 0, 0.5 at one half-life. A NEGATIVE
     * age (future stamp / clock skew) clamps to 1.0; a non-finite age scores 0.
     */
    fun decay(ageDays: Double): Double {
        if (!ageDays.isFinite()) return 0.0
        return 0.5.pow(max(0.0, ageDays) / HALF_LIFE_DAYS)
    }

    /**
     * 0…1 recency of one song from its last-played stamp (epoch ms). ABSENT IS ZERO
     * (never played), not unknown.
     */
    fun score(lastPlayedMs: Double?, nowMs: Double): Double {
        if (lastPlayedMs == null || lastPlayedMs <= 0 || !lastPlayedMs.isFinite() || !nowMs.isFinite()) return 0.0
        return decay((nowMs - lastPlayedMs) / MS_PER_DAY)
    }
}

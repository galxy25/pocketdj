package com.levi.pocketdj.data.motion

import com.levi.pocketdj.data.pockets.wheel.MotionToken

/** One activity stretch. [activity] is a [MotionToken]; [confidence] is 0 low / 1 medium / 2 high (CoreMotion scale). */
data class MotionSegment(val startMs: Long, val endMs: Long, val activity: String, val confidence: Int)

/** Port of iOS `MotionSettle` (Location/MotionActivityProviding.swift): the pure retroactive settle rule. */
object MotionSettle {
    /** A play younger than this may still be in progress / its segments not yet written. */
    const val MIN_AGE_MS: Double = 2 * 60_000.0
    /** Stop asking a little before the 7-day timeline edge. */
    const val HORIZON_MS: Double = 6.5 * 86_400_000
    /** Duration used when the catalog knows no length. */
    const val FALLBACK_DURATION_MS: Double = 180_000.0
    /** Segments below this confidence say nothing (medium = 1). Android transitions carry no confidence: stored as medium. */
    const val MIN_CONFIDENCE = 1

    data class Play(val id: String, val playedAtMs: Double, val durationMs: Double)

    /** Audible window: catalog length x played fraction when known, else the whole length, else 3 min; never under 30 s. */
    fun duration(lengthMs: Int?, listenedFraction: Double?): Double {
        if (lengthMs == null || lengthMs <= 0) return FALLBACK_DURATION_MS
        val f = (listenedFraction ?: 1.0).coerceIn(0.0, 1.0)
        return maxOf(30_000.0, lengthMs.toDouble() * (if (f > 0) f else 1.0))
    }

    fun isEligible(playedAtMs: Double, durationMs: Double, nowMs: Double): Boolean {
        val age = nowMs - playedAtMs
        return age >= MIN_AGE_MS && age <= HORIZON_MS && playedAtMs + durationMs <= nowMs + 1
    }

    /**
     * Winning activity per eligible play: most overlap seconds among segments with confidence >= medium; ties go to the
     * more active state (running > walking > cycling > automotive > stationary). No qualifying overlap = no entry.
     */
    fun settle(plays: List<Play>, segments: List<MotionSegment>, nowMs: Double): Map<String, String> {
        val usable = segments.filter { it.confidence >= MIN_CONFIDENCE && it.endMs > it.startMs }.sortedBy { it.startMs }
        if (usable.isEmpty()) return emptyMap()
        val out = HashMap<String, String>()
        for (p in plays) {
            if (!isEligible(p.playedAtMs, p.durationMs, nowMs)) continue
            val lo = p.playedAtMs / 1000
            val hi = (p.playedAtMs + p.durationMs) / 1000
            val overlap = HashMap<String, Double>()
            for (s in usable) {
                val a = maxOf(lo, s.startMs / 1000.0)
                val b = minOf(hi, s.endMs / 1000.0)
                if (b > a) overlap[s.activity] = (overlap[s.activity] ?: 0.0) + (b - a)
            }
            val best = overlap.entries.minWithOrNull(
                compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { MotionToken.activityRank(it.key) },
            ) ?: continue
            out[p.id] = best.key
        }
        return out
    }

    /** "What am I doing now": the latest qualifying segment's activity, or null. */
    fun current(segments: List<MotionSegment>): String? =
        segments.filter { it.confidence >= MIN_CONFIDENCE }.maxByOrNull { it.endMs }?.activity
}

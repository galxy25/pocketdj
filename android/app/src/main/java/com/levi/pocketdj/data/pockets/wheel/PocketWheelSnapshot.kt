package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.recs.SimilarityFamilies
import kotlinx.serialization.Serializable
import kotlin.math.exp

/**
 * One wheel cell: what listening at (hour, weekday, mode) looks like, built from local play history.
 * iOS `PocketMoment` shape (the device-local cache round-trips it).
 */
@Serializable
data class PocketMoment(
    val key: PocketMomentKey,
    /** Decayed, kernel-weighted count of NON-skipped plays. */
    val plays: Double = 0.0,
    /** Decayed, kernel-weighted count of skips (run skips at 1x). */
    val skips: Double = 0.0,
    /** Distinct local dates contributing DIRECTLY (not via smoothing), non-skipped. */
    val distinctDays: Int = 0,
    val directPlays: Int = 0,
    val directSkips: Int = 0,
    /** Collection weights from non-skipped plays (L1-normalised, top 8). */
    val collections: Map<String, Double> = emptyMap(),
    /** argmax of [collections] when its share >= 0.25, else null ("mixed"). */
    val dominantCollectionId: String? = null,
    val artists: Map<String, Double> = emptyMap(),
    val genres: Map<String, Double> = emptyMap(),
    val bpmLo: Double? = null,
    val bpmHi: Double? = null,
    val eraLo: Double? = null,
    val eraHi: Double? = null,
    val timbreCentroid: Map<String, Double>? = null,
    val timbreSpread: Double? = null,
    val timbreVectors: Int? = null,
    /** place/trip key distribution ("none" included). */
    val ctx: Map<String, Double> = emptyMap(),
    /** songId -> strength (played through here), top 40. */
    val seeds: Map<String, Double> = emptyMap(),
    val cloudPatternIds: List<String> = emptyList(),
    val lastSeenMs: Double = 0.0,
) {
    val confidence: Double get() = 1 - exp(-plays / 6)
    val skipRate: Double get() = if (plays + skips > 0) skips / (plays + skips) else 0.0
    val isRecurring: Boolean get() = distinctDays >= 2
    val bpmBand: ClosedFloatingPointRange<Double>?
        get() {
            val lo = bpmLo ?: return null
            val hi = bpmHi ?: return null
            return if (hi >= lo) lo..hi else null
        }
    val era: SimilarityFamilies.EraWindow?
        get() = if (eraLo != null && eraHi != null) SimilarityFamilies.EraWindow(eraLo, eraHi) else null
    val timbre: SimilarityFamilies.TimbreProfile?
        get() = if (timbreCentroid != null && timbreSpread != null) {
            SimilarityFamilies.TimbreProfile(timbreCentroid, timbreSpread, timbreVectors ?: 0)
        } else {
            null
        }
}

/** The whole wheel: every non-empty moment plus the colour/legend aggregates. */
@Serializable
data class PocketWheelSnapshot(
    val schemaVersion: Int = 1,
    val builtAtMs: Double = 0.0,
    /** `PlayHistoryStore` revision this was built from (cache validity). */
    val historyRevision: Int = -1,
    val moments: List<PocketMoment> = emptyList(),
    /** Collection id -> display name (local only). */
    val collectionNames: Map<String, String> = emptyMap(),
    /** Every collection dominant in >= 1 cell, by global dominance DESCENDING — the palette's seating order. */
    val dominanceOrder: List<String> = emptyList(),
    /** Legend: collection -> share of the week's (decayed) plays in cells it dominates. */
    val weekShare: Map<String, Double> = emptyMap(),
    /** Non-skipped, non-game plays the build saw (cold-start tiers). */
    val totalDirectPlays: Int = 0,
) {
    val isEmpty: Boolean get() = moments.isEmpty()

    fun index(): Map<PocketMomentKey, PocketMoment> {
        val out = LinkedHashMap<PocketMomentKey, PocketMoment>()
        for (m in moments) if (m.key !in out) out[m.key] = m
        return out
    }

    fun name(id: String?): String? = id?.let { collectionNames[it] }
}

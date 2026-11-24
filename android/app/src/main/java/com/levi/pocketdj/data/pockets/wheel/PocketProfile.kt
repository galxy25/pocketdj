package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.recs.SimilarityFamilies
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * What a pocket run is built FROM — one value for every cold-start tier so the run planner has no special
 * cases (iOS `PocketProfile`). Persisted in the run file in the iOS shape.
 */
@Serializable
data class PocketProfile(
    val tier: Tier,
    /** The winning moment — null for blended / cloud / cold profiles. */
    val key: PocketMomentKey? = null,
    /** Every moment that contributed (the tuning fold reads these). */
    val momentKeys: List<PocketMomentKey> = emptyList(),
    val caption: String,
    val detail: String,
    val collections: Map<String, Double> = emptyMap(),
    val artists: Map<String, Double> = emptyMap(),
    val genres: Map<String, Double> = emptyMap(),
    val bpmLo: Double? = null,
    val bpmHi: Double? = null,
    val eraLo: Double? = null,
    val eraHi: Double? = null,
    val timbreCentroid: Map<String, Double>? = null,
    val timbreSpread: Double? = null,
    val timbreVectors: Int? = null,
    /** songId -> strength. */
    val seeds: Map<String, Double> = emptyMap(),
    /** The cloud's `collectionCandidates` (songId -> strength). */
    val candidateBoost: Map<String, Double> = emptyMap(),
    /** The listening mode the profile is FOR (`mix` plays through Mix Auto-DJ). */
    val mode: PocketMode? = null,
) {
    @Serializable
    enum class Tier {
        @SerialName("rich") RICH,
        @SerialName("neighbourhood") NEIGHBOURHOOD,
        @SerialName("cloud") CLOUD,
        @SerialName("history") HISTORY,
        @SerialName("empty") EMPTY,
    }

    /** Highest weight wins; ties go to the smaller id (deterministic). */
    val dominantCollectionId: String?
        get() = collections.entries.minWithOrNull(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })?.key

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

    companion object {
        /** "Potential · 23 plays" (iOS `PocketBestMatch.detail`; P2-POC-6 may delegate here). */
        fun detail(collectionId: String?, plays: Int, names: Map<String, String>): String {
            val name = collectionId?.let { names[it] } ?: "Mixed"
            return "$name · $plays ${if (plays == 1) "play" else "plays"}"
        }

        /** One moment as a profile (iOS `PocketProfile.from(moment:names:tier:)`). */
        fun from(moment: PocketMoment, names: Map<String, String>, tier: Tier = Tier.RICH): PocketProfile = PocketProfile(
            tier = tier, key = moment.key, momentKeys = listOf(moment.key), caption = moment.key.shortLabel,
            detail = detail(moment.dominantCollectionId, moment.directPlays, names),
            collections = moment.collections, artists = moment.artists, genres = moment.genres,
            bpmLo = moment.bpmLo, bpmHi = moment.bpmHi, eraLo = moment.eraLo, eraHi = moment.eraHi,
            timbreCentroid = moment.timbreCentroid, timbreSpread = moment.timbreSpread, timbreVectors = moment.timbreVectors,
            seeds = moment.seeds, mode = moment.key.mode,
        )
    }
}

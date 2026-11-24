package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.pockets.ListeningPocketCollectionCandidate
import com.levi.pocketdj.data.pockets.ListeningPocketDim
import com.levi.pocketdj.data.pockets.ListeningPocketFeature
import com.levi.pocketdj.data.pockets.ListeningPocketMembershipWeight
import com.levi.pocketdj.data.pockets.ListeningPocketNumeric
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

        /** iOS `PocketProfile.from(moment:names:tier:)` under the roadmap's name. */
        fun fromMoment(moment: PocketMoment, names: Map<String, String>, tier: Tier = Tier.RICH): PocketProfile = from(moment, names, tier)

        /**
         * One cloud listening pocket / pattern (History > Pockets > List) as a run profile (iOS `from(listening:...)`):
         * Play starts a DERIVED run from it - its songs are seeds, its collections / genres / artists / tempo / era
         * steer the pool - not a replay of the exact members.
         */
        fun fromListening(
            title: String,
            features: List<ListeningPocketFeature>,
            numeric: Map<String, ListeningPocketNumeric>,
            membership: List<ListeningPocketMembershipWeight>,
            candidates: List<ListeningPocketCollectionCandidate> = emptyList(),
            songIds: List<String>,
        ): PocketProfile {
            val collections = HashMap<String, Double>()
            val artists = HashMap<String, Double>()
            val genres = HashMap<String, Double>()
            for (m in membership) if (m.weight > 0) collections[m.collectionId] = (collections[m.collectionId] ?: 0.0) + m.weight
            for (f in features) {
                if (f.score <= 0) continue
                when (f.kind) {
                    ListeningPocketDim.COLLECTION -> if (membership.isEmpty()) collections[f.value] = (collections[f.value] ?: 0.0) + f.score
                    ListeningPocketDim.ARTIST -> artists[f.value] = (artists[f.value] ?: 0.0) + f.score
                    ListeningPocketDim.GENRE -> genres[f.value] = (genres[f.value] ?: 0.0) + f.score
                    else -> Unit
                }
            }
            val band = InThePocketScorer.usableNumeric(numeric["bpm"])?.let { InThePocketScorer.normalizedBand(it.lo, it.hi) }
            var eraLo: Double? = null
            var eraHi: Double? = null
            InThePocketScorer.usableNumeric(numeric["year"])?.let { y ->
                val mid = (y.lo + y.hi) / 2
                eraLo = minOf(y.lo, mid - 2); eraHi = maxOf(y.hi, mid + 2)
            }
            val boost = HashMap<String, Double>()
            for (c in candidates) if (c.score > 0) boost[c.songId] = (boost[c.songId] ?: 0.0) + c.score
            val seeds = LinkedHashMap<String, Double>()
            for (id in songIds) if (id !in seeds) seeds[id] = 1.0
            return PocketProfile(
                tier = Tier.CLOUD, caption = title, detail = "A fresh mix from this pocket",
                collections = PocketMomentEngine.topNormalized(collections, 8),
                artists = PocketMomentEngine.topNormalized(artists, 8),
                genres = PocketMomentEngine.topNormalized(genres, 8),
                bpmLo = band?.start, bpmHi = band?.endInclusive, eraLo = eraLo, eraHi = eraHi,
                seeds = seeds, candidateBoost = boost,
            )
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

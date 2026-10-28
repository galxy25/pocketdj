package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.recs.RecAudioShortlist
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer.CollectionInfo
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer.Input
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer.Profile
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer.Song
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.sqrt

/**
 * IN THE POCKET × COLLECTIONS — the membership half of the scorer (port of
 * InThePocketMembership.swift; docs/design/pockets-collections.md). PURE.
 *
 * m(s) — a song's membership vector, collection id → weight: HARD 1.0 for a (flattened) member
 * × the add-recency scale `0.5 + 0.5·e^(−ageDays/45)` (unknown add ⇒ 0.75); SOFT for a
 * NON-member `0.6·sim(s, centroid(c))` when sim ≥ 0.55. The PROFILE vector comes from the
 * cloud's pattern/pocket membership weighted by context match, else this device's contextual
 * plays, then is nudged by the live session (last hour).
 */
class MembershipIndex(input: Input) {
    val byId: Map<String, CollectionInfo>

    /** songId → the collections it is a hard member of. */
    val memberOf: Map<String, List<String>>

    init {
        val b = LinkedHashMap<String, CollectionInfo>()
        val m = HashMap<String, MutableList<String>>()
        for (c in input.collections) {
            if (b.containsKey(c.id)) continue
            b[c.id] = c
            for (s in c.songIds) m.getOrPut(s) { mutableListOf() }.add(c.id)
        }
        byId = b
        memberOf = m
    }

    val isEmpty: Boolean get() = byId.isEmpty()
    fun name(id: String?): String? = id?.let { byId[it]?.name }
    fun collectionsOf(songId: String): Set<String> = memberOf[songId]?.toSet() ?: emptySet()

    /** Hard membership of [songId] as of [refMs] (add-recency scaled). */
    fun hard(songId: String, refMs: Double): Map<String, Double> {
        val ids = memberOf[songId] ?: return emptyMap()
        val out = LinkedHashMap<String, Double>()
        for (id in ids) out[id] = InThePocketMembership.addScale(byId[id]?.addedAtMs?.get(songId), refMs)
        return out
    }
}

/** What a collection sounds like, from its members the catalog can describe. */
data class Centroid(
    val genreShare: Map<String, Double>,
    val bpmMedian: Double?,
    /** Camelot code (uppercased) → members on it. */
    val camelotCounts: Map<String, Int>,
    val keyed: Int,
    /** Moods carried by ≥ 20 % of the members (≤ 8). */
    val moods: Set<String>,
) {
    companion object {
        fun of(c: CollectionInfo, catalog: Map<String, Song>): Centroid? {
            val songs = c.songIds.mapNotNull { catalog[it] }
            if (songs.size < InThePocketScorer.MIN_CENTROID_MEMBERS) return null
            val g = HashMap<String, Double>()
            var genred = 0.0
            val bpms = mutableListOf<Double>()
            val keys = HashMap<String, Int>()
            var keyed = 0
            val moodCounts = HashMap<String, Int>()
            for (s in songs) {
                s.genre?.let { g.merge(it, 1.0, Double::plus); genred += 1 }
                InThePocketScorer.foldBpm(s.bpm)?.let { bpms.add(it) }
                s.camelot?.uppercase()?.takeIf { it.isNotEmpty() }?.let { keys.merge(it, 1, Int::plus); keyed += 1 }
                for (m in s.moods.toSet()) moodCounts.merge(m, 1, Int::plus)
            }
            bpms.sort()
            val minMood = max(1, kotlin.math.ceil(songs.size * 0.2).toInt())
            val moods = moodCounts.filter { it.value >= minMood }.entries
                .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
                .take(8).map { it.key }.toSet()
            return Centroid(
                genreShare = if (genred > 0) g.mapValues { it.value / genred } else emptyMap(),
                bpmMedian = if (bpms.isEmpty()) null else bpms[bpms.size / 2],
                camelotCounts = keys, keyed = keyed, moods = moods,
            )
        }
    }
}

/**
 * cosine(m(s), profile) for candidates. m(s) is hard over EVERY collection the song is in and
 * soft over the profile's collections only (the only ones the dot product can see).
 */
class MembershipPull private constructor(
    private val profile: Map<String, Double>,
    private val profileNorm: Double,
    private val index: MembershipIndex,
    private val centroids: Map<String, Centroid>,
) {
    /** The membership vector the pull uses for [s] (hard everywhere, soft on the profile). */
    fun vector(s: Song, nowMs: Double): Map<String, Double> {
        val m = LinkedHashMap(index.hard(s.id, nowMs))
        for ((id, cen) in centroids) {
            if (m.containsKey(id)) continue
            val sim = InThePocketMembership.similarity(s, cen)
            if (sim >= InThePocketScorer.SOFT_MIN) m[id] = InThePocketScorer.SOFT_MAX * sim
        }
        return m
    }

    /** (cosine, the profile collection that contributed most) — null when m(s) is empty. */
    fun cosine(s: Song, nowMs: Double): Pair<Double, String?>? {
        val m = vector(s, nowMs)
        if (m.isEmpty()) return null
        val norm = sqrt(m.values.sumOf { it * it })
        if (norm <= 0) return null
        var dot = 0.0
        var best: Pair<String, Double>? = null
        for ((id, p) in profile) {
            val w = m[id] ?: continue
            dot += p * w
            val b = best
            if (b == null || p * w > b.second || (p * w == b.second && id < b.first)) best = id to p * w
        }
        if (dot <= 0) return null
        return dot / (norm * profileNorm) to best?.first
    }

    companion object {
        fun create(profile: Map<String, Double>, index: MembershipIndex, input: Input): MembershipPull? {
            if (profile.isEmpty() || index.isEmpty) return null
            val norm = sqrt(profile.values.sumOf { it * it })
            if (norm <= 0) return null
            val cs = HashMap<String, Centroid>()
            for (id in profile.keys) {
                val c = index.byId[id] ?: continue
                Centroid.of(c, input.catalog)?.let { cs[id] = it }
            }
            return MembershipPull(profile, norm, index, cs)
        }
    }
}

object InThePocketMembership {

    /** `0.5 + 0.5·e^(−ageDays/45)` with ageDays = (refMs − addAt) clamped ≥ 0; unknown ⇒ 0.75. */
    fun addScale(addedAtMs: Double?, refMs: Double): Double {
        val a = addedAtMs ?: return InThePocketScorer.UNKNOWN_ADD_SCALE
        val ageDays = max(0.0, refMs - a) / 86_400_000
        return 0.5 + 0.5 * exp(-ageDays / InThePocketScorer.ADD_HALF_LIFE_DAYS)
    }

    /** L1-normalised, top 12 kept (ties → id), weights rounded to 1e-4. */
    fun normalizeMembership(m: Map<String, Double>): Map<String, Double> {
        val top = m.entries.filter { it.value > 0 && it.value.isFinite() }
            .sortedWith(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })
            .take(InThePocketScorer.MEMBERSHIP_TOP)
        val total = top.sumOf { it.value }
        if (total <= 0) return emptyMap()
        val out = LinkedHashMap<String, Double>()
        for (e in top) out[e.key] = roundHalfAway(e.value / total * 10_000) / 10_000
        return out
    }

    /**
     * Fill `profile.membership` when the cloud gave none (local contextual plays), then nudge it
     * with the live session. No collections on this device ⇒ untouched (parity).
     */
    fun applyMembership(profileIn: Profile, input: Input, index: MembershipIndex): Profile {
        if (index.isEmpty) return profileIn
        var profile = profileIn
        var centroids: Map<String, Centroid>? = null
        val softMemo = HashMap<String, Map<String, Double>>()

        fun soft(songId: String): Map<String, Double> {
            softMemo[songId]?.let { return it }
            val s = input.catalog[songId]
            if (s == null) { softMemo[songId] = emptyMap(); return emptyMap() }
            val cs = centroids ?: run {
                val built = LinkedHashMap<String, Centroid>()
                for ((id, c) in index.byId) Centroid.of(c, input.catalog)?.let { built[id] = it }
                centroids = built
                built
            }
            val mine = (index.memberOf[songId] ?: emptyList()).toSet()
            val out = LinkedHashMap<String, Double>()
            for ((id, cen) in cs) {
                if (id in mine) continue
                val sim = similarity(s, cen)
                if (sim >= InThePocketScorer.SOFT_MIN) out[id] = InThePocketScorer.SOFT_MAX * sim
            }
            softMemo[songId] = out
            return out
        }

        fun vector(songId: String, refMs: Double, withSoft: Boolean): Map<String, Double> {
            val m = LinkedHashMap(index.hard(songId, refMs))
            if (withSoft) for ((id, w) in soft(songId)) if (!m.containsKey(id)) m[id] = w
            return m
        }

        if (profile.membership.isEmpty()) {
            val kept = InThePocketScorer.contextBasis(input).second.filter { !it.isSkip }
            val counts = HashMap<String, Int>()
            for (p in kept) counts.merge(p.songId, 1, Int::plus)
            val softIds = counts.entries
                .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
                .take(InThePocketScorer.SOFT_BASIS_SONGS).map { it.key }.toSet()
            val acc = LinkedHashMap<String, Double>()
            for (p in kept) {
                // Membership is CURRENT and retroactive: recency is measured from NOW.
                for ((id, w) in vector(p.songId, input.nowMs, p.songId in softIds)) acc.merge(id, w, Double::plus)
            }
            profile = profile.copy(membership = normalizeMembership(acc))
        }
        // Live session pull: what's been playing this past hour says where the night is going.
        val since = input.nowMs - InThePocketScorer.LIVE_WINDOW_MS
        val live = LinkedHashMap<String, Double>()
        for (p in input.plays) {
            if (p.atMs >= since && p.atMs <= input.nowMs && !p.isSkip) {
                for ((id, w) in vector(p.songId, input.nowMs, true)) live.merge(id, w, Double::plus)
            }
        }
        val liveN = normalizeMembership(live)
        if (liveN.isEmpty()) return profile
        val blended = LinkedHashMap(profile.membership)
        for ((id, w) in liveN) blended.merge(id, InThePocketScorer.LIVE_WEIGHT * w, Double::plus)
        return profile.copy(membership = normalizeMembership(blended))
    }

    /**
     * The round's `collection` targets (top 3, strongest = 1) — recorded so round learning can
     * re-weight collections. Labels are LOCAL names (never uploaded).
     */
    fun collectionTargets(membership: Map<String, Double>, index: MembershipIndex): List<InThePocketTarget> {
        val top = membership.entries
            .sortedWith(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })
            .take(InThePocketScorer.MAX_COLLECTION_TARGETS)
        val m = top.firstOrNull()?.value ?: return emptyList()
        if (m <= 0) return emptyList()
        return top.map {
            InThePocketTarget("collection", it.key, index.name(it.key) ?: "Your collection", round3(it.value / m))
        }
    }

    /**
     * sim(s, centroid) ∈ [0, 1]: the weighted blend over the dims BOTH sides have; 0 when they
     * share too little to judge (< 0.45 of the weight).
     */
    fun similarity(s: Song, c: Centroid): Double {
        var sum = 0.0
        var wsum = 0.0
        val g = s.genre
        if (g != null && c.genreShare.isNotEmpty()) {
            sum += InThePocketScorer.SIM_GENRE_WEIGHT * (c.genreShare[g] ?: 0.0); wsum += InThePocketScorer.SIM_GENRE_WEIGHT
        }
        val b = InThePocketScorer.foldBpm(s.bpm)
        val med = c.bpmMedian
        if (b != null && med != null) {
            val d = b - med
            val sg = InThePocketScorer.SIM_BPM_SIGMA
            sum += InThePocketScorer.SIM_BPM_WEIGHT * exp(-(d * d) / (2 * sg * sg)); wsum += InThePocketScorer.SIM_BPM_WEIGHT
        }
        val k = s.camelot?.uppercase()
        if (k != null && k.isNotEmpty() && c.keyed > 0) {
            var near = 0
            for ((code, n) in c.camelotCounts) if (code == k || camelotAdjacent(code, k)) near += n
            sum += InThePocketScorer.SIM_CAMELOT_WEIGHT * near / c.keyed; wsum += InThePocketScorer.SIM_CAMELOT_WEIGHT
        }
        if (s.moods.isNotEmpty() && c.moods.isNotEmpty()) {
            val mine = s.moods.toSet()
            sum += InThePocketScorer.SIM_MOOD_WEIGHT * mine.intersect(c.moods).size.toDouble() / mine.union(c.moods).size.toDouble()
            wsum += InThePocketScorer.SIM_MOOD_WEIGHT
        }
        if (wsum < InThePocketScorer.SIM_MIN_COVERAGE) return 0.0
        return sum / wsum
    }

    fun camelotAdjacent(a: String, b: String): Boolean = RecAudioShortlist.camelotAdjacent(a, b)
}

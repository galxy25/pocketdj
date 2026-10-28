package com.levi.pocketdj.data.games.puzzle

import com.levi.pocketdj.data.catalog.IndexSong
import java.text.Normalizer
import java.util.Locale
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** One pool row: a song plus its multiplicative sampling weight. */
data class PuzzleCandidate(val song: IndexSong, val weight: Double)

/**
 * Gem Collector's LOCAL-FIRST similarity ranker — port of iOS `PuzzleSimilarity`
 * (default / non-balanced path only; the `SimilarityFamilies` balance mode belongs to
 * In Da Zone, not Gem Collector). Pure: no stores, safe off the main thread.
 *
 * Seven terms: artist, genre, year, lyric keywords, co-membership, co-play (decayed),
 * and candidate recency. The weights are RATIOS — [score] divides by the profile's
 * `availableWeight` (profile-level, never per-song, so missing metadata is never an
 * advantage). The cloud contributes a pure rank BONUS only.
 */
object PuzzleSimilarity {
    const val W_ARTIST = 0.30
    const val W_GENRE = 0.25
    const val W_YEAR = 0.15
    const val W_CO_MEMBER = 0.12
    const val W_LYRICS = 0.10
    const val W_CO_PLAY = 0.08
    const val W_RECENCY = 0.05

    /** How far toward 1.0 a top-ranked CLOUD hit may lift a song. */
    const val CLOUD_WEIGHT = 0.25

    /** Two plays this far apart count as "played together". */
    const val CO_PLAY_WINDOW_MS: Double = 30.0 * 60 * 1000
    const val CO_PLAY_SATURATION = 3.0

    /** `.strict` drops everything at or below this before the top-K. */
    const val STRICT_FLOOR = 0.15

    private const val MS_PER_DAY = 86_400_000.0

    /** What the union of the target collections LOOKS like. */
    data class TargetProfile(
        val artistShare: Map<String, Double> = emptyMap(),
        val maxArtistShare: Double = 0.0,
        val genreShare: Map<String, Double> = emptyMap(),
        val maxGenreShare: Double = 0.0,
        val yearMean: Double? = null,
        /** Floored at 8 when scoring. */
        val yearSigma: Double = 8.0,
        val keywordShare: Map<String, Double> = emptyMap(),
        val maxKeywordShare: Double = 0.0,
        val coMemberIds: Set<String> = emptySet(),
        /** songId → DECAYED strength of the co-play edge. */
        val coPlayWeight: Map<String, Double> = emptyMap(),
        val memberIds: Set<String> = emptySet(),
        /** The DENOMINATOR: sum of the weights of terms this PROFILE can speak. */
        val availableWeight: Double = 0.0,
    ) {
        /** No targets / nothing resolved ⇒ similarity is a no-op. */
        val isEmpty: Boolean get() = availableWeight <= 0
    }

    /** One play-log row for the co-play graph. */
    data class Play(val songId: String, val atMs: Double)

    /** Diacritic + case insensitive, trimmed, leading "the " stripped. */
    fun artistKey(artist: String): String {
        var s = Normalizer.normalize(artist, Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "")
            .lowercase(Locale.ROOT)
            .trim()
        if (s.startsWith("the ")) s = s.substring(4)
        return s
    }

    /**
     * Build the profile from the target collections' members.
     *
     * @param memberWeights optional per-member weight (null ⇒ every member counts 1, which
     *   is what Gem Collector passes).
     * @param hasRecency does this DEVICE know any last-played dates at all (round-level —
     *   decides whether [W_RECENCY] is in the denominator).
     */
    fun profile(
        targetMemberIds: List<List<String>>,
        songsById: Map<String, IndexSong>,
        genreBySongId: Map<String, String>,
        otherCollections: List<List<String>>,
        plays: List<Play>,
        hasRecency: Boolean = false,
        memberWeights: Map<String, Double>? = null,
        nowMs: Double = System.currentTimeMillis().toDouble(),
    ): TargetProfile {
        val members = HashSet<String>()
        for (ids in targetMemberIds) members.addAll(ids)
        if (members.isEmpty()) return TargetProfile()

        val artistCount = HashMap<String, Double>()
        val genreCount = HashMap<String, Double>()
        val years = ArrayList<Pair<Double, Double>>()
        val keywordCount = HashMap<String, Double>()
        var keywordBearers = 0.0
        var resolved = 0.0

        for (id in members) {
            val song = songsById[id] ?: continue
            // Floored: a 0/negative weight contributes nothing and could divide by zero.
            val w = max(0.0, memberWeights?.get(id) ?: 1.0)
            if (w <= 0) continue
            resolved += w
            artistCount.merge(artistKey(song.artist), w, Double::plus)
            genreBySongId[id]?.let { genreCount.merge(it, w, Double::plus) }
            song.year?.let { years += it.toDouble() to w }
            val kws = (song.sentimentKeywords ?: emptyList()).map { it.lowercase(Locale.ROOT) }
            if (kws.isNotEmpty()) {
                keywordBearers += w
                for (k in kws.toSet()) keywordCount.merge(k, w, Double::plus)
            }
        }
        // Not one target member resolves against this catalog ⇒ no profile.
        if (resolved <= 0) return TargetProfile()

        val artistShare = artistCount.mapValues { it.value / resolved }
        val genreShare = genreCount.mapValues { it.value / resolved }
        var yearMean: Double? = null
        var yearSigma = 8.0
        if (years.isNotEmpty()) {
            val wSum = years.sumOf { it.second }
            val mean = years.sumOf { it.first * it.second } / wSum
            yearMean = mean
            val variance = years.sumOf { it.second * (it.first - mean) * (it.first - mean) } / wSum
            yearSigma = max(8.0, sqrt(variance))
        }
        var keywordShare: Map<String, Double> = emptyMap()
        if (keywordBearers > 0) {
            // Top 20 only — descending by (share, key), a long tail is noise.
            keywordShare = keywordCount.mapValues { it.value / keywordBearers }.entries
                .sortedWith(compareByDescending<Map.Entry<String, Double>> { it.value }.thenByDescending { it.key })
                .take(20)
                .associate { it.key to it.value }
        }

        // Co-membership: any collection that is NOT a target and holds a target member.
        val targetSets = targetMemberIds.map { it.toSet() }
        val coMember = HashSet<String>()
        for (ids in otherCollections) {
            val set = ids.toSet()
            if (targetSets.any { it == set }) continue
            if (set.none { it in members }) continue
            for (x in set) if (x !in members) coMember += x
        }

        // Co-play: one sorted pass + binary search per event — O(E log M).
        val coPlay = HashMap<String, Double>()
        val memberPlayTimes = plays.filter { it.songId in members }.map { it.atMs }.sorted()
        if (memberPlayTimes.isNotEmpty()) {
            for (e in plays) {
                if (e.songId in members) continue
                if (nearestDistance(e.atMs, memberPlayTimes) <= CO_PLAY_WINDOW_MS) {
                    coPlay.merge(e.songId, PlayRecency.decay((nowMs - e.atMs) / MS_PER_DAY), Double::plus)
                }
            }
        }

        var w = 0.0
        if (artistShare.isNotEmpty()) w += W_ARTIST
        if (genreShare.isNotEmpty()) w += W_GENRE
        if (yearMean != null) w += W_YEAR
        if (keywordShare.isNotEmpty()) w += W_LYRICS
        if (coMember.isNotEmpty()) w += W_CO_MEMBER
        if (coPlay.isNotEmpty()) w += W_CO_PLAY
        if (hasRecency) w += W_RECENCY

        return TargetProfile(
            artistShare = artistShare,
            maxArtistShare = artistShare.values.maxOrNull() ?: 0.0,
            genreShare = genreShare,
            maxGenreShare = genreShare.values.maxOrNull() ?: 0.0,
            yearMean = yearMean,
            yearSigma = yearSigma,
            keywordShare = keywordShare,
            maxKeywordShare = keywordShare.values.maxOrNull() ?: 0.0,
            coMemberIds = coMember,
            coPlayWeight = coPlay,
            memberIds = members,
            availableWeight = w,
        )
    }

    /** Distance from [t] to the closest value in a SORTED list. */
    private fun nearestDistance(t: Double, sorted: List<Double>): Double {
        var lo = 0
        var hi = sorted.size
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (sorted[mid] < t) lo = mid + 1 else hi = mid
        }
        var best = Double.MAX_VALUE
        if (lo < sorted.size) best = min(best, abs(sorted[lo] - t))
        if (lo > 0) best = min(best, abs(t - sorted[lo - 1]))
        return best
    }

    /**
     * 0…1 similarity of one song to the profile. [cloudRank] is 0 for anything the cloud
     * did not name (the DEFAULT) — then the result is EXACTLY the local score. [recency] is
     * the song's 0…1 `PlayRecency` score, already computed by the caller.
     */
    fun score(
        song: IndexSong,
        profile: TargetProfile,
        genre: String?,
        cloudRank: Double = 0.0,
        recency: Double = 0.0,
    ): Double {
        val p = profile
        var local = 0.0
        if (p.artistShare.isNotEmpty()) {
            val share = p.artistShare[artistKey(song.artist)] ?: 0.0
            local += W_ARTIST * min(1.0, share / max(0.05, p.maxArtistShare))
        }
        if (p.genreShare.isNotEmpty() && p.maxGenreShare > 0) {
            val share = genre?.let { p.genreShare[it] } ?: 0.0
            local += W_GENRE * min(1.0, share / p.maxGenreShare)
        }
        val mean = p.yearMean
        val y = song.year
        if (mean != null && y != null) {
            local += W_YEAR * exp(-abs(y.toDouble() - mean) / max(8.0, p.yearSigma))
        }
        if (p.keywordShare.isNotEmpty() && p.maxKeywordShare > 0) {
            val hits = (song.sentimentKeywords ?: emptyList()).map { it.lowercase(Locale.ROOT) }.toSet()
                .mapNotNull { p.keywordShare[it] }
            if (hits.isNotEmpty()) local += W_LYRICS * min(1.0, hits.sum() / p.maxKeywordShare)
        }
        if (p.coMemberIds.isNotEmpty() && song.id in p.coMemberIds) local += W_CO_MEMBER
        if (p.coPlayWeight.isNotEmpty()) {
            val n = p.coPlayWeight[song.id] ?: 0.0
            if (n > 0) local += W_CO_PLAY * min(1.0, n / CO_PLAY_SATURATION)
        }
        if (recency > 0) local += W_RECENCY * min(1.0, recency)
        val normalized = min(1.0, max(0.0, if (p.availableWeight > 0) local / p.availableWeight else 0.0))
        // The cloud is a pure BONUS: it can only RAISE a score, and rank 0 is an exact identity.
        if (cloudRank <= 0) return normalized
        return min(1.0, normalized + CLOUD_WEIGHT * min(1.0, cloudRank) * (1 - normalized))
    }

    /**
     * Restrict [candidates] to the songs most similar to the profile, keeping the existing
     * soft weights as the WITHIN-shortlist ordering. Off / empty profile / empty candidates
     * returns the SAME list object. A starvation guard refills a thin shortlist so a
     * similarity setting can never empty a round.
     */
    fun shortlist(
        candidates: List<PuzzleCandidate>,
        profile: TargetProfile,
        genreBySongId: Map<String, String>,
        cloudRanks: Map<String, Double> = emptyMap(),
        recencies: Map<String, Double> = emptyMap(),
        mode: PuzzleSettings.Similarity,
        wanted: Int,
    ): List<PuzzleCandidate> {
        val p = profile
        if (mode == PuzzleSettings.Similarity.OFF || p.isEmpty || candidates.isEmpty()) return candidates

        val floor = if (mode == PuzzleSettings.Similarity.STRICT) STRICT_FLOOR else 0.0
        class Scored(val index: Int, val sim: Double)
        val scored = ArrayList<Scored>(min(candidates.size, 4096))
        for ((i, c) in candidates.withIndex()) {
            val s = score(
                c.song, p, genreBySongId[c.song.id],
                cloudRank = cloudRanks[c.song.id] ?: 0.0,
                recency = recencies[c.song.id] ?: 0.0,
            )
            if (s > floor) scored += Scored(i, s)
        }
        val k = max(400, 8 * max(1, wanted))
        // Deterministic order: sim desc, weight desc, recency desc, id asc.
        scored.sortWith { x, y ->
            if (x.sim != y.sim) return@sortWith y.sim.compareTo(x.sim)
            val a = candidates[x.index]
            val b = candidates[y.index]
            if (a.weight != b.weight) return@sortWith b.weight.compareTo(a.weight)
            val ra = recencies[a.song.id] ?: 0.0
            val rb = recencies[b.song.id] ?: 0.0
            if (ra != rb) return@sortWith rb.compareTo(ra)
            a.song.id.compareTo(b.song.id)
        }
        while (scored.size > k) scored.removeAt(scored.size - 1)

        // Re-weight INSIDE the shortlist: floor 0.25 keeps the round varied; ♥/play-count
        // weights survive multiplicatively.
        val out = ArrayList<PuzzleCandidate>(scored.size)
        for (s in scored) out += PuzzleCandidate(candidates[s.index].song, candidates[s.index].weight * (0.25 + s.sim))

        // STARVATION GUARD.
        val minimum = min(candidates.size, max(20, wanted / 2))
        if (out.size < minimum) {
            val taken = scored.mapTo(HashSet()) { it.index }
            val filler = candidates.withIndex()
                .filter { it.index !in taken }
                .sortedWith { x, y ->
                    if (x.value.weight != y.value.weight) return@sortedWith y.value.weight.compareTo(x.value.weight)
                    val ra = recencies[x.value.song.id] ?: 0.0
                    val rb = recencies[y.value.song.id] ?: 0.0
                    if (ra != rb) return@sortedWith rb.compareTo(ra)
                    x.value.song.id.compareTo(y.value.song.id)
                }
                .take(minimum - out.size)
                .map { PuzzleCandidate(it.value.song, it.value.weight) }
            out.addAll(filler)
        }
        return out
    }
}

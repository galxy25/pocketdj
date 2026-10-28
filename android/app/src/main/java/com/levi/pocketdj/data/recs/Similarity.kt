package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.games.puzzle.PlayRecency
import com.levi.pocketdj.data.games.puzzle.PuzzleSimilarity
import java.util.Locale
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The `PuzzleSimilarity.profile/score/familyScores` subset the For You zone uses, INCLUDING the
 * optional `balance:` family mode that the Gem Collector port (data/games/puzzle) deliberately
 * leaves out. Kept as a separate type for the same reason iOS keeps the family balance out of the
 * puzzle's default term list: passing no balance is byte-identical to the shipped seven-term
 * scorer, and the puzzle's rankings must not move.
 *
 * Term weights, artist keying and the recency decay are the puzzle port's own (single source).
 */
object Similarity {

    data class Play(val songId: String, val atMs: Double)

    data class TargetProfile(
        val artistShare: Map<String, Double> = emptyMap(),
        val maxArtistShare: Double = 0.0,
        val genreShare: Map<String, Double> = emptyMap(),
        val maxGenreShare: Double = 0.0,
        val yearMean: Double? = null,
        val yearSigma: Double = 8.0,
        val keywordShare: Map<String, Double> = emptyMap(),
        val maxKeywordShare: Double = 0.0,
        val musical: SimilarityFamilies.MusicalProfile = SimilarityFamilies.MusicalProfile(),
        val musicalCalibration: SimilarityFamilies.MusicalCalibration = SimilarityFamilies.MusicalCalibration(),
        /** Non-null ONLY in balance mode; null ⇒ the shipped seven-term weights apply. */
        val terms: SimilarityFamilies.TermWeights? = null,
        val coMemberIds: Set<String> = emptySet(),
        val coPlayWeight: Map<String, Double> = emptyMap(),
        val memberIds: Set<String> = emptySet(),
        val availableWeight: Double = 0.0,
    ) {
        val isEmpty: Boolean get() = availableWeight <= 0

        /** Round-level calibration of the musical neutral against the actual candidate pool. */
        fun calibrated(candidates: Iterable<IndexSong>): TargetProfile {
            if (terms == null || musical.isEmpty) return this
            return copy(
                musicalCalibration = SimilarityFamilies.calibrate(
                    candidates.map { SimilarityFamilies.BpmCamelot(it.bpm, it.camelot) }, musical,
                ),
            )
        }
    }

    private const val MS_PER_DAY = 86_400_000.0

    fun profile(
        targetMemberIds: List<List<String>>,
        songsById: Map<String, IndexSong>,
        genreBySongId: Map<String, String>,
        otherCollections: List<List<String>>,
        plays: List<Play>,
        hasRecency: Boolean = false,
        memberWeights: Map<String, Double>? = null,
        balance: SimilarityFamilies.Balance? = null,
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
        val musicalMembers = ArrayList<SimilarityFamilies.MusicalMember>()

        for (id in members) {
            val song = songsById[id] ?: continue
            val w = max(0.0, memberWeights?.get(id) ?: 1.0)
            if (!(w > 0)) continue
            resolved += w
            artistCount.merge(PuzzleSimilarity.artistKey(song.artist), w, Double::plus)
            genreBySongId[id]?.let { genreCount.merge(it, w, Double::plus) }
            song.year?.let { years.add(it.toDouble() to w) }
            val kws = (song.sentimentKeywords ?: emptyList()).map { it.lowercase(Locale.ROOT) }
            if (kws.isNotEmpty()) {
                keywordBearers += w
                for (k in kws.toSet()) keywordCount.merge(k, w, Double::plus)
            }
            if (balance != null && (song.bpm != null || song.camelot != null)) {
                musicalMembers.add(SimilarityFamilies.MusicalMember(song.bpm, song.camelot, w))
            }
        }
        if (!(resolved > 0)) return TargetProfile(memberIds = members)

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
        var keywordShare = emptyMap<String, Double>()
        if (keywordBearers > 0) {
            keywordShare = keywordCount.mapValues { it.value / keywordBearers }.entries
                .sortedWith { a, b -> if (a.value != b.value) b.value.compareTo(a.value) else b.key.compareTo(a.key) }
                .take(20).associate { it.key to it.value }
        }

        val coMember = HashSet<String>()
        val targetSets = targetMemberIds.map { it.toSet() }
        for (ids in otherCollections) {
            val set = ids.toSet()
            if (targetSets.any { it == set }) continue
            if (set.none { it in members }) continue
            coMember.addAll(set - members)
        }

        val coPlay = HashMap<String, Double>()
        val memberPlayTimes = plays.filter { it.songId in members }.map { it.atMs }.sorted()
        if (memberPlayTimes.isNotEmpty()) {
            for (e in plays) {
                if (e.songId in members) continue
                if (nearestDistance(e.atMs, memberPlayTimes) <= PuzzleSimilarity.CO_PLAY_WINDOW_MS) {
                    coPlay.merge(e.songId, PlayRecency.decay((nowMs - e.atMs) / MS_PER_DAY), Double::plus)
                }
            }
        }

        var musical = SimilarityFamilies.MusicalProfile()
        var terms: SimilarityFamilies.TermWeights? = null
        if (balance != null) {
            musical = SimilarityFamilies.musicalProfile(musicalMembers)
            terms = SimilarityFamilies.termWeights(
                balance,
                hasGenre = genreShare.isNotEmpty(),
                hasYear = yearMean != null,
                hasMusical = !musical.isEmpty,
            )
        }

        var w = 0.0
        if (terms != null) {
            if (artistShare.isNotEmpty()) w += terms.artist
            if (genreShare.isNotEmpty()) w += terms.genre
            if (yearMean != null) w += terms.year
            w += terms.musical
        } else {
            if (artistShare.isNotEmpty()) w += PuzzleSimilarity.W_ARTIST
            if (genreShare.isNotEmpty()) w += PuzzleSimilarity.W_GENRE
            if (yearMean != null) w += PuzzleSimilarity.W_YEAR
        }
        if (keywordShare.isNotEmpty()) w += PuzzleSimilarity.W_LYRICS
        if (coMember.isNotEmpty()) w += PuzzleSimilarity.W_CO_MEMBER
        if (coPlay.isNotEmpty()) w += PuzzleSimilarity.W_CO_PLAY
        if (hasRecency) w += PuzzleSimilarity.W_RECENCY

        return TargetProfile(
            artistShare = artistShare,
            maxArtistShare = artistShare.values.maxOrNull() ?: 0.0,
            genreShare = genreShare,
            maxGenreShare = genreShare.values.maxOrNull() ?: 0.0,
            yearMean = yearMean,
            yearSigma = yearSigma,
            keywordShare = keywordShare,
            maxKeywordShare = keywordShare.values.maxOrNull() ?: 0.0,
            musical = musical,
            terms = terms,
            coMemberIds = coMember,
            coPlayWeight = coPlay,
            memberIds = members,
            availableWeight = w,
        )
    }

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

    fun score(
        song: IndexSong,
        profile: TargetProfile,
        genre: String?,
        cloudRank: Double = 0.0,
        recency: Double = 0.0,
    ): Double {
        val p = profile
        var local = 0.0
        val tArtist = p.terms?.artist ?: PuzzleSimilarity.W_ARTIST
        val tGenre = p.terms?.genre ?: PuzzleSimilarity.W_GENRE
        val tYear = p.terms?.year ?: PuzzleSimilarity.W_YEAR
        if (p.artistShare.isNotEmpty()) {
            val share = p.artistShare[PuzzleSimilarity.artistKey(song.artist)] ?: 0.0
            local += tArtist * min(1.0, share / max(0.05, p.maxArtistShare))
        }
        if (p.genreShare.isNotEmpty() && p.maxGenreShare > 0) {
            val share = genre?.let { p.genreShare[it] } ?: 0.0
            local += tGenre * min(1.0, share / p.maxGenreShare)
        }
        val mean = p.yearMean
        val y = song.year
        if (mean != null && y != null) {
            local += tYear * exp(-abs(y.toDouble() - mean) / max(8.0, p.yearSigma))
        }
        val t = p.terms
        if (t != null && t.musical > 0) {
            local += t.musical * SimilarityFamilies.musicalFit(song.bpm, song.camelot, p.musical, p.musicalCalibration)
        }
        if (p.keywordShare.isNotEmpty() && p.maxKeywordShare > 0) {
            val hits = (song.sentimentKeywords ?: emptyList()).map { it.lowercase(Locale.ROOT) }.toSet()
                .mapNotNull { p.keywordShare[it] }
            if (hits.isNotEmpty()) local += PuzzleSimilarity.W_LYRICS * min(1.0, hits.sum() / p.maxKeywordShare)
        }
        if (p.coMemberIds.isNotEmpty() && song.id in p.coMemberIds) local += PuzzleSimilarity.W_CO_MEMBER
        if (p.coPlayWeight.isNotEmpty()) {
            val n = p.coPlayWeight[song.id] ?: 0.0
            if (n > 0) local += PuzzleSimilarity.W_CO_PLAY * min(1.0, n / PuzzleSimilarity.CO_PLAY_SATURATION)
        }
        if (recency > 0) local += PuzzleSimilarity.W_RECENCY * min(1.0, recency)
        val normalized = min(1.0, max(0.0, if (p.availableWeight > 0) local / p.availableWeight else 0.0))
        if (cloudRank <= 0) return normalized
        return min(1.0, normalized + PuzzleSimilarity.CLOUD_WEIGHT * min(1.0, cloudRank) * (1 - normalized))
    }

    /** The three family scores for one song (each null when the profile can't speak that field). */
    fun familyScores(song: IndexSong, profile: TargetProfile, genre: String?): SimilarityFamilies.Scores {
        val p = profile
        val artist = if (p.artistShare.isEmpty()) null
        else min(1.0, (p.artistShare[PuzzleSimilarity.artistKey(song.artist)] ?: 0.0) / max(0.05, p.maxArtistShare))
        val genreFit = if (p.genreShare.isEmpty() || p.maxGenreShare <= 0) null
        else min(1.0, (genre?.let { p.genreShare[it] } ?: 0.0) / p.maxGenreShare)
        val yearFit = p.yearMean?.let { mean ->
            song.year?.let { exp(-abs(it.toDouble() - mean) / max(8.0, p.yearSigma)) }
        }
        val musical = if (p.musical.isEmpty) null
        else SimilarityFamilies.musicalFit(song.bpm, song.camelot, p.musical, p.musicalCalibration)
        return SimilarityFamilies.scores(artist, genreFit, yearFit, musical)
    }
}

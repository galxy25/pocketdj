package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.games.puzzle.PuzzleSimilarity
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/** Port of RecNovelty: primary-artist cap key, artist familiarity/novelty, aux mix. */
object RecNovelty {

    fun primaryArtistKey(credit: String): String {
        val cut = primaryCredit(credit)
        return PuzzleSimilarity.artistKey(if (cut.isEmpty()) credit else cut)
    }

    private val wordSeparators = listOf("& ", "feat. ", "feat ", "featuring ", "ft. ", "ft ", "with ", "x ", "vs. ", "vs ")
    private const val THE = "the "

    /** Lowercased leading credit, cut at the first list/collab separator. */
    fun primaryCredit(credit: String): String {
        val s = credit.lowercase()
        if (s.isEmpty()) return credit
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == ',') {
                var j = i + 1
                while (j < s.length && s[j] == ' ') j++
                if (!s.startsWith(THE, j)) return s.substring(0, i).trim()
                i = j
                continue
            }
            if (c == '/') return s.substring(0, i).trim()
            if (c == ' ') {
                for (w in wordSeparators) if (s.startsWith(w, i + 1)) return s.substring(0, i).trim()
            }
            i++
        }
        return s.trim()
    }

    class ArtistFamiliarity private constructor(
        private val byArtist: Map<String, Double>,
        val isLive: Boolean,
    ) {
        constructor() : this(emptyMap(), false)

        fun familiarity(artistKey: String): Double = if (isLive) (byArtist[artistKey] ?: 0.0) else 0.0
        fun novelty(artistKey: String): Double = if (isLive) 1 - (byArtist[artistKey] ?: 0.0) else 0.0

        fun reason(artistKey: String): String? {
            if (!isLive) return null
            val f = familiarity(artistKey)
            if (byArtist[artistKey] == null) return "An artist you've never played"
            if (f < 0.25) return "An artist you rarely play"
            return null
        }

        companion object {
            fun of(artistPlays: Map<String, Int>): ArtistFamiliarity {
                val maxPlays = artistPlays.values.maxOrNull() ?: 0
                if (maxPlays <= 0) return ArtistFamiliarity()
                val denom = log2(1.0 + maxPlays)
                if (denom <= 0) return ArtistFamiliarity(emptyMap(), true)
                val m = HashMap<String, Double>()
                for ((k, n) in artistPlays) if (n > 0) m[k] = min(1.0, log2(1.0 + n) / denom)
                return ArtistFamiliarity(m, true)
            }
        }
    }

    private fun log2(x: Double) = ln(x) / ln(2.0)

    fun artistFamiliarity(rows: Iterable<Pair<String, Int>>): ArtistFamiliarity {
        val totals = HashMap<String, Int>()
        for ((key, plays) in rows) if (plays > 0) totals[key] = (totals[key] ?: 0) + plays
        return ArtistFamiliarity.of(totals)
    }

    fun aux(
        novelty: Double, familiarity: Double, noveltyWeight: Double, familiarityWeight: Double, isLive: Boolean,
    ): Double {
        if (!isLive) return 0.0
        val den = noveltyWeight + familiarityWeight
        if (den <= 0) return 0.0
        return (noveltyWeight * novelty + familiarityWeight * familiarity) / den
    }
}

/** Port of RecComposition: artist cap, incumbent budget, sound-quota seating, diversity floor. */
object RecComposition {

    data class Row(
        val id: String,
        val capKey: String,
        val isIncumbent: Boolean,
        val rawGenre: String? = null,
        val isNewGenre: Boolean = false,
    )

    data class SoundAdmit(
        val rows: List<Row>,
        val maxShare: Double,
        val hardCap: Int,
        val firstIndex: Int = 4,
        val stride: Int = 5,
    )

    data class Diversity(val minDistinctRawGenres: Int, val maxSwaps: Int, val searchDepth: Int = 200)

    fun compose(
        rows: List<Row>,
        limit: Int,
        maxPerArtist: Int?,
        incumbentMaxShare: Double,
        soundAdmit: SoundAdmit? = null,
        diversity: Diversity? = null,
    ): List<String> {
        val cap = if ((maxPerArtist ?: 0) > 0) maxPerArtist!! else Int.MAX_VALUE

        // Phase 0 — target size of the plain capped walk.
        var n = 0
        val sizing = HashMap<String, Int>()
        for (r in rows) {
            if (n >= limit) break
            if (r.capKey.isNotEmpty()) {
                val used = sizing[r.capKey] ?: 0
                if (used >= cap) continue
                sizing[r.capKey] = used + 1
            }
            n++
        }
        val incumbentCap = min(n, max(0, floor(n * incumbentMaxShare).toInt()))

        val perArtist = HashMap<String, Int>()
        val out = ArrayList<Row>()
        val spill = ArrayList<Row>()
        var incumbents = 0
        fun blocked(r: Row) = r.capKey.isNotEmpty() && (perArtist[r.capKey] ?: 0) >= cap
        fun bump(key: String, d: Int) { perArtist[key] = (perArtist[key] ?: 0) + d }
        fun take(r: Row) { if (r.capKey.isNotEmpty()) bump(r.capKey, 1); out.add(r) }

        for (r in rows) {
            if (out.size >= n) break
            if (blocked(r)) continue
            if (r.isIncumbent && incumbents >= incumbentCap) { spill.add(r); continue }
            if (r.isIncumbent) incumbents++
            take(r)
        }
        for (r in spill) {
            if (out.size >= n) break
            if (blocked(r)) continue
            take(r)
        }

        // Phase S — seat the sound quota.
        val admitted = HashSet<String>()
        if (soundAdmit != null && soundAdmit.rows.isNotEmpty() && n > 0) {
            val quota = minOf(max(0, soundAdmit.hardCap), soundAdmit.rows.size,
                max(0, floor(n * soundAdmit.maxShare).toInt()))
            var seated = 0
            for (r in soundAdmit.rows) {
                if (seated >= quota) break
                if (blocked(r)) continue
                val idx = min(max(0, soundAdmit.firstIndex + seated * max(1, soundAdmit.stride)), out.size)
                out.add(idx, r)
                if (r.capKey.isNotEmpty()) bump(r.capKey, 1)
                if (r.isIncumbent) incumbents++
                admitted.add(r.id)
                seated++
            }
            if (out.size > n) {
                for (r in out.subList(n, out.size)) {
                    if (r.capKey.isNotEmpty()) bump(r.capKey, -1)
                    if (r.isIncumbent) incumbents--
                    admitted.remove(r.id)
                }
                while (out.size > n) out.removeAt(out.size - 1)
            }
        }

        // Phase D — diversity floor.
        val d = diversity
        if (d != null && d.minDistinctRawGenres > 0 && d.maxSwaps > 0 && out.isNotEmpty()) {
            val seatedIds = out.map { it.id }.toHashSet()
            var swaps = 0
            val reachable = rows.take(max(d.searchDepth, out.size))
            while (swaps < d.maxSwaps) {
                val counts = HashMap<String, Int>()
                for (r in out) r.rawGenre?.let { counts[it] = (counts[it] ?: 0) + 1 }
                if (counts.size >= d.minDistinctRawGenres) break
                val fresh = reachable.filter { r ->
                    val g = r.rawGenre
                    r.id !in seatedIds && g != null && counts[g] == null
                }
                val candidates = fresh.filter { it.isNewGenre } + fresh.filter { !it.isNewGenre }
                var swapped = false
                victims@ for (i in out.indices.reversed()) {
                    val victim = out[i]
                    if (victim.id in admitted) continue
                    val vg = victim.rawGenre
                    if (vg != null && (counts[vg] ?: 0) <= 1) continue
                    for (cand in candidates) {
                        if (cand.capKey.isNotEmpty()) {
                            val held = (perArtist[cand.capKey] ?: 0) - (if (victim.capKey == cand.capKey) 1 else 0)
                            if (held >= cap) continue
                        }
                        val inc = incumbents - (if (victim.isIncumbent) 1 else 0)
                        if (cand.isIncumbent && inc >= incumbentCap) continue
                        if (victim.capKey.isNotEmpty()) bump(victim.capKey, -1)
                        if (cand.capKey.isNotEmpty()) bump(cand.capKey, 1)
                        incumbents = inc + (if (cand.isIncumbent) 1 else 0)
                        seatedIds.remove(victim.id)
                        seatedIds.add(cand.id)
                        out[i] = cand
                        swaps++
                        swapped = true
                        break@victims
                    }
                }
                if (!swapped) break
            }
        }
        return out.map { it.id }
    }
}

/** Port of RecSoundAdmit: nearest-by-distance admission with per-decade/genre/artist skew caps. */
object RecSoundAdmit {
    const val MAX_PER_DECADE = 1
    const val MAX_PER_RAW_GENRE = 1
    const val MAX_PER_ARTIST = 1
    const val MIN_NET_FIT = 0.9
    const val TRIM_AT = 4096
    const val TRIM_TO = 1024

    data class Candidate(
        val id: String,
        val capKey: String,
        val decade: Int?,
        val rawGenre: String?,
        val distance: Double,
    )

    fun genreBucket(raw: String?): String? {
        if (raw == null) return null
        val s = raw.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        return s.ifEmpty { null }
    }

    private val byDistance = Comparator<Candidate> { a, b ->
        val c = a.distance.compareTo(b.distance)
        if (c != 0) c else a.id.compareTo(b.id)
    }

    fun select(pool: List<Candidate>, cap: Int): List<Candidate> {
        if (cap <= 0 || pool.isEmpty()) return emptyList()
        val byDecade = HashMap<Int, Int>()
        val byGenre = HashMap<String, Int>()
        val byArtist = HashMap<String, Int>()
        val out = ArrayList<Candidate>()
        for (c in pool.sortedWith(byDistance)) {
            if (out.size >= cap) break
            val d = c.decade ?: Int.MIN_VALUE
            val g = c.rawGenre ?: "\u0000none"
            val a = c.capKey.ifEmpty { c.id }
            if ((byDecade[d] ?: 0) >= MAX_PER_DECADE || (byGenre[g] ?: 0) >= MAX_PER_RAW_GENRE ||
                (byArtist[a] ?: 0) >= MAX_PER_ARTIST) continue
            byDecade[d] = (byDecade[d] ?: 0) + 1
            byGenre[g] = (byGenre[g] ?: 0) + 1
            byArtist[a] = (byArtist[a] ?: 0) + 1
            out.add(c)
        }
        return out
    }

    /** Keep the TRIM_TO nearest once the pool reaches TRIM_AT. */
    fun trimIfNeeded(pool: MutableList<Candidate>) {
        if (pool.size < TRIM_AT) return
        pool.sortWith(byDistance)
        while (pool.size > TRIM_TO) pool.removeAt(pool.size - 1)
    }
}

/** Port of RecAudioShortlist: nightly analysis shortlist alternating novelty and similarity. */
object RecAudioShortlist {

    const val DEFAULT_PER_NIGHT = 40
    const val GENRE_WEIGHT = 0.5
    const val BPM_WEIGHT = 0.3
    const val KEY_WEIGHT = 0.2
    const val BPM_TOLERANCE = 24.0

    data class Candidate(
        val songId: String,
        val artistKey: String,
        val genre: String? = null,
        val bpm: Double? = null,
        val camelot: String? = null,
    )

    data class RecentProfile(
        val genreShare: Map<String, Double> = emptyMap(),
        val meanBpm: Double? = null,
        val camelotCodes: Set<String> = emptySet(),
    ) {
        val isLive: Boolean get() = genreShare.isNotEmpty() || meanBpm != null || camelotCodes.isNotEmpty()

        companion object {
            fun from(recent: List<Candidate>): RecentProfile {
                val counts = HashMap<String, Double>()
                var genreVotes = 0.0
                var bpmSum = 0.0
                var bpmVotes = 0.0
                val codes = HashSet<String>()
                for (r in recent) {
                    r.genre?.takeIf { it.isNotEmpty() }?.let { counts[it] = (counts[it] ?: 0.0) + 1; genreVotes += 1 }
                    r.bpm?.takeIf { it > 0 }?.let { bpmSum += it; bpmVotes += 1 }
                    r.camelot?.takeIf { it.isNotEmpty() }?.let { codes.add(it.uppercase()) }
                }
                val share = if (genreVotes > 0) counts.mapValues { it.value / genreVotes } else emptyMap()
                return RecentProfile(share, if (bpmVotes > 0) bpmSum / bpmVotes else null, codes)
            }
        }
    }

    data class Inputs(
        val candidates: List<Candidate> = emptyList(),
        val analysedIds: Set<String> = emptySet(),
        val pendingIds: Set<String> = emptySet(),
        val recent: RecentProfile = RecentProfile(),
        val familiarity: RecNovelty.ArtistFamiliarity = RecNovelty.ArtistFamiliarity(),
        val perNight: Int = DEFAULT_PER_NIGHT,
        val perArtistCap: Int = 3,
    )

    fun similarity(c: Candidate, p: RecentProfile): Double {
        var sum = 0.0
        var den = 0.0
        if (p.genreShare.isNotEmpty()) {
            den += GENRE_WEIGHT
            val share = c.genre?.let { p.genreShare[it] }
            if (share != null) {
                val top = p.genreShare.values.maxOrNull() ?: 1.0
                sum += GENRE_WEIGHT * (if (top > 0) min(1.0, share / top) else 0.0)
            }
        }
        val mean = p.meanBpm
        if (mean != null && mean > 0) {
            den += BPM_WEIGHT
            val b = c.bpm
            if (b != null && b > 0) sum += BPM_WEIGHT * max(0.0, 1 - abs(b - mean) / BPM_TOLERANCE)
        }
        if (p.camelotCodes.isNotEmpty()) {
            den += KEY_WEIGHT
            val code = c.camelot?.uppercase()
            if (!code.isNullOrEmpty()) {
                if (code in p.camelotCodes) sum += KEY_WEIGHT
                else if (p.camelotCodes.any { camelotAdjacent(code, it) }) sum += KEY_WEIGHT * 0.6
            }
        }
        return if (den > 0) sum / den else 0.0
    }

    fun camelotAdjacent(a: String, b: String): Boolean {
        val x = parseCamelot(a) ?: return false
        val y = parseCamelot(b) ?: return false
        if (x.first == y.first && x.second != y.second) return true
        if (x.second != y.second) return false
        val d = abs(x.first - y.first)
        return d == 1 || d == 11
    }

    private fun parseCamelot(s: String): Pair<Int, Char>? {
        val t = s.trim().uppercase()
        val mode = t.lastOrNull() ?: return null
        if (mode != 'A' && mode != 'B') return null
        val n = t.dropLast(1).toIntOrNull() ?: return null
        if (n !in 1..12) return null
        return n to mode
    }

    /** Alternate most-novel-artist and most-similar picks; capped per artist; excludes analysed AND pending. */
    fun select(inputs: Inputs): List<String> {
        if (inputs.perNight <= 0) return emptyList()
        val eligible = inputs.candidates.filter { it.songId !in inputs.analysedIds && it.songId !in inputs.pendingIds }
        if (eligible.isEmpty()) return emptyList()

        val indexed = eligible.withIndex().toList()
        val byNovelty = indexed.sortedWith { a, b ->
            val na = inputs.familiarity.novelty(a.value.artistKey)
            val nb = inputs.familiarity.novelty(b.value.artistKey)
            if (na == nb) a.index.compareTo(b.index) else nb.compareTo(na)
        }.map { it.value }
        val bySimilarity = indexed.sortedWith { a, b ->
            val sa = similarity(a.value, inputs.recent)
            val sb = similarity(b.value, inputs.recent)
            if (sa == sb) a.index.compareTo(b.index) else sb.compareTo(sa)
        }.map { it.value }

        val picked = ArrayList<String>()
        val taken = HashSet<String>()
        val perArtist = HashMap<String, Int>()
        val cursors = intArrayOf(0, 0)

        fun take(list: List<Candidate>, which: Int): Boolean {
            while (cursors[which] < list.size) {
                val c = list[cursors[which]]
                cursors[which]++
                if (c.songId in taken) continue
                if ((perArtist[c.artistKey] ?: 0) >= inputs.perArtistCap) continue
                taken.add(c.songId)
                perArtist[c.artistKey] = (perArtist[c.artistKey] ?: 0) + 1
                picked.add(c.songId)
                return true
            }
            return false
        }

        var wantNovel = true
        while (picked.size < inputs.perNight) {
            val tookOne = if (wantNovel) take(byNovelty, 0) else take(bySimilarity, 1)
            if (!tookOne) {
                val other = if (wantNovel) take(bySimilarity, 1) else take(byNovelty, 0)
                if (!other) break
            }
            wantNovel = !wantNovel
        }
        return picked
    }
}

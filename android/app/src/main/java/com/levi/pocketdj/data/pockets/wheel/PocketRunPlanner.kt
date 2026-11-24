package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.games.inthepocket.SplitMix64
import com.levi.pocketdj.data.recs.SimilarityFamilies
import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The adaptive 100-song pocket run (iOS `PocketRunPlanner`): initial selection (pool -> score -> compose with quotas,
 * caps and a seeded tempo/key flow -> bench), the live re-plan's slot-wise replacement rule, and the bench top-up the
 * "100 PLAYED-THROUGH songs" accounting needs. PURE and deterministic per seed (SplitMix64 + weightedDraw, identical
 * to iOS).
 */
object PocketRunPlanner {

    // Tuning
    const val SLOTS = 100
    const val ARTIST_CAP = 6
    /** No artist twice within 4 slots. */
    const val ARTIST_SPACING = 4
    /** >= 20 % of slots: artists outside the cell's top 10. */
    const val NEWCOMER_FLOOR = 0.2
    /** When the dominant collection's share >= 0.25. */
    const val DOMINANT_MIN_SLOT_SHARE = 0.4
    /** Soft neighbours <= 25 % of the pool. */
    const val SOFT_CAP = 0.25
    const val SOFT_MIN_FIT = 0.6
    const val BENCH_CAP = 400
    const val POOL_CAP = 600
    const val FIRST_DRAW_FROM = 8
    const val NEXT_DRAW_FROM = 6
    const val INSTANT_LEAD_SLOTS = 3
    const val REPLAN_FLOOR_SHARE_OF_MEDIAN = 0.6
    const val MIN_POCKET_FIT = 0.3
    /** A run is DERIVED from its pocket, not a replay: seeds get a light nudge and at most a quarter of the slots. */
    const val SEED_WEIGHT = 0.3
    const val SEED_SLOT_SHARE = 0.25
    const val NEIGHBOUR_MAX_COUNT = 3
    /** Freshness: fresh = not played in [FRESH_DAYS]; every run prefix is >= [FRESH_FLOOR] fresh. */
    const val FRESH_DAYS = 30.0
    const val FRESH_FLOOR = 0.6
    const val FRESH_WEIGHT = 0.6
    const val NEIGHBOUR_SHARE = 0.3
    const val NEIGHBOUR_MIN_SIM = 0.55
    const val NEIGHBOUR_MIN_MEMBERS = 5
    const val NEIGHBOUR_MAX_MEMBERS = 1500

    private const val OTHER_BUCKET = "\u0000other"

    // Input

    data class Candidate(
        val id: String,
        val title: String,
        val artist: String,
        val lengthMs: Int? = null,
        val features: PocketTuning.Features,
        val camelot: String? = null,
        /** Hard membership (add-time recency, 0.5..1) by collection; soft <= 0.6 for non-members. */
        val memberships: Map<String, Double> = emptyMap(),
        /** Starts with no network round trip (burned / AM pre-resolvable / cached presign). */
        val startsInstantly: Boolean = false,
    ) {
        val foldedBpm: Double? get() = InThePocketScorer.foldBpm(features.bpm)
    }

    class Input(
        val profile: PocketProfile,
        /** Every PLAYABLE candidate (the playability rule is the caller's). */
        val candidates: Map<String, Candidate>,
        /** Played in the last 12 h, lifetime thumbs-down, ... */
        val excluded: Set<String> = emptySet(),
        /** Only its NEGATIVE side counts here: a song you keep skipping sinks; playing a lot never lifts it. */
        val familiarity: Map<String, Double> = emptyMap(),
        /** songId -> 0..1, how recently it played (1 = just now, 0 = >= FRESH_DAYS / never). */
        val recency: Map<String, Double> = emptyMap(),
        val tuning: PocketTuning.Multipliers = PocketTuning.Multipliers.NEUTRAL,
        val seed: ULong,
        val slots: Int = SLOTS,
    )

    @Serializable
    data class Row(val songId: String, val slot: Int, val collectionId: String? = null, val score: Double)

    @Serializable
    data class BenchEntry(val songId: String, val score: Double)

    data class Plan(val rows: List<Row>, val bench: List<BenchEntry>)

    /** Swift `(x * 1e6).rounded() / 1e6` (half away from zero). */
    internal fun round6(x: Double): Double = roundHalfAway(x * 1e6) / 1e6

    private fun roundHalfAway(x: Double): Double = if (x < 0) -floor(-x + 0.5) else floor(x + 0.5)

    // Scoring

    class Scorer(
        private val profile: PocketProfile,
        private val tuning: PocketTuning.Multipliers,
        private val familiarity: Map<String, Double>,
        private val recency: Map<String, Double> = emptyMap(),
        pool: List<Candidate>,
    ) {
        private val maxSeed = profile.seeds.values.maxOrNull() ?: 0.0
        private val maxGenre = profile.genres.values.maxOrNull() ?: 0.0
        private val timbreCal: SimilarityFamilies.TimbreCalibration? = profile.timbre?.let { pos ->
            SimilarityFamilies.timbreCalibrate(pool.map { it.features.timbre }, pos, tuning.negativeTimbre, 0.5)
        }

        /** The score with the CURRENT tuning multipliers. */
        fun score(c: Candidate): Double {
            var s = 0.0
            for ((cid, w) in profile.collections) s += 1.5 * w * (c.memberships[cid] ?: 0.0)
            if (maxSeed > 0) profile.seeds[c.id]?.let { s += SEED_WEIGHT * it / maxSeed }
            profile.bpmBand?.let { band ->
                val b = c.foldedBpm
                if (b != null) {
                    val d = bandDistance(b, band)
                    s += 0.6 * (if (d == 0.0) 1.0 else exp(-d / 8))
                } else {
                    s += 0.6 * 0.5 // unknown tempo: neutral (AM rows carry no BPM)
                }
            }
            profile.era?.let { era ->
                val y = c.features.year
                s += if (y != null && y > 0) 0.5 * SimilarityFamilies.eraFit(y.toDouble(), era)
                else 0.5 * SimilarityFamilies.FALLBACK_NEUTRAL_ERA_FIT
            }
            val pos = profile.timbre
            val cal = timbreCal
            if (pos != null && cal != null) {
                s += 0.7 * SimilarityFamilies.timbreFit(c.features.timbre, pos, tuning.negativeTimbre, 0.5, cal)
            }
            if (maxGenre > 0) {
                val g = c.features.genre
                val v = if (g != null) profile.genres[g] else null
                if (v != null) s += 0.4 * v / maxGenre
            }
            s += min(0.0, familiarity[c.id] ?: 0.0)
            s += FRESH_WEIGHT * (1 - (recency[c.id] ?: 0.0))
            return max(0.0, s) * tuning.factor(c.features)
        }
    }

    private fun bandDistance(b: Double, band: ClosedFloatingPointRange<Double>): Double =
        if (b in band) 0.0 else min(abs(b - band.start), abs(b - band.endInclusive))

    // Freshness

    /** songId -> 0..1 recency from last-played times (1 = now, 0 at >= FRESH_DAYS). Absent songs are fresh. */
    fun recency(lastPlayedMs: Map<String, Double>, nowMs: Double): Map<String, Double> {
        val span = FRESH_DAYS * 86_400_000
        val out = HashMap<String, Double>()
        for ((id, t) in lastPlayedMs) {
            val r = 1 - (nowMs - t) / span
            if (r > 0) out[id] = min(1.0, r)
        }
        return out
    }

    // Seed gaps

    /** Fill what the profile doesn't know from its seeds' own features. Never overwrites a known dimension. */
    fun fillingGapsFromSeeds(p: PocketProfile, candidates: Map<String, Candidate>): PocketProfile {
        val seeds = p.seeds.keys.sorted().mapNotNull { candidates[it] }
        if (seeds.isEmpty()) return p
        var out = p
        if (out.genres.isEmpty()) {
            val g = LinkedHashMap<String, Double>()
            for (c in seeds) c.features.genre?.let { g[it] = (g[it] ?: 0.0) + 1 }
            out = out.copy(genres = PocketMomentEngine.topNormalized(g, 8))
        }
        if (out.era == null) {
            SimilarityFamilies.eraWindow(seeds.mapNotNull { it.features.year?.toDouble() })?.let {
                out = out.copy(eraLo = it.lo, eraHi = it.hi)
            }
        }
        if (out.bpmBand == null) {
            val bpms = seeds.mapNotNull { it.foldedBpm }.sorted()
            if (bpms.size >= 3) {
                val band = InThePocketScorer.normalizedBand(bpms[bpms.size / 4], bpms[(bpms.size * 3) / 4])
                out = out.copy(bpmLo = band.start, bpmHi = band.endInclusive)
            }
        }
        if (out.timbre == null) {
            val tp = SimilarityFamilies.timbreProfile(
                seeds.mapNotNull { c -> c.features.timbre?.let { SimilarityFamilies.TimbreMember(it, 1.0) } },
            )
            if (tp != null) out = out.copy(timbreCentroid = tp.centroid, timbreSpread = tp.spread, timbreVectors = tp.vectors)
        }
        return out
    }

    /** Step 0 in full: seed gaps, then neighbour collections. */
    fun derived(p: PocketProfile, candidates: Map<String, Candidate>): PocketProfile =
        withNeighbourCollections(fillingGapsFromSeeds(p, candidates), candidates)

    // Neighbour collections

    /** One non-profile collection's resemblance to the pocket (null = never a neighbour). */
    fun collectionSim(members: List<Candidate>, overlap: Double, profile: PocketProfile): Double? {
        val parts = ArrayList<Pair<Double, Double>>() // (value, weight)
        val genreCounts = LinkedHashMap<String, Double>()
        for (c in members) c.features.genre?.let { genreCounts[it] = (genreCounts[it] ?: 0.0) + 1 }
        if (profile.genres.isNotEmpty() && genreCounts.isNotEmpty()) {
            val dot = genreCounts.entries.fold(0.0) { a, e -> a + e.value * (profile.genres[e.key] ?: 0.0) }
            val na = sqrt(genreCounts.values.fold(0.0) { a, x -> a + x * x })
            val nb = sqrt(profile.genres.values.fold(0.0) { a, x -> a + x * x })
            val cos = if (na > 0 && nb > 0) dot / (na * nb) else 0.0
            if (cos < 0.5) return null // a different genre is never a neighbour
            parts.add(cos to 2.0)
        }
        profile.era?.let { era ->
            val fits = members.mapNotNull { c -> c.features.year?.takeIf { it > 0 }?.let { SimilarityFamilies.eraFit(it.toDouble(), era) } }
            if (fits.isNotEmpty()) parts.add(fits.sum() / fits.size to 1.0)
        }
        profile.bpmBand?.let { band ->
            val fits = members.mapNotNull { it.foldedBpm }.map { exp(-bandDistance(it, band) / 8) }
            if (fits.isNotEmpty()) parts.add(fits.sum() / fits.size to 1.0)
        }
        profile.timbre?.let { pos ->
            val fits = members.mapNotNull { c -> c.features.timbre?.let { SimilarityFamilies.timbreFit(it, pos) } }
            if (fits.isNotEmpty()) parts.add(fits.sum() / fits.size to 2.0)
        }
        if (parts.isEmpty()) return null
        val musical = parts.sumOf { it.first * it.second } / parts.sumOf { it.second }
        return 0.75 * musical + 0.25 * overlap
    }

    /**
     * The profile with up to [NEIGHBOUR_MAX_COUNT] collections that resemble its own folded in (<= [NEIGHBOUR_SHARE] of
     * the collection weight, proportional to similarity). Unchanged when no collections or nothing qualifies.
     */
    fun withNeighbourCollections(p: PocketProfile, candidates: Map<String, Candidate>): PocketProfile {
        if (p.collections.isEmpty()) return p
        val members = HashMap<String, MutableList<Candidate>>()
        for (c in candidates.values) {
            for ((cid, m) in c.memberships) if (m >= 0.5) members.getOrPut(cid) { ArrayList() }.add(c)
        }
        val own: Map<String, Set<String>> = p.collections.keys.associateWith { cid -> (members[cid] ?: emptyList<Candidate>()).map { it.id }.toSet() }
        val ownMass = p.collections.values.sum()
        val scored = ArrayList<Pair<String, Double>>()
        for (cid in members.keys.sorted()) {
            val ms = members.getValue(cid)
            if (p.collections[cid] != null || cid == PocketWheelIds.FAVORITES) continue
            if (ms.size < NEIGHBOUR_MIN_MEMBERS || ms.size > NEIGHBOUR_MAX_MEMBERS) continue
            val ids = ms.map { it.id }.toSet()
            var overlap = 0.0
            for (oid in own.keys.sorted()) {
                val oset = own.getValue(oid)
                if (oset.isEmpty()) continue
                val o = oset.intersect(ids).size.toDouble() / min(oset.size, ids.size)
                overlap += (p.collections[oid] ?: 0.0) / max(ownMass, 1e-9) * o
            }
            val sim = collectionSim(ms, overlap, p)
            if (sim != null && sim >= NEIGHBOUR_MIN_SIM) scored.add(cid to sim)
        }
        val top = scored.sortedWith { a, b -> if (a.second != b.second) b.second.compareTo(a.second) else a.first.compareTo(b.first) }
            .take(NEIGHBOUR_MAX_COUNT)
        if (top.isEmpty()) return p
        val simTotal = top.sumOf { it.second }
        val share = NEIGHBOUR_SHARE * simTotal / top.size // closer neighbours earn more
        val cols = LinkedHashMap<String, Double>()
        for ((k, v) in p.collections) cols[k] = v / max(ownMass, 1e-9) * (1 - share)
        for ((cid, sim) in top) cols[cid] = share * sim / simTotal
        return p.copy(collections = cols)
    }

    // Pool

    fun pool(input: Input): List<Candidate> {
        val p = input.profile
        val core = ArrayList<Candidate>()
        val soft = ArrayList<Candidate>()
        for (c in input.candidates.values) {
            if (c.id in input.excluded || input.tuning.isBanned(c.features)) continue
            val member = p.collections.keys.any { (c.memberships[it] ?: 0.0) >= 0.5 }
            if (member || p.seeds[c.id] != null || p.candidateBoost[c.id] != null) {
                core.add(c)
                continue
            }
            if (softFit(c, p) >= SOFT_MIN_FIT) soft.add(c)
        }
        val scorer = Scorer(p, input.tuning, input.familiarity, input.recency, core + soft)
        fun ranked(a: List<Candidate>): List<Candidate> =
            a.map { it to scorer.score(it) }
                .sortedWith { x, y -> if (x.second != y.second) y.second.compareTo(x.second) else x.first.id.compareTo(y.first.id) }
                .map { it.first }
        val coreRanked = ranked(core)
        // Every profile collection keeps its share of the core pool.
        val corePicked = ArrayList<Candidate>()
        val seen = HashSet<String>()
        val mass = p.collections.values.sum()
        if (mass > 0 && coreRanked.size > POOL_CAP) {
            val byBucket = HashMap<String, MutableList<Candidate>>()
            for (c in coreRanked) bucket(c, p)?.let { byBucket.getOrPut(it) { ArrayList() }.add(c) }
            for ((cid, w) in p.collections.entries.sortedBy { it.key }) {
                val n = ceil(w / mass * POOL_CAP).toInt()
                for (c in (byBucket[cid] ?: emptyList<Candidate>()).take(n)) if (seen.add(c.id)) corePicked.add(c)
            }
        }
        for (c in coreRanked) if (corePicked.size < POOL_CAP && seen.add(c.id)) corePicked.add(c)
        val softQuota = max(0, (min(POOL_CAP, coreRanked.size + soft.size) * SOFT_CAP).toInt())
        return (ranked(corePicked).take(POOL_CAP) + ranked(soft).take(softQuota)).take(POOL_CAP)
    }

    /** The soft-neighbour test for a NON-member: timbre fit to the profile centroid, else genre + era / bpm. */
    fun softFit(c: Candidate, p: PocketProfile): Double {
        val pos = p.timbre
        val v = c.features.timbre
        if (pos != null && v != null) SimilarityFamilies.timbreFit(v, pos)?.let { return it }
        val g = c.features.genre ?: return 0.0
        val gw = p.genres[g] ?: return 0.0
        if (!(gw > 0)) return 0.0
        val gNorm = gw / (p.genres.values.maxOrNull() ?: gw)
        val parts = ArrayList<Double>()
        val era = p.era
        val y = c.features.year
        if (era != null && y != null) parts.add(SimilarityFamilies.eraFit(y.toDouble(), era))
        val band = p.bpmBand
        val b = c.foldedBpm
        if (band != null && b != null) parts.add(exp(-bandDistance(b, band) / 8))
        val rest = if (parts.isEmpty()) 0.5 else parts.sum() / parts.size
        return gNorm * (0.5 + 0.5 * rest)
    }

    // Compose

    /** The collection a candidate fills a quota slot for: largest w_c * m_c(song) (member >= 0.5), or null ("other"). */
    fun bucket(c: Candidate, p: PocketProfile): String? {
        var best: String? = null
        var bestV = 0.0
        for ((cid, w) in p.collections) {
            val m = c.memberships[cid] ?: 0.0
            if (m < 0.5) continue
            val v = w * m
            if (best == null || v > bestV || (v == bestV && cid < best)) { best = cid; bestV = v }
        }
        return best
    }

    /** Slots per collection proportional to w_c, the dominant at >= 40 % when its share is >= 0.25. */
    fun quotas(profile: PocketProfile, slots: Int): Map<String, Int> {
        if (profile.collections.isEmpty()) return emptyMap()
        val w = LinkedHashMap(profile.collections)
        val total = w.values.sum()
        if (!(total > 0)) return emptyMap()
        for (k in w.keys.toList()) w[k] = w.getValue(k) / total
        val d = profile.dominantCollectionId
        val share = if (d != null) w[d] else null
        if (d != null && share != null && share >= 0.25 && share < DOMINANT_MIN_SLOT_SHARE) {
            val rest = 1 - share
            for (k in w.keys.toList()) if (k != d) w[k] = w.getValue(k) * (1 - DOMINANT_MIN_SLOT_SHARE) / max(rest, 1e-9)
            w[d] = DOMINANT_MIN_SLOT_SHARE
        }
        return w.mapValues { roundHalfAway(it.value * slots).toInt() }
    }

    fun flow(c: Candidate, prev: Candidate?): Double {
        if (prev == null) return 0.0
        var f = 0.0
        val a = c.foldedBpm
        val b = prev.foldedBpm
        if (a != null && b != null) f += 0.3 * exp(-abs(a - b) / 10)
        val ca = c.camelot
        val cb = prev.camelot
        if (ca != null && cb != null) f += 0.2 * SimilarityFamilies.camelotRelatedness(ca, cb)
        return f
    }

    private class Scored(val c: Candidate, val s: Double, val bucket: String?)

    fun plan(input: Input): Plan {
        val pool = pool(input)
        val scorer = Scorer(input.profile, input.tuning, input.familiarity, input.recency, pool)
        val scored = pool.mapTo(ArrayList()) { Scored(it, scorer.score(it), bucket(it, input.profile)) }
        val slots = min(input.slots, scored.size)
        val quotas = quotas(input.profile, slots)
        val topArtists = input.profile.artists.entries
            .sortedWith { a, b -> if (a.value != b.value) b.value.compareTo(a.value) else a.key.compareTo(b.key) }
            .take(10).map { it.key }.toSet()
        val newcomersNeeded = ceil(slots * NEWCOMER_FLOOR).toInt()
        val seedCap = max(1, roundHalfAway(slots * SEED_SLOT_SHARE).toInt())
        var seedsPlaced = 0
        fun isFresh(c: Candidate) = (input.recency[c.id] ?: 0.0) <= 0
        var freshPlaced = 0
        val rng = SplitMix64(input.seed)
        val rows = ArrayList<Row>()
        val placed = ArrayList<Candidate>()
        val artistCount = HashMap<String, Int>()
        val bucketCount = HashMap<String, Int>()
        var newcomers = 0
        fun isNewcomer(c: Candidate) = c.features.artistKeys.none { it in topArtists }
        val quotaTotal = quotas.values.sum()

        while (rows.size < slots && scored.isNotEmpty()) {
            val slot = rows.size + 1
            val recent = placed.takeLast(ARTIST_SPACING - 1).flatMap { it.features.artistKeys }
            val remaining = slots - rows.size
            val mustNewcomer = topArtists.isNotEmpty() && newcomersNeeded - newcomers >= remaining
            // Paced, not back-loaded: every prefix of the run stays >= FRESH_FLOOR fresh.
            val mustFresh = (freshPlaced + 1).toDouble() <= FRESH_FLOOR * slot
            fun eligible(e: Scored, strict: Boolean, fresh: Boolean = true): Boolean {
                val keys = e.c.features.artistKeys
                if (fresh && mustFresh && !isFresh(e.c)) return false
                if (keys.any { (artistCount[it] ?: 0) >= ARTIST_CAP }) return false
                if (keys.any { it in recent }) return false
                if (mustNewcomer && !isNewcomer(e.c)) return false
                if (strict && seedsPlaced >= seedCap && input.profile.seeds[e.c.id] != null) return false
                val b = e.bucket
                val q = if (b != null) quotas[b] else null
                if (strict && b != null && q != null && (bucketCount[b] ?: 0) >= q) return false
                if (strict && b == null && quotas.isNotEmpty()) {
                    if ((bucketCount[OTHER_BUCKET] ?: 0) >= max(0, slots - quotaTotal)) return false
                }
                return true
            }
            var idx = scored.indices.filter { eligible(scored[it], strict = true) }
            if (idx.isEmpty()) idx = scored.indices.filter { eligible(scored[it], strict = false) }
            if (idx.isEmpty()) idx = scored.indices.filter { eligible(scored[it], strict = false, fresh = false) }
            if (idx.isEmpty()) idx = scored.indices.toList() // constraints unsatisfiable: best effort
            if (slot <= INSTANT_LEAD_SLOTS) {
                val instant = idx.filter { scored[it].c.startsInstantly }
                if (instant.isNotEmpty()) idx = instant
            }
            val prev = placed.lastOrNull()
            val ranked = idx.map { it to scored[it].s + flow(scored[it].c, prev) }
                .sortedWith { a, b -> if (a.second != b.second) b.second.compareTo(a.second) else scored[a.first].c.id.compareTo(scored[b.first].c.id) }
            val window = ranked.take(if (slot == 1) FIRST_DRAW_FROM else NEXT_DRAW_FROM)
            val pick = InThePocketScorer.weightedDraw(window, rng)
            val e = scored.removeAt(pick)
            rows.add(Row(e.c.id, slot, e.bucket, round6(e.s)))
            placed.add(e.c)
            for (k in e.c.features.artistKeys) artistCount[k] = (artistCount[k] ?: 0) + 1
            val bk = e.bucket ?: OTHER_BUCKET
            bucketCount[bk] = (bucketCount[bk] ?: 0) + 1
            if (isNewcomer(e.c)) newcomers++
            if (input.profile.seeds[e.c.id] != null) seedsPlaced++
            if (isFresh(e.c)) freshPlaced++
        }
        val bench = scored.sortedWith { a, b -> if (a.s != b.s) b.s.compareTo(a.s) else a.c.id.compareTo(b.c.id) }
            .take(BENCH_CAP).map { BenchEntry(it.c.id, round6(it.s)) }
        return Plan(rows, bench)
    }

    // Re-plan

    /** A row of the live queue the planner may consider (the caller already applied the protection rules). */
    data class LiveRow(
        val uid: String,
        val songId: String,
        val slot: Int,
        val collectionId: String? = null,
        /** Replacement must start instantly (an in-flight capture is never traded for another). */
        val requiresInstant: Boolean = false,
    )

    data class Replacement(val uid: String, val songId: String, val slot: Int, val collectionId: String?, val score: Double)

    data class ReplanResult(val replacements: List<Replacement>, val removals: List<String>, val banned: List<String>)

    /** The song ids of a live row's previous / next neighbour (null at an end). */
    data class Neighbours(val prev: String? = null, val next: String? = null)

    /** "Similar musically, different artist": genre + era + bpm + key + timbre (counts double). NO artist family. */
    fun musicalSim(x: Candidate, r: Candidate): Double {
        val parts = ArrayList<Double>()
        val sameGenre = if (x.features.genre != null && x.features.genre == r.features.genre) 1.0 else 0.0
        if (x.features.genre != null || r.features.genre != null) parts.add(sameGenre)
        val ya = x.features.year
        val yb = r.features.year
        if (ya != null && yb != null) parts.add(exp(-abs(ya - yb).toDouble() / 4))
        val ba = x.foldedBpm
        val bb = r.foldedBpm
        if (ba != null && bb != null) parts.add(exp(-abs(ba - bb) / 10))
        val ca = x.camelot
        val cb = r.camelot
        if (ca != null && cb != null) parts.add(SimilarityFamilies.camelotRelatedness(ca, cb))
        val ta = x.features.timbre
        val tb = r.features.timbre
        if (ta != null && tb != null) {
            SimilarityFamilies.timbreDistance(ta, tb)?.let { d ->
                parts.add(exp(-d / SimilarityFamilies.TIMBRE_DECAY))
                parts.add(exp(-d / SimilarityFamilies.TIMBRE_DECAY))
            }
        }
        return if (parts.isEmpty()) 0.0 else parts.sum() / parts.size
    }

    /**
     * Replace upcoming rows that now fall below the floor (banned artist, or a score under 0.6 x the median placed
     * score) with the best "similar, different artist" candidate; a row with no candidate clearing
     * `pocketFit >= 0.3` is removed.
     */
    fun replan(
        profile: PocketProfile,
        candidates: Map<String, Candidate>,
        tuning: PocketTuning.Multipliers,
        familiarity: Map<String, Double>,
        recency: Map<String, Double> = emptyMap(),
        live: List<LiveRow>,
        inRun: Set<String>,
        neighbours: Map<String, Neighbours>,
        excluded: Set<String> = emptySet(),
    ): ReplanResult {
        val pool = candidates.values.filter { it.id !in excluded }
        val scorer = Scorer(profile, tuning, familiarity, recency, pool)
        val placedScores = live.mapNotNull { r -> candidates[r.songId]?.let { scorer.score(it) } }.sorted()
        val median = if (placedScores.isEmpty()) 0.0 else placedScores[placedScores.size / 2]
        val maxScore = max(pool.maxOfOrNull { scorer.score(it) } ?: 1.0, 1e-9)
        val used = HashSet(inRun)
        val artistCount = HashMap<String, Int>()
        for (row in live) for (k in candidates[row.songId]?.features?.artistKeys.orEmpty()) artistCount[k] = (artistCount[k] ?: 0) + 1
        val replacements = ArrayList<Replacement>()
        val removals = ArrayList<String>()
        // Artists by slot (kept current as rows are replaced): a replacement keeps the spacing rule against its
        // neighbours, not just "not the skipped artist".
        val artistsAt = HashMap<Int, Set<String>>()
        for (row in live) artistsAt[row.slot] = candidates[row.songId]?.features?.artistKeys.orEmpty().toSet()
        for (row in live.sortedBy { it.slot }) {
            val r = candidates[row.songId] ?: continue
            val banned = tuning.isBanned(r.features)
            val s = scorer.score(r)
            if (!(banned || s < REPLAN_FLOOR_SHARE_OF_MEDIAN * median)) continue
            val atCap = artistCount.filter { it.value >= ARTIST_CAP }.keys
            val nb = neighbours[row.uid]
            val nearby = HashSet<String>()
            nb?.prev?.let { candidates[it] }?.let { nearby.addAll(it.features.artistKeys) }
            nb?.next?.let { candidates[it] }?.let { nearby.addAll(it.features.artistKeys) }
            for (d in 1 until ARTIST_SPACING) {
                artistsAt[row.slot - d]?.let { nearby.addAll(it) }
                artistsAt[row.slot + d]?.let { nearby.addAll(it) }
            }
            var best: Candidate? = null
            var bestTotal = 0.0
            var bestScore = 0.0
            val rKeys = r.features.artistKeys.toSet()
            for (x in pool) {
                if (x.id in used) continue
                val xk = x.features.artistKeys
                if (xk.any { it in tuning.bannedArtists || it in atCap }) continue
                if (xk.any { it in rKeys }) continue
                if (xk.any { it in nearby }) continue
                if (row.requiresInstant && !x.startsInstantly) continue
                val xs = scorer.score(x)
                val fit = xs / maxScore
                if (fit < MIN_POCKET_FIT) continue
                val prev = nb?.prev?.let { candidates[it] }
                val next = nb?.next?.let { candidates[it] }
                val fl = (flow(x, prev) + flow(x, next)) / 2
                val total = 0.55 * musicalSim(x, r) + 0.35 * fit + 0.10 * fl
                if (best == null || total > bestTotal || (total == bestTotal && x.id < best.id)) {
                    best = x; bestTotal = total; bestScore = xs
                }
            }
            for (k in r.features.artistKeys) artistCount[k] = (artistCount[k] ?: 0) - 1
            if (best != null) {
                used.add(best.id)
                for (k in best.features.artistKeys) artistCount[k] = (artistCount[k] ?: 0) + 1
                artistsAt[row.slot] = best.features.artistKeys.toSet()
                replacements.add(Replacement(row.uid, best.id, row.slot, bucket(best, profile), round6(bestScore)))
            } else {
                removals.add(row.uid)
                artistsAt.remove(row.slot)
            }
        }
        return ReplanResult(replacements, removals, tuning.bannedArtists.sorted())
    }

    /**
     * W2 top-up: the next [count] songs to APPEND after a skip (so 100 played-through stays reachable), best-scored
     * first, respecting bans, the artist cap and spacing after [tail].
     */
    fun topUp(
        count: Int,
        profile: PocketProfile,
        candidates: Map<String, Candidate>,
        tuning: PocketTuning.Multipliers,
        familiarity: Map<String, Double>,
        recency: Map<String, Double> = emptyMap(),
        inRun: Set<String>,
        tail: List<String>,
        excluded: Set<String> = emptySet(),
    ): List<BenchEntry> {
        if (count <= 0) return emptyList()
        val pool = candidates.values.filter { it.id !in excluded && it.id !in inRun && !tuning.isBanned(it.features) }
        val scorer = Scorer(profile, tuning, familiarity, recency, pool)
        val artistCount = HashMap<String, Int>()
        for (id in inRun) for (k in candidates[id]?.features?.artistKeys.orEmpty()) artistCount[k] = (artistCount[k] ?: 0) + 1
        var recent: List<String> = tail.takeLast(ARTIST_SPACING - 1).flatMap { candidates[it]?.features?.artistKeys.orEmpty() }
        val out = ArrayList<BenchEntry>()
        val ranked = pool.map { it to scorer.score(it) }
            .sortedWith { a, b -> if (a.second != b.second) b.second.compareTo(a.second) else a.first.id.compareTo(b.first.id) }
        for ((c, s) in ranked) {
            if (out.size >= count) break
            val keys = c.features.artistKeys
            if (keys.any { (artistCount[it] ?: 0) >= ARTIST_CAP || it in recent }) continue
            out.add(BenchEntry(c.id, round6(s)))
            for (k in keys) artistCount[k] = (artistCount[k] ?: 0) + 1
            recent = (recent + keys).takeLast((ARTIST_SPACING - 1) * 2)
        }
        return out
    }
}

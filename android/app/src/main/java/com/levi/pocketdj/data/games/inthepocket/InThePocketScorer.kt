package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.pockets.ListeningContextTag
import com.levi.pocketdj.data.pockets.ListeningPocketCollectionCandidate
import com.levi.pocketdj.data.pockets.ListeningPocketFeature
import com.levi.pocketdj.data.pockets.ListeningPocketMembershipWeight
import com.levi.pocketdj.data.pockets.ListeningPocketNumeric
import com.levi.pocketdj.data.pockets.ListeningPocketsResults
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * IN THE POCKET — the round builder (port of InThePocketScorer.swift). PURE and DETERMINISTIC:
 * the same [Input] (seed included) always yields the same round.
 *
 * Profile: `.CLOUD` (the cloud's pockets + patterns matching now) → `.HISTORY` (this device's own
 * plays in this context) → `.COLD` (every non-skipped play). Round learning multiplies target
 * weights per context. Score = Σ matched target weights + 0.6·bpm fit + 0.8·seed strength +
 * familiarity + 0.9·cosine(membership) + 0.5·collection-candidate strength. Pick: top 40 (ties →
 * id); song 1 a seeded draw (score²) from the top 8, each next re-scored for coherence/diversity
 * and drawn from the top 6. Four songs for CLOUD, three otherwise.
 */
object InThePocketScorer {

    const val ALGO_VERSION = 1

    // MARK: - Input

    /** What the scorer knows about a song. Built from the catalog (genre category via the album). */
    data class Song(
        val id: String,
        val title: String,
        val artist: String,
        val lengthMs: Int? = null,
        /** `Genre.category` — the same vocabulary as the cloud's `g` (lowercased). */
        val genre: String? = null,
        val bpm: Double? = null,
        val camelot: String? = null,
        val moods: List<String> = emptyList(),
    )

    /** One play from the history log, reduced to what matters here. */
    data class Play(
        val songId: String,
        val atMs: Double,
        val tzOffsetMin: Int,
        /** completed | skipped | partial | unknown. */
        val outcome: String,
        val ctx: ListeningContextTag? = null,
    ) {
        val isSkip: Boolean get() = outcome == "skipped"
    }

    /** One collection as the scorer sees it: effective members + when each was last added. */
    data class CollectionInfo(
        val id: String,
        /** LOCAL display name (round target labels / "why" chips). Never uploaded. */
        val name: String? = null,
        val songIds: Set<String>,
        /** songId → epoch ms it was last added (absent ⇒ unknown). */
        val addedAtMs: Map<String, Double> = emptyMap(),
    )

    data class Input(
        val context: InThePocketContext,
        /** Display label for `context.ctx` ("Location A", "A → B"). */
        val contextLabel: String? = null,
        val results: ListeningPocketsResults? = null,
        /** Every song the scorer may describe (playable or not — history songs need genres too). */
        val catalog: Map<String, Song>,
        /** Songs that can make sound right now. Only these are ever picked. */
        val playableIds: Set<String>,
        val plays: List<Play> = emptyList(),
        /** This device's finished rounds — the local round-learning fallback + variety exclusion. */
        val pastRounds: List<InThePocketRound> = emptyList(),
        val nowMs: Double,
        val seed: ULong,
        /** Songs played (anywhere) within this window are not picked. */
        val recentExclusionMs: Double = 48 * 3_600_000.0,
        /** This device's collections, flattened. Empty ⇒ the scorer behaves as without them. */
        val collections: List<CollectionInfo> = emptyList(),
    )

    data class Pick(val song: Song, val score: Double, val why: List<String>)

    data class Output(
        val mode: InThePocketMode,
        val targets: List<InThePocketTarget>,
        val bpmBand: ClosedFloatingPointRange<Double>?,
        val picks: List<Pick>,
        /** The round's "why" chips: "Weekday evening · Location A · 118–126 BPM · Funk/Soul". */
        val chips: List<String>,
    )

    enum class Failure {
        /** Nothing playable right now (no Apple Music, nothing ripped or downloaded). */
        NOTHING_PLAYABLE,
        /** Fewer than three songs fit — play more music first. */
        NOT_ENOUGH_CANDIDATES,
    }

    sealed class BuildResult {
        data class Success(val output: Output) : BuildResult()
        data class Failed(val failure: Failure) : BuildResult()
    }

    data class Profile(
        val mode: InThePocketMode,
        val targets: List<InThePocketTarget>,
        val bpmBand: ClosedFloatingPointRange<Double>?,
        val seedSongs: Map<String, Double>,
        /** Collection id → weight (L1-normalised, top 12). Empty ⇒ no membership pull. */
        val membership: Map<String, Double> = emptyMap(),
        /** Song id → strength from the cloud's `pattern.collectionCandidates`. */
        val candidateBoost: Map<String, Double> = emptyMap(),
    )

    data class Scored(val profile: Profile, val membership: MembershipIndex, val scored: List<Pick>)

    // MARK: - Tuning (one place)

    const val MAX_TARGETS = 6
    const val BPM_WEIGHT = 0.6
    const val SEED_WEIGHT = 0.8
    const val TOP_K = 40
    const val FIRST_DRAW_FROM = 8
    const val NEXT_DRAW_FROM = 6
    const val MIN_CONTEXT_PLAYS = 5
    const val LEARNING_ADD_MIN = 1.25

    // Pockets × collections (docs/design/pockets-collections.md).
    const val MEMBERSHIP_WEIGHT = 0.9
    const val MEMBERSHIP_RELATED_MIN = 0.2
    const val SOFT_MAX = 0.6
    const val SOFT_MIN = 0.55
    const val SIM_GENRE_WEIGHT = 0.35
    const val SIM_BPM_WEIGHT = 0.25
    const val SIM_CAMELOT_WEIGHT = 0.2
    const val SIM_MOOD_WEIGHT = 0.2
    const val SIM_MIN_COVERAGE = 0.45
    const val SIM_BPM_SIGMA = 8.0
    const val MIN_CENTROID_MEMBERS = 3
    const val ADD_HALF_LIFE_DAYS = 45.0
    const val UNKNOWN_ADD_SCALE = 0.75
    const val MEMBERSHIP_TOP = 12
    const val LIVE_WINDOW_MS = 60 * 60_000.0
    const val LIVE_WEIGHT = 0.5
    const val SOFT_BASIS_SONGS = 50
    const val COLLECTION_CANDIDATE_WEIGHT = 0.5
    const val COHERENCE_MEMBERSHIP_WEIGHT = 0.3
    const val MAX_COLLECTION_TARGETS = 3

    val musicalDims: Set<String> = setOf("genre", "artist", "mood", "camelot")

    private val targetOrder = compareByDescending<InThePocketTarget> { it.weight }
        .thenBy { it.dim }.thenBy { it.value }

    // MARK: - Build

    fun build(input: Input): BuildResult {
        val candidatesAll = input.playableIds.mapNotNull { input.catalog[it] }
        if (candidatesAll.isEmpty()) return BuildResult.Failed(Failure.NOTHING_PLAYABLE)
        val (profile0, membership, scoredRaw) = scoreCandidates(input, candidatesAll)
        val count = if (profile0.mode == InThePocketMode.CLOUD) 4 else 3
        if (scoredRaw.size < 3) return BuildResult.Failed(Failure.NOT_ENOUGH_CANDIDATES)
        val scored = scoredRaw.sortedWith(compareByDescending<Pick> { it.score }.thenBy { it.song.id })
        val pool = scored.take(TOP_K).toMutableList()
        val rng = SplitMix64(input.seed)
        val picks = mutableListOf<Pick>()
        while (picks.size < min(count, scored.size) && pool.isNotEmpty()) {
            val ranked: List<Pair<Int, Double>> = if (picks.isEmpty()) {
                pool.indices.map { it to pool[it].score }
            } else {
                pool.indices.map { i -> i to (pool[i].score + coherence(pool[i].song, picks) { membership.collectionsOf(it) }) }
                    .sortedWith(compareByDescending<Pair<Int, Double>> { it.second }.thenBy { pool[it.first].song.id })
            }
            val window = ranked.take(if (picks.isEmpty()) FIRST_DRAW_FROM else NEXT_DRAW_FROM)
            val chosen = weightedDraw(window, rng)
            picks.add(pool[chosen])
            pool.removeAt(chosen)
        }
        if (picks.size < 3) return BuildResult.Failed(Failure.NOT_ENOUGH_CANDIDATES)
        val profile = profile0.copy(targets = profile0.targets + collectionTargets(profile0.membership, membership))
        return BuildResult.Success(
            Output(profile.mode, profile.targets, profile.bpmBand, picks, chips(input, profile)),
        )
    }

    /**
     * The profile (with membership + learning applied) and every RELATED, non-excluded
     * candidate with its score — `build`'s first half, exposed for tests.
     */
    fun scoreCandidates(input: Input, candidates: List<Song>? = null): Scored {
        val candidatesAll = candidates ?: input.playableIds.mapNotNull { input.catalog[it] }
        var profile = cloudProfile(input) ?: historyProfile(input)
        val membership = MembershipIndex(input)
        profile = applyMembership(profile, input, membership)
        profile = applyLearning(profile, input)

        // Exclusions: anything played recently, and the songs of the last three rounds.
        val cutoff = input.nowMs - input.recentExclusionMs
        val excluded = HashSet<String>()
        input.plays.filter { it.atMs >= cutoff }.mapTo(excluded) { it.songId }
        for (r in input.pastRounds.sortedByDescending { it.createdAtMs }.take(3)) r.songs.mapTo(excluded) { it.id }
        val familiarity = familiarity(input.plays)
        val maxSeed = profile.seedSongs.values.maxOrNull() ?: 0.0
        val maxBoost = profile.candidateBoost.values.maxOrNull() ?: 0.0
        val pull = MembershipPull.create(profile.membership, membership, input)

        val scored = mutableListOf<Pick>()
        for (c in candidatesAll) {
            if (c.id in excluded) continue
            var s = 0.0
            val why = mutableListOf<String>()
            var related = false
            for (t in profile.targets) if (matches(c, t)) { s += t.weight; why.add(t.label); related = true }
            val band = profile.bpmBand
            val folded = foldBpm(c.bpm)
            if (band != null && folded != null) {
                val d = if (folded in band) 0.0 else min(abs(folded - band.start), abs(folded - band.endInclusive))
                val fit = if (d == 0.0) 1.0 else exp(-d / 8)
                s += BPM_WEIGHT * fit
                if (d == 0.0) { why.add("${roundHalfAway(folded).toInt()} BPM"); related = true }
            }
            val seedW = profile.seedSongs[c.id]
            if (maxSeed > 0 && seedW != null) {
                s += SEED_WEIGHT * (seedW / maxSeed); why.add("From your pockets"); related = true
            }
            val r = pull?.cosine(c, input.nowMs)
            if (r != null && r.first > 0) {
                s += MEMBERSHIP_WEIGHT * r.first
                if (r.first >= MEMBERSHIP_RELATED_MIN) {
                    why.add(membership.name(r.second)?.let { "Like $it" } ?: "Like your collections")
                    related = true
                }
            }
            val b = profile.candidateBoost[c.id]
            if (maxBoost > 0 && b != null && b > 0) {
                s += COLLECTION_CANDIDATE_WEIGHT * (b / maxBoost)
                if (why.none { it.startsWith("Like ") }) why.add("From your collections")
                related = true
            }
            if (!related) continue
            s += familiarity[c.id] ?: 0.0
            scored.add(Pick(c, s, why))
        }
        return Scored(profile, membership, scored)
    }

    // MARK: - Profiles

    /** How well a cloud source's context matches now: 0 unless the time bucket matches; +1 day type; +2 same place/trip. */
    fun contextMatch(timeBucket: String?, dayType: String?, ctx: ListeningContextTag?, now: InThePocketContext): Double {
        if (timeBucket != now.timeBucket) return 0.0
        var m = 2.0
        if (dayType == now.dayType) m += 1
        val mine = now.ctx
        if (ctx != null && mine != null) {
            if (ctx.isTrip && mine.isTrip && ctx.tripId == mine.tripId) m += 2
            if (ctx.isPlace && mine.isPlace && ctx.placeId == mine.placeId) m += 2
        }
        return m
    }

    fun cloudProfile(input: Input): Profile? {
        val results = input.results ?: return null
        if (results.generatedAtMs == null) return null
        val acc = LinkedHashMap<String, Pair<InThePocketTarget, Double>>()
        val seeds = LinkedHashMap<String, Double>()
        var bandLo = 0.0; var bandHi = 0.0; var bandW = 0.0
        val memb = LinkedHashMap<String, Double>()
        val boost = LinkedHashMap<String, Double>()
        var any = false

        fun absorb(
            features: List<ListeningPocketFeature>, numeric: Map<String, ListeningPocketNumeric>,
            songIds: List<Pair<String, Double>>, membership: List<ListeningPocketMembershipWeight>,
            candidates: List<ListeningPocketCollectionCandidate>, w: Double,
        ) {
            any = true
            for (m in membership) if (m.weight > 0) memb[m.collectionId] = (memb[m.collectionId] ?: 0.0) + w * m.weight
            for (c in candidates) if (c.score > 0) boost[c.songId] = (boost[c.songId] ?: 0.0) + w * c.score
            for (f in features) {
                if (f.dim !in musicalDims || f.score <= 0) continue
                val key = f.dim + "\u0000" + f.value
                val cur = acc[key] ?: (InThePocketTarget(f.dim, f.value, f.label, 0.0) to 0.0)
                acc[key] = cur.first to (cur.second + w * f.score)
            }
            val bpm = numeric["bpm"]
            if (bpm != null && (bpm.defining || bpm.coverage >= 0.6)) {
                bandLo += w * bpm.lo; bandHi += w * bpm.hi; bandW += w
            }
            for ((id, n) in songIds) seeds[id] = (seeds[id] ?: 0.0) + w * n
        }

        for (p in results.patterns) {
            val m = contextMatch(p.timeBucket, p.dayType, p.ctx, input.context)
            if (m <= 0) continue
            val w = m * (1 + ln(max(1, p.occurrences).toDouble()))
            absorb(p.features, p.numeric, p.topSongs.map { it.songId to max(1, it.plays).toDouble() },
                p.membership, p.collectionCandidates, w)
        }
        for (p in results.pockets) {
            val m = contextMatch(p.timeBucket, p.dayType, p.ctx, input.context)
            if (m <= 0) continue
            absorb(p.features, p.numeric, p.songIds.map { it to 1.0 }, p.membership, emptyList(), 0.5 * m)
        }
        if (!any) return null
        val band = if (bandW > 0) normalizedBand(bandLo / bandW, bandHi / bandW) else null
        if (acc.isEmpty() && band == null && seeds.isEmpty()) return null
        return Profile(
            InThePocketMode.CLOUD,
            normalize(acc.values.map { it.first.copy(weight = it.second) }),
            band, seeds, normalizeMembership(memb), boost,
        )
    }

    /**
     * The plays that describe "here, now": same time bucket + day type (narrowed to this place /
     * trip when it has enough), else same bucket — HISTORY; too few ⇒ every play, COLD.
     */
    fun contextBasis(input: Input): Pair<InThePocketMode, List<Play>> {
        val ctx = input.context
        val withCtx = input.plays.map { it to InThePocketContext.make(it.atMs, it.tzOffsetMin, null) }
        var inContext = withCtx.filter { it.second.timeBucket == ctx.timeBucket && it.second.dayType == ctx.dayType }.map { it.first }
        val here = ctx.ctxKey
        if (here != null) {
            val atPlace = inContext.filter { InThePocketContext.make(it.atMs, it.tzOffsetMin, it.ctx).ctxKey == here }
            if (atPlace.size >= MIN_CONTEXT_PLAYS) inContext = atPlace
        }
        if (inContext.size < MIN_CONTEXT_PLAYS) {
            inContext = withCtx.filter { it.second.timeBucket == ctx.timeBucket }.map { it.first }
        }
        val mode = if (inContext.size >= MIN_CONTEXT_PLAYS) InThePocketMode.HISTORY else InThePocketMode.COLD
        return mode to (if (mode == InThePocketMode.HISTORY) inContext else input.plays)
    }

    fun historyProfile(input: Input): Profile {
        val (mode, basis) = contextBasis(input)
        val kept = basis.filter { !it.isSkip }
        val allKept = input.plays.filter { !it.isSkip }

        fun shares(plays: List<Play>, key: (Song) -> List<String>): Map<String, Double> {
            val counts = LinkedHashMap<String, Double>()
            var n = 0.0
            for (p in plays) {
                val s = input.catalog[p.songId] ?: continue
                n += 1
                for (k in key(s)) counts[k] = (counts[k] ?: 0.0) + 1
            }
            if (n <= 0) return emptyMap()
            return counts.mapValues { it.value / n }
        }

        val targets = mutableListOf<InThePocketTarget>()
        val dims: List<Pair<String, (Song) -> List<String>>> = listOf(
            "genre" to { s: Song -> s.genre?.let { listOf(it) } ?: emptyList() },
            "artist" to { s: Song -> listOf(s.artist.lowercase()) },
        )
        for ((dim, key) in dims) {
            val here = shares(kept, key)
            val overall = shares(allKept, key)
            for ((value, share) in here) {
                if (share < 0.15) continue
                val lift = min(3.0, max(0.5, share / max(overall[value] ?: share, 0.01)))
                val label = if (dim == "genre") genreLabel(value) else {
                    kept.asSequence().mapNotNull { input.catalog[it.songId] }
                        .firstOrNull { it.artist.lowercase() == value }?.artist ?: value
                }
                targets.add(InThePocketTarget(dim, value, label, share * lift))
            }
        }
        val bpms = kept.mapNotNull { input.catalog[it.songId]?.let { s -> foldBpm(s.bpm) } }.sorted()
        val band = if (bpms.size >= 3) normalizedBand(bpms[bpms.size / 4], bpms[(bpms.size * 3) / 4]) else null
        val seeds = LinkedHashMap<String, Double>()
        for (p in basis) seeds[p.songId] = (seeds[p.songId] ?: 0.0) + (if (p.isSkip) -2.0 else 1.0)
        return Profile(mode, normalize(targets), band, seeds.filterValues { it > 0 })
    }

    /** Weights scaled so the strongest target is 1; top [MAX_TARGETS] by weight (ties → dim, value). */
    fun normalize(targets: List<InThePocketTarget>): List<InThePocketTarget> {
        val top = targets.filter { it.weight > 0 }.sortedWith(targetOrder).take(MAX_TARGETS)
        val m = top.firstOrNull()?.weight ?: return emptyList()
        if (m <= 0) return emptyList()
        return top.map { it.copy(weight = round3(it.weight / m)) }
    }

    /** A band at least 6 BPM wide, rounded to whole beats. */
    fun normalizedBand(lo: Double, hi: Double): ClosedFloatingPointRange<Double> {
        var a = roundHalfAway(min(lo, hi)); var b = roundHalfAway(max(lo, hi))
        if (b - a < 6) { val mid = (a + b) / 2; a = kotlin.math.floor(mid - 3); b = kotlin.math.ceil(mid + 3) }
        return a..b
    }

    // MARK: - Round learning

    data class Learned(val multiplier: Double, val pos: Int)

    /**
     * "dim\0value" → multiplier for this context: the cloud's `rounds` section (exact key, then
     * relaxed), else the SAME formula over this device's own finished rounds.
     */
    fun learning(input: Input): Map<String, Learned> {
        val keys = input.context.learningKeys
        input.results?.roundLearning?.let { cloud ->
            for (k in keys) {
                val c = cloud.contexts.firstOrNull { it.key == k } ?: continue
                val out = LinkedHashMap<String, Learned>()
                for (w in c.weights) out.putIfAbsent(w.dim + "\u0000" + w.value, Learned(w.multiplier, w.pos))
                return out
            }
        }
        val local = InThePocketLearning.contexts(input.pastRounds)
        for (k in keys) local[k]?.let { c -> return c.mapValues { Learned(it.value.multiplier, it.value.pos) } }
        return emptyMap()
    }

    /** Swift `split(separator:maxSplits:1)` — empty pieces omitted. */
    private fun splitKey(key: String): List<String> = key.split('\u0000', limit = 2).filter { it.isNotEmpty() }

    fun applyLearning(profile: Profile, input: Input): Profile {
        val learned = learning(input)
        if (learned.isEmpty()) return profile
        var membership = profile.membership
        // `collection` targets re-weight the membership vector: a collection that keeps predicting
        // well here pulls harder (and joins once it has ≥ 2 good rounds — only if this device still
        // has it), one that keeps breaking pulls less.
        if (membership.isNotEmpty() || input.collections.isNotEmpty()) {
            val known = input.collections.map { it.id }.toSet()
            val top = membership.values.maxOrNull() ?: 1.0
            val m = LinkedHashMap(membership)
            for ((key, l) in learned.toSortedMap()) {
                val parts = splitKey(key)
                if (parts.size != 2 || parts[0] != "collection") continue
                val w = m[parts[1]]
                if (w != null) m[parts[1]] = w * l.multiplier
                else if (l.multiplier >= LEARNING_ADD_MIN && l.pos >= 2 && parts[1] in known) m[parts[1]] = 0.3 * l.multiplier * top
            }
            if (m != membership) membership = normalizeMembership(m)
        }
        val targets = profile.targets.toMutableList()
        val present = HashSet<String>()
        for (i in targets.indices) {
            val key = targets[i].dim + "\u0000" + targets[i].value
            present.add(key)
            learned[key]?.let { targets[i] = targets[i].copy(weight = round3(targets[i].weight * it.multiplier)) }
        }
        for ((key, l) in learned.toSortedMap()) {
            if (key in present || l.multiplier < LEARNING_ADD_MIN || l.pos < 2) continue
            val parts = splitKey(key)
            if (parts.size != 2 || parts[0] !in musicalDims) continue
            val label = if (parts[0] == "genre") genreLabel(parts[1]) else capitalized(parts[1])
            targets.add(InThePocketTarget(parts[0], parts[1], label, round3(0.3 * l.multiplier)))
        }
        targets.sortWith(targetOrder)
        return profile.copy(targets = targets, membership = membership)
    }

    /** Foundation `capitalized`: first letter of each word upper, the rest lower. */
    private fun capitalized(s: String): String {
        val sb = StringBuilder()
        var start = true
        for (ch in s) {
            if (ch.isWhitespace()) { sb.append(ch); start = true; continue }
            sb.append(if (start) ch.uppercaseChar() else ch.lowercaseChar())
            start = false
        }
        return sb.toString()
    }

    // MARK: - Pieces

    fun matches(s: Song, t: InThePocketTarget): Boolean = when (t.dim) {
        "genre" -> s.genre?.lowercase() == t.value
        "artist" -> s.artist.lowercase() == t.value
        "mood" -> s.moods.any { it.lowercase() == t.value }
        "camelot" -> s.camelot?.uppercase() == t.value.uppercase()
        else -> false
    }

    /** `memberOf` = a song's hard collection memberships (none ⇒ the pre-collections coherence). */
    fun coherence(s: Song, picked: List<Pick>, memberOf: (String) -> Set<String> = { emptySet() }): Double {
        var c = 0.0
        val mine = memberOf(s.id)
        if (mine.isNotEmpty() && picked.isNotEmpty()) {
            var j = 0.0
            for (p in picked) {
                val theirs = memberOf(p.song.id)
                if (theirs.isEmpty()) continue
                j += mine.intersect(theirs).size.toDouble() / mine.union(theirs).size.toDouble()
            }
            c += COHERENCE_MEMBERSHIP_WEIGHT * j / picked.size
        }
        val g = s.genre
        if (g != null && picked.any { it.song.genre == g }) c += 0.3
        val bpms = picked.mapNotNull { foldBpm(it.song.bpm) }
        val b = foldBpm(s.bpm)
        if (b != null && bpms.isNotEmpty()) {
            val mean = bpms.sum() / bpms.size
            c += 0.3 * exp(-abs(b - mean) / 10)
        }
        val sameArtist = picked.count { it.song.artist.lowercase() == s.artist.lowercase() }
        c -= sameArtist
        return c
    }

    /** Per song: 0.6·(play-through rate − ½) + 0.3·min(plays,5)/5 — Laplace-smoothed. */
    fun familiarity(plays: List<Play>): Map<String, Double> {
        val through = HashMap<String, Int>(); val skips = HashMap<String, Int>()
        for (p in plays) {
            if (p.isSkip) skips.merge(p.songId, 1, Int::plus) else through.merge(p.songId, 1, Int::plus)
        }
        val out = HashMap<String, Double>()
        for (id in through.keys + skips.keys) {
            val n = (through[id] ?: 0).toDouble(); val k = (skips[id] ?: 0).toDouble()
            val rate = (n + 1) / (n + k + 2)
            out[id] = 0.6 * (rate - 0.5) + 0.3 * min(n, 5.0) / 5
        }
        return out
    }

    /** Seeded draw proportional to max(score, 0.01)². Returns the pool index. */
    fun weightedDraw(window: List<Pair<Int, Double>>, rng: SplitMix64): Int {
        val weights = window.map { max(it.second, 0.01).pow(2) }
        val total = weights.sum()
        var r = rng.nextUnit() * total
        for ((i, w) in weights.withIndex()) {
            r -= w
            if (r < 0) return window[i].first
        }
        return window[window.size - 1].first
    }

    /** Fold a tempo into [80, 160) by doubling/halving — the cloud's `foldBpm`. */
    fun foldBpm(b: Double?): Double? {
        var x = b ?: return null
        if (!x.isFinite() || x <= 0) return null
        while (x < 80) x *= 2
        while (x >= 160) x /= 2
        return x
    }

    fun genreLabel(g: String): String = when (g) {
        "r&b" -> "R&B"
        "edm" -> "EDM"
        "hip-hop" -> "Hip-Hop"
        else -> g.replaceFirstChar { it.uppercase() }
    }

    fun chips(input: Input, profile: Profile): List<String> {
        val out = mutableListOf(input.context.timePhrase)
        input.contextLabel?.let { out.add(it) }
        profile.bpmBand?.let { out.add("${it.start.toInt()}–${it.endInclusive.toInt()} BPM") }
        val genres = profile.targets.filter { it.dim == "genre" }.take(2).map { it.label }
        if (genres.isNotEmpty()) out.add(genres.joinToString("/"))
        else profile.targets.firstOrNull { it.dim == "artist" }?.let { out.add(it.label) }
        return out
    }

    // Membership half lives in InThePocketMembership.kt (same object, split for size).
    internal fun normalizeMembership(m: Map<String, Double>) = InThePocketMembership.normalizeMembership(m)
    internal fun applyMembership(p: Profile, input: Input, index: MembershipIndex) = InThePocketMembership.applyMembership(p, input, index)
    internal fun collectionTargets(m: Map<String, Double>, index: MembershipIndex) = InThePocketMembership.collectionTargets(m, index)
}

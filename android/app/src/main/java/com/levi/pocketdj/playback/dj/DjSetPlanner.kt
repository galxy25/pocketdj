package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.data.recs.SimilarityFamilies
import com.levi.pocketdj.screens.browse.Genre
import java.util.UUID

/**
 * The PocketDJ selector: re-orders a Now Playing session's upcoming rows into 10-BPM tempo waves
 * and genre/year/collection pockets. Pure; port of iOS `DJSetPlanner` (Playback/DJSetPlanner.swift),
 * including artist spacing 4 + the scarcity rule and aging. Same `(current, upcoming, state,
 * options)` yields the same order on both platforms.
 */
object DjSetPlanner {

    /** One upcoming row. `bpm` is RAW (folded by [DjFeatures.of]); `genre` is the tier-1 category. */
    data class Candidate(
        val uid: UUID = UUID.randomUUID(),
        val songId: String,
        val bpm: Double? = null,
        val camelot: String? = null,
        val genre: String? = null,
        val year: Int? = null,
        val collections: Set<String> = emptySet(),
        val fixed: Boolean = false,
        val artists: Set<String> = emptySet(),
        /** AGING: how many earlier plans pushed this row later. */
        val deferrals: Int = 0,
        /** The LISTENER chose this song: the set re-anchors on it. */
        val anchor: Boolean = false,
    ) {
        val features: DjFeatures get() = DjFeatures.of(bpm, camelot, genre, year, collections)
    }

    /** Builds a [Candidate] from RAW app-model values (genre mapped through `Genre.category`). */
    fun candidate(
        uid: UUID, songId: String, bpm: Double?, camelot: String?, rawGenre: String?, year: Int?,
        collections: Set<String>, fixed: Boolean, artists: Set<String> = emptySet(),
    ): Candidate {
        val cat = Genre.category(rawGenre)
        return Candidate(
            uid = uid, songId = songId, bpm = bpm, camelot = camelot,
            genre = if (cat == Genre.OTHER) null else cat,
            year = if ((year ?: 0) > 0) year else null,
            collections = collections, fixed = fixed, artists = artists,
        )
    }

    data class Options(
        val tempoWaves: Boolean = true,
        val pockets: Boolean = true,
        val key: Boolean = true,
    ) {
        companion object { val ALL_ON = Options() }
    }

    const val BAND_WIDTH = 10
    const val MIN_PER_BAND = 3
    const val WEIGHT_BAND = 0.35
    const val WEIGHT_BPM = 0.2
    const val WEIGHT_KEY = 0.2
    const val WEIGHT_POCKET = 0.25
    const val ORDER_BONUS = 0.02
    const val AGING_BONUS = 0.03
    const val NEUTRAL_SCORE = 0.5
    val NEAR_ADJACENT: ClosedFloatingPointRange<Double> = 0.3..0.8
    const val ARTIST_SPACING = 4

    /** Band steps per wave (2 or 3), deterministic per seed + wave index. */
    fun waveLength(seed: ULong, index: Int): Int = 2 + (hash(seed, 0x57A7EuL, index) % 2uL).toInt()

    /** Songs per pocket (3 or 4), deterministic per seed + pocket index. */
    fun pocketLength(seed: ULong, index: Int): Int = 3 + (hash(seed, 0x90C4E7uL, index) % 2uL).toInt()

    /** SplitMix64 finalizer over (seed, salt, index) - the planner's only source of variety. */
    fun hash(seed: ULong, salt: ULong, index: Int): ULong {
        var z = seed + salt * 0x9E37_79B9_7F4A_7C15uL + index.toLong().toULong() * 0xD6E8_FEB8_6659_FD93uL
        z = (z xor (z shr 30)) * 0xBF58_476D_1CE4_E5B9uL
        z = (z xor (z shr 27)) * 0x94D0_49BB_1331_11EBuL
        return z xor (z shr 31)
    }

    data class Plan(val order: List<UUID>, val state: DjPlannerState)

    /**
     * Re-orders [upcoming]. Every upcoming uid exactly once, `fixed` rows at their original
     * indexes, plus the state with `current` accounted. [state] is not mutated.
     */
    fun plan(current: Candidate?, upcoming: List<Candidate>, state: DjPlannerState, options: Options): Plan {
        val committed = state.copy()
        var prev: DjFeatures? = null
        if (current != null) {
            if (current.anchor) committed.reanchor(current.features, current.uid, options)
            else committed.account(current.features, current.uid, options)
            prev = current.features
        }
        if (upcoming.isEmpty()) return Plan(emptyList(), committed)

        val n = upcoming.size
        val feats = upcoming.map { it.features }
        val aged = upcoming.map { it.deferrals }
        val free = upcoming.indices.filter { !upcoming[it].fixed }.toMutableSet()
        val sim = committed.copy()
        val order = ArrayList<UUID>(n)
        val recentArtists = ArrayList<Set<String>>()
        if (current != null) recentArtists.add(current.artists)

        for (slot in 0 until n) {
            val pick: Int
            if (upcoming[slot].fixed) {
                pick = slot
            } else {
                val blocked = HashSet<String>()
                for (s in recentArtists) blocked.addAll(s)
                var spaced = free.filter { i -> upcoming[i].artists.none { it in blocked } }
                // Scarcity: an artist with too many rows left plays as soon as spacing allows.
                val left = HashMap<String, Int>()
                for (i in free) for (a in upcoming[i].artists) left[a] = (left[a] ?: 0) + 1
                val urgent = spaced.filter { i ->
                    upcoming[i].artists.any { ((left[it] ?: 0) - 1) * ARTIST_SPACING + 1 >= free.size }
                }
                if (urgent.isNotEmpty()) spaced = urgent
                pick = best(if (spaced.isEmpty()) free else spaced.toSet(), feats, aged, n, prev, sim, options)
                free.remove(pick)
            }
            recentArtists.add(upcoming[pick].artists)
            if (recentArtists.size > ARTIST_SPACING - 1) recentArtists.removeAt(0)
            order.add(upcoming[pick].uid)
            if (upcoming[pick].anchor) sim.reanchor(feats[pick], upcoming[pick].uid, options)
            else sim.account(feats[pick], upcoming[pick].uid, options)
            prev = carried(prev, feats[pick])
        }
        return Plan(order, committed)
    }

    /** The "previous song" with the last KNOWN tempo and key carried through songs lacking them. */
    private fun carried(prev: DjFeatures?, f: DjFeatures): DjFeatures =
        f.copy(bpm = f.bpm ?: prev?.bpm, camelot = f.camelot ?: prev?.camelot)

    private sealed interface PocketMode {
        data object Off : PocketMode
        data class InPocket(val anchor: DjFeatures) : PocketMode
        data class NearAdjacent(val anchor: DjFeatures) : PocketMode
    }

    private fun best(
        free: Set<Int>, feats: List<DjFeatures>, aged: List<Int>, n: Int, prev: DjFeatures?,
        sim: DjPlannerState, options: Options,
    ): Int {
        val target = if (options.tempoWaves) sim.resolveTarget(free.mapNotNull { feats[it].band }) else null

        var pocketMode: PocketMode = PocketMode.Off
        if (options.pockets) {
            val anchor = sim.pocketAnchor
            if (anchor != null) {
                pocketMode = if (sim.needsNewPocket) {
                    val anyNear = free.any { i -> similarity(feats[i], anchor)?.let { it in NEAR_ADJACENT } ?: false }
                    if (anyNear) PocketMode.NearAdjacent(anchor) else PocketMode.Off
                } else PocketMode.InPocket(anchor)
            }
        }

        var bestIndex = -1
        var bestScore = Double.NEGATIVE_INFINITY
        for (i in free.sorted()) {
            val s = score(feats[i], i, n, prev, target, pocketMode, options) +
                AGING_BONUS * maxOf(0, aged[i]).toDouble()
            if (s > bestScore) { bestScore = s; bestIndex = i }
        }
        return bestIndex
    }

    private fun score(
        f: DjFeatures, index: Int, n: Int, prev: DjFeatures?, target: Int?,
        pocket: PocketMode, options: Options,
    ): Double {
        var sum = 0.0
        var weight = 0.0
        if (options.tempoWaves) {
            val b = f.band
            if (target != null && b != null) {
                val d = Math.abs(b - target)
                sum += WEIGHT_BAND * (if (d == 0) 1.0 else if (d == BAND_WIDTH) 0.4 else 0.0)
                weight += WEIGHT_BAND
            }
            val pa = prev?.bpm
            val fb = f.bpm
            if (pa != null && fb != null) {
                sum += WEIGHT_BPM * Math.exp(-Math.abs(pa - fb) / 10)
                weight += WEIGHT_BPM
            }
        }
        if (options.key) {
            val a = prev?.camelot
            val b = f.camelot
            if (a != null && b != null) {
                sum += WEIGHT_KEY * SimilarityFamilies.camelotRelatedness(a, b)
                weight += WEIGHT_KEY
            }
        }
        when (pocket) {
            PocketMode.Off -> {}
            is PocketMode.InPocket -> similarity(f, pocket.anchor)?.let { sum += WEIGHT_POCKET * it; weight += WEIGHT_POCKET }
            is PocketMode.NearAdjacent -> similarity(f, pocket.anchor)?.let {
                sum += WEIGHT_POCKET * (if (it in NEAR_ADJACENT) 1.0 else 0.0)
                weight += WEIGHT_POCKET
            }
        }
        val base = if (weight > 0) sum / weight else NEUTRAL_SCORE
        return base + ORDER_BONUS * (1 - index.toDouble() / maxOf(n, 1).toDouble())
    }

    /** Pocket similarity: genre (1/0), year exp(-|dy|/6), collections Jaccard; averaged over shared parts. */
    fun similarity(a: DjFeatures, b: DjFeatures): Double? {
        var sum = 0.0
        var count = 0.0
        val ga = a.genre; val gb = b.genre
        if (ga != null && gb != null) { sum += if (ga == gb) 1.0 else 0.0; count += 1 }
        val ya = a.year; val yb = b.year
        if (ya != null && yb != null) { sum += Math.exp(-Math.abs(ya - yb).toDouble() / 6); count += 1 }
        if (a.collections.isNotEmpty() && b.collections.isNotEmpty()) {
            val inter = a.collections.intersect(b.collections).size
            val union = a.collections.union(b.collections).size
            sum += inter.toDouble() / union.toDouble(); count += 1
        }
        return if (count > 0) sum / count else null
    }

    /** "8a" / " 08B " -> "8A" / "8B"; null when not a Camelot code. */
    fun normalizedCamelot(raw: String): String? {
        val s = raw.trim(' ', '\t').uppercase()
        val letter = s.lastOrNull() ?: return null
        if (letter != 'A' && letter != 'B') return null
        val n = s.dropLast(1).toIntOrNull() ?: return null
        if (n !in 1..12) return null
        return "$n$letter"
    }
}

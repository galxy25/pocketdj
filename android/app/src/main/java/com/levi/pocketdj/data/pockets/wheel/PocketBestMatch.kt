package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.games.inthepocket.InThePocketContext
import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource
import com.levi.pocketdj.data.pockets.ListeningContextTag
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * The centre play button (iOS `PocketBestMatch`, design §10.3): score every cell against NOW (time, day, mode, place,
 * previous activity), pick the best, and fall back through the cold-start tiers. PURE (no clock, no Android).
 */
object PocketBestMatch {

    data class Now(
        /** Local fractional hour and ISO weekday. */
        val hour: Double,
        val dow: Int,
        /** null = unknown (the surface modes are not inferable while looking at the wheel). */
        val mode: PocketMode? = null,
        /** "place:..." / "trip:..." ([PocketMomentEngine.contextKey]), or null. */
        val ctx: String? = null,
        /** Collection attribution of the last 45 min of plays (empty = none). */
        val recentCollections: Map<String, Double> = emptyMap(),
        /** Skip rate over those plays (null = none). */
        val recentSkipRate: Double? = null,
    ) {
        val isWeekend: Boolean get() = dow >= 6
    }

    data class Scored(val key: PocketMomentKey, val match: Double, val quality: Double, val continuity: Double, val score: Double)

    data class Result(
        val profile: PocketProfile,
        val winner: Scored?,
        /** Up to 3 runners-up with a DIFFERENT dominant collection. */
        val alternatives: List<PocketProfile>,
    )

    /** Optional extra profiles for the cloud / empty tiers (the caller builds them; null => skip). */
    data class Fallbacks(
        /** T2: the cloud scorer's profile, converted (opt-in on + patterns match the bucket). */
        val cloud: PocketProfile? = null,
        /** T4: the most recently played collection, else Favorites, else For You's top tile. */
        val empty: PocketProfile? = null,
        /** Cloud patterns with round-learning `pocketRate >= 0.5` (x1.15 boost). */
        val boostedPatternIds: Set<String> = emptySet(),
    )

    // Tuning

    const val richMinMatch = 0.35
    const val richMinPlays = 3.0
    const val neighbourhoodHours = 3.0
    const val neighbourhoodMinPlays = 5
    const val coldMinPlays = 20
    const val continuityWeight = 0.35
    const val cloudBoost = 1.15
    const val skipStreakRate = 0.5

    /** The recent-activity window (last 45 minutes of plays). */
    const val recentWindowMs = 45 * 60_000.0

    // Kernels

    fun circularHours(a: Double, b: Double): Double {
        val d = abs(a - b) % 24
        return min(d, 24 - d)
    }

    fun kt(now: Now, k: PocketMomentKey): Double {
        val dh = circularHours(now.hour, k.hour.toDouble() + 0.5)
        return exp(-dh * dh / 2)
    }

    fun kd(now: Now, k: PocketMomentKey): Double {
        if (k.dow == now.dow) return 1.0
        return if (k.isWeekend == now.isWeekend) 0.6 else 0.25
    }

    fun km(now: Now, k: PocketMomentKey): Double {
        val m = now.mode ?: return 0.6
        if (m == k.mode) return 1.0
        return if (m.related == k.mode) 0.7 else 0.35
    }

    fun kl(now: Now, m: PocketMoment): Double {
        val ctx = now.ctx
        if (ctx == null || m.ctx.isEmpty()) return 1.0
        return 0.3 + 0.7 * (m.ctx[ctx] ?: 0.0)
    }

    fun quality(m: PocketMoment): Double =
        m.confidence * (1 - m.skipRate).pow(1.5) * (if (m.isRecurring) 1.0 else 0.7)

    fun cosine(a: Map<String, Double>, b: Map<String, Double>): Double {
        if (a.isEmpty() || b.isEmpty()) return 0.0
        var dot = 0.0
        for ((k, v) in a) dot += v * (b[k] ?: 0.0)
        val na = sqrt(a.values.sumOf { it * it })
        val nb = sqrt(b.values.sumOf { it * it })
        return if (na > 0 && nb > 0) dot / (na * nb) else 0.0
    }

    fun score(m: PocketMoment, now: Now, boosted: Set<String>): Scored {
        val match = kt(now, m.key) * kd(now, m.key) * km(now, m.key) * kl(now, m)
        val q = quality(m)
        var cont = cosine(now.recentCollections, m.collections)
        val r = now.recentSkipRate
        if (r != null && r > skipStreakRate) cont = -cont // unhappy => steer away
        var s = match * (0.4 + 0.6 * q) + continuityWeight * cont * sqrt(match)
        if (boosted.isNotEmpty() && m.cloudPatternIds.any { it in boosted }) s *= cloudBoost
        return Scored(m.key, match, q, cont, s)
    }

    // Best match + tiers

    fun best(snapshot: PocketWheelSnapshot, now: Now, fallbacks: Fallbacks = Fallbacks()): Result {
        val candidates = snapshot.moments.filter { it.plays > 0 }
        val index = snapshot.index()
        val ranked = candidates.map { score(it, now, fallbacks.boostedPatternIds) }
            .sortedWith { x, y ->
                if (x.score != y.score) return@sortedWith y.score.compareTo(x.score)
                val a = index[x.key]?.lastSeenMs ?: 0.0
                val b = index[y.key]?.lastSeenMs ?: 0.0
                if (a != b) b.compareTo(a) else x.key.compareTo(y.key)
            }
        val names = snapshot.collectionNames

        fun alternatives(dominant: String?): List<PocketProfile> {
            val seen = HashSet<String>()
            dominant?.let { seen += it }
            val out = ArrayList<PocketProfile>()
            for (s in ranked.drop(1)) {
                val m = index[s.key] ?: continue
                val d = m.dominantCollectionId ?: continue
                if (d in seen) continue
                seen += d
                out += PocketProfile.from(m, names)
                if (out.size == 3) break
            }
            return out
        }

        // T0 - a rich winner.
        val w = ranked.firstOrNull()
        val wm = w?.let { index[it.key] }
        if (w != null && wm != null && w.match >= richMinMatch && wm.plays >= richMinPlays) {
            return Result(PocketProfile.from(wm, names), w, alternatives(wm.dominantCollectionId))
        }
        // T1 - the neighbourhood: same day type within +-3 h has >= 5 plays -> blend the top 5.
        val near = candidates.filter {
            it.key.isWeekend == now.isWeekend && circularHours(now.hour, it.key.hour.toDouble() + 0.5) <= neighbourhoodHours
        }
        if (near.sumOf { it.directPlays } >= neighbourhoodMinPlays) {
            val nearKeys = near.map { it.key }.toSet()
            val top = ranked.filter { it.key in nearKeys }.take(5)
            val profile = blend(
                top.mapNotNull { s -> index[s.key]?.let { it to max(s.score, 1e-6) } },
                PocketProfile.Tier.NEIGHBOURHOOD, neighbourhoodPhrase(now), names,
            )
            return Result(profile, top.firstOrNull(), alternatives(profile.dominantCollectionId))
        }
        // T2 - the cloud's listening pockets.
        fallbacks.cloud?.let { return Result(it, null, emptyList()) }
        // T3 - the whole history, recency-weighted.
        if (snapshot.totalDirectPlays >= coldMinPlays) {
            val all = candidates.map { m ->
                m to m.plays * exp(-max(0.0, snapshot.builtAtMs - m.lastSeenMs) / (30 * 86_400_000.0))
            }.filter { it.second > 0 }
            val profile = blend(all, PocketProfile.Tier.HISTORY, "Your recent favourites", names)
            return Result(profile, null, alternatives(profile.dominantCollectionId))
        }
        // T4 - nothing: fav_songs / most recent collection when the caller supplies it.
        val empty = fallbacks.empty ?: PocketProfile(
            tier = PocketProfile.Tier.EMPTY, caption = "Getting to know you", detail = "Play for a week to paint your wheel",
        )
        return Result(empty, null, emptyList())
    }

    /** Weighted blend of moments into one profile (T1 / T3). */
    fun blend(parts: List<Pair<PocketMoment, Double>>, tier: PocketProfile.Tier, caption: String, names: Map<String, String>): PocketProfile {
        val colls = HashMap<String, Double>()
        val artists = HashMap<String, Double>()
        val genres = HashMap<String, Double>()
        val seeds = HashMap<String, Double>()
        var bLo = 0.0; var bHi = 0.0; var bW = 0.0
        var eLo = 0.0; var eHi = 0.0; var eW = 0.0
        var timbreBest: Pair<PocketMoment, Double>? = null
        var plays = 0
        val modeW = HashMap<PocketMode, Double>()
        for ((m, w) in parts) {
            for ((k, v) in m.collections) colls[k] = (colls[k] ?: 0.0) + w * v
            for ((k, v) in m.artists) artists[k] = (artists[k] ?: 0.0) + w * v
            for ((k, v) in m.genres) genres[k] = (genres[k] ?: 0.0) + w * v
            for ((k, v) in m.seeds) seeds[k] = (seeds[k] ?: 0.0) + w * v
            val bl = m.bpmLo; val bh = m.bpmHi
            if (bl != null && bh != null) { bLo += w * bl; bHi += w * bh; bW += w }
            val el = m.eraLo; val eh = m.eraHi
            if (el != null && eh != null) { eLo += w * el; eHi += w * eh; eW += w }
            if (m.timbreCentroid != null && w > (timbreBest?.second ?: 0.0)) timbreBest = m to w
            plays += m.directPlays
            modeW[m.key.mode] = (modeW[m.key.mode] ?: 0.0) + w
        }
        var p = PocketProfile(
            tier = tier, key = null, momentKeys = parts.map { it.first.key }, caption = caption, detail = "",
            collections = PocketMomentEngine.topNormalized(colls, 8),
            artists = PocketMomentEngine.topNormalized(artists, 8),
            genres = PocketMomentEngine.topNormalized(genres, 8),
            seeds = PocketMomentEngine.topRaw(seeds, 60),
        )
        if (bW > 0) p = p.copy(bpmLo = roundHalfAwayD(bLo / bW), bpmHi = roundHalfAwayD(bHi / bW))
        if (eW > 0) p = p.copy(eraLo = eLo / eW, eraHi = eHi / eW)
        timbreBest?.first?.let { t ->
            p = p.copy(timbreCentroid = t.timbreCentroid, timbreSpread = t.timbreSpread, timbreVectors = t.timbreVectors)
        }
        val mode = modeW.entries.minWithOrNull(compareByDescending<Map.Entry<PocketMode, Double>> { it.value }.thenBy { it.key.rank })?.key
        return p.copy(mode = mode, detail = PocketProfile.detail(p.dominantCollectionId, plays, names))
    }

    private fun roundHalfAwayD(x: Double): Double = if (x < 0) -kotlin.math.floor(-x + 0.5) else kotlin.math.floor(x + 0.5)

    /** "Potential . 23 plays". */
    fun detail(collectionId: String?, plays: Int, names: Map<String, String>): String =
        PocketProfile.detail(collectionId, plays, names)

    /** "Weekday mornings" / "Weekend evenings". */
    fun neighbourhoodPhrase(now: Now): String {
        val plural = when (InThePocketContext.timeBucket(now.hour)) {
            "morning" -> "mornings"
            "midday" -> "middays"
            "afternoon" -> "afternoons"
            "evening" -> "evenings"
            else -> "nights"
        }
        return (if (now.isWeekend) "Weekend " else "Weekday ") + plural
    }

    /**
     * `mode_now` (iOS §3.1): car projection (Android Auto) connected -> carPlay; running/walking in the last 5 min ->
     * that; vehicle / cycling or a trip guess -> trip; else unknown.
     */
    fun modeNow(carPlayConnected: Boolean, motion: String?, contextGuess: ListeningContextTag?): PocketMode? {
        if (carPlayConnected) return PocketMode.CAR_PLAY
        if (motion == MotionToken.RUNNING) return PocketMode.RUNNING
        if (motion == MotionToken.WALKING) return PocketMode.WALKING
        if (motion == MotionToken.AUTOMOTIVE || motion == MotionToken.CYCLING || contextGuess?.isTrip == true) return PocketMode.TRIP
        return null
    }

    /** The previous-activity inputs (iOS §3.1) from the last 45 minutes of plays; [events] are oldest-first. */
    fun recentActivity(
        events: List<PlayEvent>,
        nowMs: Double,
        attribute: (PlayEvent) -> Map<String, Double>,
        windowMs: Double = recentWindowMs,
    ): Pair<Map<String, Double>, Double?> {
        val colls = HashMap<String, Double>()
        var n = 0
        var skips = 0
        for (e in events.asReversed()) {
            if (nowMs - e.playedAt > windowMs) break
            if (e.source == PlaySource.GAME || e.playedAt > nowMs) continue
            n++
            if (e.wasSkipped == true) { skips++; continue }
            for ((k, v) in attribute(e)) colls[k] = (colls[k] ?: 0.0) + v
        }
        return colls to (if (n > 0) skips.toDouble() / n else null)
    }

    /** Convert the cloud scorer's profile (T2) - exactly `InThePocketScorer`'s CLOUD builder. */
    fun cloudProfile(p: InThePocketScorer.Profile): PocketProfile {
        val artists = HashMap<String, Double>()
        val genres = HashMap<String, Double>()
        for (t in p.targets) {
            if (t.dim == "artist") artists[t.value] = t.weight
            if (t.dim == "genre") genres[t.value] = t.weight
        }
        return PocketProfile(
            tier = PocketProfile.Tier.CLOUD, caption = "From your listening pockets", detail = "Patterns the cloud found",
            collections = PocketMomentEngine.topNormalized(p.membership, 8),
            artists = PocketMomentEngine.topNormalized(artists, 8),
            genres = PocketMomentEngine.topNormalized(genres, 8),
            bpmLo = p.bpmBand?.start, bpmHi = p.bpmBand?.endInclusive,
            seeds = p.seedSongs, candidateBoost = p.candidateBoost,
        )
    }
}

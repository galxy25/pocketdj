package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.data.games.inthepocket.InThePocketScorer
import com.levi.pocketdj.data.recs.SimilarityFamilies
import kotlinx.serialization.Serializable
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * What a pocket run LEARNS (iOS `PocketTuning`): per-feature evidence from the run's verdicts turned into score
 * multipliers, an artist ban for the rest of the run, and a negative timbre profile; plus the cross-run fold. PURE.
 *
 * P2-POC-7 lands the planner-facing half (Features, Evidence, Multipliers, formulas, fold) because the planner scores
 * with [Multipliers]; P2-POC-8 owns this file and adds `verdicts(from play history)` and the store wiring.
 */
object PocketTuning {

    /** The features a song is judged on. Built once per candidate by the planner's input builder. */
    data class Features(
        val artistKeys: List<String>,
        val album: String? = null,
        val genre: String? = null,
        val year: Int? = null,
        val bpm: Double? = null,
        val collectionId: String? = null,
        val timbre: Map<String, Double>? = null,
    ) {
        /** "artist:drake", "album:alb_1", "genre:r&b", "era:2015", "bpm:96", "collection:pl_x". */
        val keys: List<String>
            get() {
                val out = artistKeys.mapTo(ArrayList()) { "artist:$it" }
                album?.let { out.add("album:$it") }
                genre?.let { out.add("genre:$it") }
                year?.let { if (it > 0) out.add("era:${it / 5 * 5}") }
                InThePocketScorer.foldBpm(bpm)?.let { out.add("bpm:${it.toInt() / 8 * 8}") }
                collectionId?.let { out.add("collection:$it") }
                return out
            }
    }

    /** One finished run row's verdict. */
    data class Verdict(
        val songId: String,
        val skipped: Boolean,
        val fraction: Double?,
        val atMs: Double,
        val momentKey: String,
        val rowCollectionId: String? = null,
    ) {
        /** Fast skip -1.0, skip -0.6, completed +0.5, partial +0.2; null = no verdict yet. */
        val strength: Double?
            get() {
                if (skipped) return if ((fraction ?: 0.0) < 0.15) -1.0 else -0.6
                val f = fraction ?: return null
                if (f >= 0.9) return 0.5
                if (f >= 0.5) return 0.2
                return -0.6
            }
    }

    /** Per-feature evidence sums. */
    @Serializable
    data class Evidence(
        val pos: MutableMap<String, Double> = LinkedHashMap(),
        val neg: MutableMap<String, Double> = LinkedHashMap(),
        /** Vectors of skipped rows (the run's NEGATIVE timbre profile). */
        val skippedVectors: MutableList<Map<String, Double>> = ArrayList(),
    ) {
        fun add(keys: List<String>, strength: Double, scale: Double = 1.0, vector: Map<String, Double>? = null) {
            for (k in keys) {
                if (strength > 0) pos[k] = (pos[k] ?: 0.0) + strength * scale
                else neg[k] = (neg[k] ?: 0.0) + -strength * scale
            }
            if (strength < 0 && vector != null && scale >= 1) skippedVectors.add(vector)
        }

        fun merge(o: Evidence, scale: Double) {
            for ((k, v) in o.pos) pos[k] = (pos[k] ?: 0.0) + v * scale
            for ((k, v) in o.neg) neg[k] = (neg[k] ?: 0.0) + v * scale
        }
    }

    /** The multipliers a score is multiplied by, the ban list, and the negative sound. */
    data class Multipliers(
        val byKey: Map<String, Double> = emptyMap(),
        val bannedArtists: Set<String> = emptySet(),
        val negativeTimbre: SimilarityFamilies.TimbreProfile? = null,
    ) {
        /** Product of multipliers over a song's features. */
        fun factor(f: Features): Double {
            var x = 1.0
            for (k in f.keys) x *= byKey[k] ?: 1.0
            return x
        }

        fun isBanned(f: Features): Boolean = f.artistKeys.any { it in bannedArtists }

        companion object {
            val NEUTRAL = Multipliers()
        }
    }

    const val BAN_AT_OR_BELOW = 0.35

    /** Artist / album: NEGATIVE evidence counts double (1 fast skip = 0.333, 2 ordinary skips = 0.294 -> banned). */
    fun artistMultiplier(pos: Double, neg: Double): Double = clamp(2 * (pos + 0.5) / (pos + 2 * neg + 1), 0.15, 1.6)
    fun collectionMultiplier(pos: Double, neg: Double): Double = clamp(2 * (pos + 2) / (pos + neg + 4), 0.5, 1.4)
    fun musicalMultiplier(pos: Double, neg: Double): Double = clamp(2 * (pos + 1) / (pos + neg + 2), 0.35, 1.5)
    fun clamp(x: Double, lo: Double, hi: Double): Double = min(hi, max(lo, x))

    /** Evidence -> multipliers. `allowBans` is true inside a run and FALSE across runs (W5). */
    fun multipliers(e: Evidence, allowBans: Boolean): Multipliers {
        val byKey = LinkedHashMap<String, Double>()
        val banned = LinkedHashSet<String>()
        for (k in e.pos.keys + e.neg.keys) {
            val p = e.pos[k] ?: 0.0
            val n = e.neg[k] ?: 0.0
            val m = when {
                k.startsWith("artist:") || k.startsWith("album:") -> artistMultiplier(p, n)
                k.startsWith("collection:") -> collectionMultiplier(p, n)
                else -> musicalMultiplier(p, n)
            }
            byKey[k] = floor(m * 1000 + 0.5) / 1000
            if (allowBans && k.startsWith("artist:") && m <= BAN_AT_OR_BELOW) banned.add(k.drop(7))
        }
        val neg = SimilarityFamilies.timbreProfile(
            e.skippedVectors.map { SimilarityFamilies.TimbreMember(it, 1.0) }, minVectors = 1,
        )
        return Multipliers(byKey, banned, neg)
    }

    /** One run's evidence from its verdicts. */
    fun runEvidence(verdicts: List<Verdict>, features: (String) -> Features?): Evidence {
        val e = Evidence()
        for (v in verdicts) {
            val s = v.strength ?: continue
            var f = features(v.songId) ?: continue
            v.rowCollectionId?.let { f = f.copy(collectionId = it) }
            e.add(f.keys, s, vector = f.timbre)
        }
        return e
    }

    const val FOLD_HALF_LIFE_DAYS = 30.0
    const val RELATED_SCALE = 0.5
    const val GLOBAL_SCALE = 0.15

    /** Is moment [b] a smoothing-kernel neighbour of [a]? */
    fun isRelated(a: PocketMomentKey, b: PocketMomentKey): Boolean {
        if (a == b) return false
        val ha = (a.dow - 1) * 24 + a.hour
        val hb = (b.dow - 1) * 24 + b.hour
        val dh = min((ha - hb + 168) % 168, (hb - ha + 168) % 168)
        if (a.mode == b.mode && dh <= 2) return true
        if (a.mode == b.mode && a.hour == b.hour && a.isWeekend == b.isWeekend) return true
        if (a.hour == b.hour && a.dow == b.dow && a.mode.related == b.mode) return true
        return false
    }

    /** The prior evidence a NEW run of [moment] starts with: own x1, related x0.5, everything x0.15, 30-day half-life. */
    fun fold(verdicts: List<Verdict>, moment: PocketMomentKey?, nowMs: Double, features: (String) -> Features?): Evidence {
        val e = Evidence()
        for (v in verdicts) {
            val s = v.strength ?: continue
            var f = features(v.songId) ?: continue
            v.rowCollectionId?.let { f = f.copy(collectionId = it) }
            val decay = 0.5.pow(max(0.0, nowMs - v.atMs) / 86_400_000.0 / FOLD_HALF_LIFE_DAYS)
            var scale = GLOBAL_SCALE
            val k = PocketMomentKey.fromToken(v.momentKey)
            if (moment != null && k != null) {
                if (k == moment) scale = 1.0 else if (isRelated(moment, k)) scale = RELATED_SCALE
            }
            e.add(f.keys, s, scale = scale * decay, vector = if (scale == 1.0) f.timbre else null)
        }
        return e
    }
}

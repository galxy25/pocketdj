package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.games.puzzle.PuzzleSimilarity
import com.levi.pocketdj.screens.browse.Genre
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Port of iOS `SimilarityFamilies` (Services/Recommendations/SimilarityFamilies.swift): the
 * three comparable families — A artist, B genre+year, C genre+bpm+key — expressed as pure math.
 * Each family is the MEAN of its fields, so the blend is exactly term-separable
 * (`wA·artist + (wB/2+wC/2)·genre + (wB/2)·year + (wC/2)·musical`). Constants are verbatim from
 * iOS; every one of them is calibrated against the real catalog, do not retune.
 */
object SimilarityFamilies {

    // ── Balance + term weights ─────────────────────────────────────────────────────────────

    data class Balance(val artist: Double, val genreYear: Double, val genreMusical: Double) {
        companion object {
            /** Clamped non-negative, mirroring the iOS init. */
            fun of(artist: Double, genreYear: Double, genreMusical: Double) =
                Balance(max(0.0, artist), max(0.0, genreYear), max(0.0, genreMusical))

            val EVEN = Balance(0.25, 0.375, 0.375)
            val NOMINAL_THIRDS = Balance(1.0 / 3, 1.0 / 3, 1.0 / 3)
            val ARTIST_DOMINANT = Balance(0.55, 0.45, 0.0)
        }
    }

    data class TermWeights(
        val artist: Double = 0.0,
        val genre: Double = 0.0,
        val year: Double = 0.0,
        val musical: Double = 0.0,
    ) {
        val total: Double get() = artist + genre + year + musical
    }

    /** The shipped seven-term scorer's family budget: wArtist + wGenre + wYear. */
    val familyTotal: Double =
        PuzzleSimilarity.W_ARTIST + PuzzleSimilarity.W_GENRE + PuzzleSimilarity.W_YEAR

    /**
     * Flatten the family balance into term weights, renormalised over the fields this profile
     * can actually speak (a family loses a dead field, the remaining one carries its share).
     */
    fun termWeights(
        balance: Balance = Balance.EVEN,
        hasGenre: Boolean,
        hasYear: Boolean,
        hasMusical: Boolean,
        scaledTo: Double = familyTotal,
    ): TermWeights {
        var genre = 0.0
        var year = 0.0
        var musical = 0.0
        val bLive = (if (hasGenre) 1.0 else 0.0) + (if (hasYear) 1.0 else 0.0)
        if (bLive > 0) {
            val each = balance.genreYear / bLive
            if (hasGenre) genre += each
            if (hasYear) year += each
        }
        val cLive = (if (hasGenre) 1.0 else 0.0) + (if (hasMusical) 1.0 else 0.0)
        if (cLive > 0) {
            val each = balance.genreMusical / cLive
            if (hasGenre) genre += each
            if (hasMusical) musical += each
        }
        val artist = balance.artist
        val sum = artist + genre + year + musical
        if (!(sum > 0) || !(scaledTo > 0)) return TermWeights()
        val k = scaledTo / sum
        return TermWeights(artist * k, genre * k, year * k, musical * k)
    }

    // ── Genre ──────────────────────────────────────────────────────────────────────────────

    /** Tier-1 genre category, or null for blank/absent input (the term then drops). */
    fun canonicalGenre(raw: String?): String? {
        if (raw == null || raw.isBlank()) return null
        return Genre.category(raw)
    }

    // ── Era ────────────────────────────────────────────────────────────────────────────────

    data class EraWindow(val lo: Double, val hi: Double) {
        fun contains(year: Double): Boolean = year >= lo && year <= hi
    }

    const val ERA_PERCENTILE_LOW = 0.15
    const val ERA_PERCENTILE_HIGH = 0.85
    const val ERA_PADDING_YEARS = 2.0
    const val ERA_DECAY_YEARS = 4.0
    const val FALLBACK_NEUTRAL_ERA_FIT = 0.76

    /** p15–p85 of the (positive, finite) target years, padded ±2 y. Null when there are none. */
    fun eraWindow(years: List<Double>): EraWindow? {
        val ys = years.filter { it.isFinite() && it > 0 }.sorted()
        if (ys.isEmpty()) return null
        fun rank(p: Double): Double {
            val idx = min(ys.size - 1, max(0, ceil(p * ys.size).toInt() - 1))
            return ys[idx]
        }
        return EraWindow(rank(ERA_PERCENTILE_LOW) - ERA_PADDING_YEARS, rank(ERA_PERCENTILE_HIGH) + ERA_PADDING_YEARS)
    }

    /** Flat 1 inside the window, exp(-gap/4) outside. */
    fun eraFit(year: Double, window: EraWindow): Double {
        if (window.contains(year)) return 1.0
        val gap = if (year < window.lo) window.lo - year else year - window.hi
        return exp(-gap / ERA_DECAY_YEARS)
    }

    data class EraCalibration(
        val neutral: Double = FALLBACK_NEUTRAL_ERA_FIT,
        val observations: Int = 0,
    ) {
        val usedRoundMean: Boolean get() = observations >= MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL
    }

    /** The round's own mean era fit over DATED candidates — what an undated one scores. */
    fun eraCalibrate(candidateYears: Iterable<Double?>, window: EraWindow): EraCalibration {
        var sum = 0.0
        var n = 0
        for (y in candidateYears) {
            if (y == null || !y.isFinite() || y <= 0) continue
            sum += eraFit(y, window)
            n++
        }
        return EraCalibration(
            neutral = if (n >= MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL) sum / n else FALLBACK_NEUTRAL_ERA_FIT,
            observations = n,
        )
    }

    /** Undated candidates score the round neutral — never 0. */
    fun eraFit(year: Double?, window: EraWindow, calibration: EraCalibration): Double {
        if (year == null || !year.isFinite() || year <= 0) return calibration.neutral
        return eraFit(year, window)
    }

    // ── Musical profile (bpm + camelot densities) ──────────────────────────────────────────

    data class TempoMode(val bpm: Double, val weight: Double)

    data class MusicalProfile(
        val tempoModes: List<TempoMode> = emptyList(),
        val camelotWeight: Map<String, Double> = emptyMap(),
        val tempoPeak: Double = 0.0,
        val camelotPeak: Double = 0.0,
    ) {
        val isEmpty: Boolean get() = tempoModes.isEmpty() && camelotWeight.isEmpty()
    }

    data class MusicalMember(val bpm: Double?, val camelot: String?, val weight: Double)

    const val MAX_TEMPO_MODES = 6
    const val TEMPO_SIGMA_OCTAVES = 0.10
    const val TRIPLET_STRENGTH = 0.6

    private fun log2(x: Double) = ln(x) / ln(2.0)

    fun musicalProfile(members: List<MusicalMember>): MusicalProfile {
        val buckets = HashMap<Double, Double>()
        val camelot = HashMap<String, Double>()
        for (m in members) {
            val w = max(0.0, m.weight)
            if (!(w > 0)) continue
            val b = m.bpm
            if (b != null && b > 0) {
                // Swift `.rounded()` is half-away-from-zero; bpm is positive here.
                buckets.merge(floor(b + 0.5), w, Double::plus)
            }
            val c = m.camelot?.trim()?.uppercase(Locale.ROOT)
            if (!c.isNullOrEmpty()) camelot.merge(c, w, Double::plus)
        }
        val modes = buckets.entries
            .sortedWith { a, b -> if (a.value != b.value) b.value.compareTo(a.value) else a.key.compareTo(b.key) }
            .take(MAX_TEMPO_MODES)
            .map { TempoMode(it.key, it.value) }
        val partial = MusicalProfile(tempoModes = modes, camelotWeight = camelot)
        val tempoPeak = modes.maxOfOrNull { tempoDensity(it.bpm, partial) } ?: 0.0
        val camelotPeak = ALL_CAMELOT_CODES.maxOfOrNull { camelotDensity(it, partial) } ?: 0.0
        return partial.copy(tempoPeak = tempoPeak, camelotPeak = camelotPeak)
    }

    val ALL_CAMELOT_CODES: List<String> = (1..12).flatMap { listOf("${it}A", "${it}B") }

    private data class Camelot(val n: Int, val letter: Char)

    private fun parseCamelot(raw: String): Camelot? {
        val s = raw.trim().uppercase(Locale.ROOT)
        val letter = s.lastOrNull() ?: return null
        if (letter != 'A' && letter != 'B') return null
        val n = s.dropLast(1).toIntOrNull() ?: return null
        if (n !in 1..12) return null
        return Camelot(n, letter)
    }

    /** 1.0 identical · 0.75 relative major/minor · 0.6 ±1 on the wheel (same letter) · else 0. */
    fun camelotRelatedness(a: String, b: String): Double {
        val x = parseCamelot(a) ?: return 0.0
        val y = parseCamelot(b) ?: return 0.0
        if (x.n == y.n && x.letter == y.letter) return 1.0
        if (x.n == y.n) return 0.75
        if (x.letter != y.letter) return 0.0
        val up = x.n % 12 + 1
        val down = (x.n + 10) % 12 + 1
        return if (y.n == up || y.n == down) 0.6 else 0.0
    }

    fun camelotDensity(code: String, p: MusicalProfile): Double {
        var sum = 0.0
        for ((c, w) in p.camelotWeight) sum += w * camelotRelatedness(code, c)
        return sum
    }

    fun camelotAffinity(code: String?, p: MusicalProfile): Double {
        if (code.isNullOrEmpty() || p.camelotWeight.isEmpty() || !(p.camelotPeak > 0) || parseCamelot(code) == null) return 0.0
        return min(1.0, camelotDensity(code, p) / p.camelotPeak)
    }

    fun tempoDensity(bpm: Double, p: MusicalProfile): Double {
        if (!(bpm > 0)) return 0.0
        var sum = 0.0
        for (m in p.tempoModes) {
            if (!(m.bpm > 0)) continue
            sum += m.weight * exp(-abs(log2(bpm / m.bpm)) / TEMPO_SIGMA_OCTAVES)
        }
        return sum
    }

    /** Half-time / double-time count fully; triplet (2:3, 3:2) relations at 0.6. */
    fun bpmAffinity(bpm: Double?, p: MusicalProfile): Double {
        if (bpm == null || !(bpm > 0) || p.tempoModes.isEmpty() || !(p.tempoPeak > 0)) return 0.0
        val related = listOf(
            bpm to 1.0, bpm / 2 to 1.0, bpm * 2 to 1.0,
            bpm * 2 / 3 to TRIPLET_STRENGTH, bpm * 3 / 2 to TRIPLET_STRENGTH,
        )
        var best = 0.0
        for ((b, strength) in related) best = max(best, strength * tempoDensity(b, p) / p.tempoPeak)
        return min(1.0, best)
    }

    // ── Musical calibration ────────────────────────────────────────────────────────────────

    const val FALLBACK_NEUTRAL_MUSICAL_FIT = 0.34
    const val MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL = 25
    const val MUSICAL_PRIOR = 2.0

    data class MusicalCalibration(
        val neutral: Double = FALLBACK_NEUTRAL_MUSICAL_FIT,
        val observations: Int = 0,
    ) {
        val usedRoundMean: Boolean get() = observations >= MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL
    }

    data class RawMusical(val fit: Double, val observations: Int)

    /** Mean of the available bpm/camelot affinities, or null when the candidate has neither. */
    fun rawMusicalFit(bpm: Double?, camelot: String?, p: MusicalProfile): RawMusical? {
        val terms = ArrayList<Double>(2)
        if (p.tempoModes.isNotEmpty() && bpm != null && bpm > 0) terms.add(bpmAffinity(bpm, p))
        if (p.camelotWeight.isNotEmpty() && !camelot.isNullOrEmpty()) terms.add(camelotAffinity(camelot, p))
        if (terms.isEmpty()) return null
        return RawMusical(terms.sum() / terms.size, terms.size)
    }

    data class BpmCamelot(val bpm: Double?, val camelot: String?)

    fun calibrate(candidates: Iterable<BpmCamelot>, p: MusicalProfile): MusicalCalibration {
        if (p.isEmpty) return MusicalCalibration()
        var sum = 0.0
        var n = 0
        for (c in candidates) {
            val r = rawMusicalFit(c.bpm, c.camelot, p) ?: continue
            sum += r.fit
            n++
        }
        return MusicalCalibration(
            neutral = if (n >= MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL) sum / n else FALLBACK_NEUTRAL_MUSICAL_FIT,
            observations = n,
        )
    }

    /** Shrunk toward the round neutral by the prior, so one lucky axis can't saturate. */
    fun musicalFit(bpm: Double?, camelot: String?, p: MusicalProfile, calibration: MusicalCalibration): Double {
        val r = rawMusicalFit(bpm, camelot, p) ?: return calibration.neutral
        val n = r.observations.toDouble()
        return (MUSICAL_PRIOR * calibration.neutral + n * r.fit) / (MUSICAL_PRIOR + n)
    }

    // ── Timbre ─────────────────────────────────────────────────────────────────────────────

    /** Axis list + ORDER are part of the packed-vector contract. */
    val TIMBRE_AXES: List<String> = listOf(
        "bright", "brightVar", "air", "width", "noisy", "fizz",
        "punch", "busy", "dynamic", "loud", "m1", "m2", "m3", "m4",
    )
    const val TIMBRE_MIN_SHARED_AXES = 8

    /** Calibration version of the corpus; a document at any other version is refused. */
    const val TIMBRE_VERSION = 1
    const val TIMBRE_MIN_VECTORS = 3
    const val TIMBRE_MAX_ZERO_AXES = 7

    /** ≥ 8 finite axes AND fewer than 7 exact zeros (degenerate rows are all the same point). */
    fun isUsableTimbreRow(f: Map<String, Double>): Boolean {
        var usable = 0
        var zeros = 0
        for (axis in TIMBRE_AXES) {
            val v = f[axis] ?: continue
            if (!v.isFinite()) return false
            usable++
            if (v == 0.0) zeros++
        }
        return usable >= TIMBRE_MIN_SHARED_AXES && zeros < TIMBRE_MAX_ZERO_AXES
    }

    /** e-fold of the fit outside the spread, in rail units. */
    const val TIMBRE_DECAY = 0.12
    const val FALLBACK_NEUTRAL_TIMBRE_FIT = 0.57
    const val TIMBRE_PRIOR = 2.0

    const val TIMBRE_NOISE_FLOOR = 0.12
    const val SOUND_ADMIT_MARGIN = 0.06
    const val SOUND_ADMIT_MIN_PROFILE_VECTORS = 8
    const val SOUND_ADMIT_MIN_ANALYSED_SHARE = 0.5
    const val SOUND_ADMIT_MAX_SPREAD = 0.20

    fun soundAdmitRadius(spread: Double): Double = max(spread, TIMBRE_NOISE_FLOOR) - SOUND_ADMIT_MARGIN

    fun timbreProfileAdmits(p: TimbreProfile?, profileSize: Int): Boolean {
        if (p == null || profileSize <= 0) return false
        if (p.vectors < SOUND_ADMIT_MIN_PROFILE_VECTORS) return false
        if (p.vectors.toDouble() / profileSize < SOUND_ADMIT_MIN_ANALYSED_SHARE) return false
        return p.spread <= SOUND_ADMIT_MAX_SPREAD
    }

    class PackedVector(val v: DoubleArray, val count: Int) {
        override fun equals(other: Any?) = other is PackedVector && count == other.count && v.contentEquals(other.v)
        override fun hashCode() = 31 * count + v.contentHashCode()
    }

    fun pack(v: Map<String, Double>): PackedVector {
        val out = DoubleArray(TIMBRE_AXES.size) { Double.NaN }
        var n = 0
        for ((i, k) in TIMBRE_AXES.withIndex()) {
            val x = v[k] ?: continue
            if (!x.isFinite()) continue
            out[i] = x
            n++
        }
        return PackedVector(out, n)
    }

    fun pack(m: Map<String, Map<String, Double>>): Map<String, PackedVector> = m.mapValues { pack(it.value) }

    /** RMS over the SHARED finite axes (not euclidean); null below [TIMBRE_MIN_SHARED_AXES]. */
    fun timbreDistance(a: PackedVector, b: PackedVector): Double? {
        if (a.count < TIMBRE_MIN_SHARED_AXES || b.count < TIMBRE_MIN_SHARED_AXES) return null
        var sum = 0.0
        var n = 0
        for (i in TIMBRE_AXES.indices) {
            val x = a.v[i]
            val y = b.v[i]
            if (!x.isFinite() || !y.isFinite()) continue
            sum += (x - y) * (x - y)
            n++
        }
        if (n < TIMBRE_MIN_SHARED_AXES) return null
        return sqrt(sum / n)
    }

    fun timbreDistance(a: Map<String, Double>, b: Map<String, Double>): Double? {
        var sum = 0.0
        var n = 0
        for (k in TIMBRE_AXES) {
            val x = a[k] ?: continue
            val y = b[k] ?: continue
            if (!x.isFinite() || !y.isFinite()) continue
            sum += (x - y) * (x - y)
            n++
        }
        if (n < TIMBRE_MIN_SHARED_AXES) return null
        return sqrt(sum / n)
    }

    data class TimbreProfile(val centroid: Map<String, Double>, val spread: Double, val vectors: Int)

    data class TimbreMember(val vector: Map<String, Double>, val weight: Double)

    /** Weighted centroid + mean weighted distance to it (spread). Null below [minVectors]. */
    fun timbreProfile(members: List<TimbreMember>, minVectors: Int = TIMBRE_MIN_VECTORS): TimbreProfile? {
        val usable = members.filter { it.weight > 0 && isUsableTimbreRow(it.vector) }
        if (usable.size < max(1, minVectors)) return null
        val centroid = LinkedHashMap<String, Double>()
        for (axis in TIMBRE_AXES) {
            var s = 0.0
            var w = 0.0
            for (m in usable) {
                val v = m.vector[axis] ?: continue
                if (!v.isFinite()) continue
                s += v * m.weight
                w += m.weight
            }
            if (w > 0) centroid[axis] = s / w
        }
        var dSum = 0.0
        var dW = 0.0
        for (m in usable) {
            val d = timbreDistance(m.vector, centroid) ?: continue
            dSum += d * m.weight
            dW += m.weight
        }
        if (!(dW > 0)) return null
        return TimbreProfile(centroid, dSum / dW, usable.size)
    }

    /** Saturates at 1 inside the spread, exp(-(d-spread)/0.12) outside; null if incomparable. */
    fun timbreFit(v: Map<String, Double>, p: TimbreProfile): Double? {
        val d = timbreDistance(v, p.centroid) ?: return null
        if (d <= p.spread) return 1.0
        return exp(-(d - p.spread) / TIMBRE_DECAY)
    }

    fun timbreNetFit(
        v: Map<String, Double>,
        positive: TimbreProfile,
        negative: TimbreProfile?,
        rejectionWeight: Double,
    ): Double? {
        val pos = timbreFit(v, positive) ?: return null
        if (negative == null) return pos
        val neg = timbreFit(v, negative) ?: return pos
        return max(0.0, pos - rejectionWeight * neg)
    }

    data class TimbreCalibration(
        val neutral: Double = FALLBACK_NEUTRAL_TIMBRE_FIT,
        val observations: Int = 0,
    ) {
        val usedRoundMean: Boolean get() = observations >= MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL
    }

    fun timbreCalibrate(
        candidates: Iterable<Map<String, Double>?>,
        positive: TimbreProfile,
        negative: TimbreProfile?,
        rejectionWeight: Double,
    ): TimbreCalibration {
        var sum = 0.0
        var n = 0
        for (v in candidates) {
            if (v == null) continue
            val fit = timbreNetFit(v, positive, negative, rejectionWeight) ?: continue
            sum += fit
            n++
        }
        return TimbreCalibration(
            neutral = if (n >= MIN_OBSERVATIONS_FOR_ROUND_NEUTRAL) sum / n else FALLBACK_NEUTRAL_TIMBRE_FIT,
            observations = n,
        )
    }

    /** Un-analysed candidate scores the round neutral; analysed ones shrink toward it. */
    fun timbreFit(
        v: Map<String, Double>?,
        positive: TimbreProfile,
        negative: TimbreProfile?,
        rejectionWeight: Double,
        calibration: TimbreCalibration,
    ): Double {
        val fit = v?.let { timbreNetFit(it, positive, negative, rejectionWeight) } ?: return calibration.neutral
        return (TIMBRE_PRIOR * calibration.neutral + fit) / (TIMBRE_PRIOR + 1)
    }

    /** Up to [maxCount] words for axes deviating >= 0.15 from the 0.5 midpoint, strongest first. */
    fun timbreAdjectives(centroid: Map<String, Double>, maxCount: Int = 3): List<String> {
        val table = listOf(
            Triple("punch", "punchy", "smooth"),
            Triple("bright", "bright", "dark"),
            Triple("busy", "busy", "sparse"),
            Triple("dynamic", "dynamic", "even"),
            Triple("loud", "loud", "quiet"),
            Triple("noisy", "gritty", "clean"),
            Triple("air", "airy", "warm"),
        )
        val picks = ArrayList<Pair<String, Double>>()
        for ((axis, hi, lo) in table) {
            val v = centroid[axis] ?: continue
            if (!v.isFinite()) continue
            val dev = v - 0.5
            if (abs(dev) < 0.15) continue
            picks.add((if (dev > 0) hi else lo) to abs(dev))
        }
        return picks
            .sortedWith { a, b -> if (a.second != b.second) b.second.compareTo(a.second) else a.first.compareTo(b.first) }
            .take(max(0, maxCount))
            .map { it.first }
    }

    // ── Family scores ──────────────────────────────────────────────────────────────────────

    data class Scores(val artist: Double?, val genreYear: Double?, val genreMusical: Double?) {
        /** Which family speaks loudest, as a UI word; null when nothing scored. */
        val leading: String?
            get() {
                val pairs = listOf("artist" to (artist ?: -1.0), "era" to (genreYear ?: -1.0), "groove" to (genreMusical ?: -1.0))
                // Swift max(by: <) keeps the FIRST max on ties; replace only when strictly greater.
                var best = pairs[0]
                for (p in pairs.drop(1)) if (p.second > best.second) best = p
                return if (best.second >= 0) best.first else null
            }
    }

    fun scores(artistFit: Double?, genreFit: Double?, yearFit: Double?, musicalFit: Double?): Scores {
        fun mean(a: Double?, b: Double?): Double? = when {
            a != null && b != null -> (a + b) / 2
            a != null -> a
            b != null -> b
            else -> null
        }
        return Scores(artistFit, mean(genreFit, yearFit), mean(genreFit, musicalFit))
    }
}

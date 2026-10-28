package com.levi.pocketdj.mix.model

import kotlin.math.abs

/** A parsed Camelot code: wheel hour 1..12 and mode (B = major, A = minor). */
data class CamelotKey(val num: Int, val major: Boolean)

/** Port of iOS `Camelot` (Support/Format.swift) pure parts + the Mix's signed wheel distance. */
object Camelot {
    /** All 24 codes in wheel order: 1A, 1B, 2A ... 12B. */
    val keys: List<String> = (1..12).flatMap { listOf("${it}A", "${it}B") }

    /** Parse "<num><A|B>" (trimmed, case-insensitive); null if unparseable. */
    fun parse(code: String?): CamelotKey? {
        if (code == null) return null
        val t = code.trim { it == ' ' || it == '\t' }.uppercase()
        val last = t.lastOrNull() ?: return null
        if (last != 'A' && last != 'B') return null
        val n = t.dropLast(1).toIntOrNull() ?: return null
        if (n !in 1..12) return null
        return CamelotKey(n, last == 'B')
    }

    /** Comparable rank (A = even, B = odd, contiguous) so numeric compare yields wheel order. */
    fun rank(code: String?): Int? = parse(code)?.let { it.num * 2 + if (it.major) 1 else 0 }

    /**
     * Signed Camelot-hour distance a to b wrapped the shortest way round the 12-hour wheel
     * (-6..+6). null if either is unparseable. Positive: b is "higher".
     */
    fun signedSteps(a: String?, b: String?): Int? {
        val pa = parse(a) ?: return null
        val pb = parse(b) ?: return null
        var d = pb.num - pa.num
        if (d > 6) d -= 12 else if (d < -6) d += 12
        return d
    }

    /** Wheel hue 0..<1 for the code (hour-1)/12; null if unparseable. */
    fun hue(code: String?): Double? = parse(code)?.let { (it.num - 1) / 12.0 }

    /** HSL lightness: B (major) brighter, A (minor) deeper. */
    fun lightness(code: String?): Double? = parse(code)?.let { if (it.major) 0.50 else 0.38 }

    /** Circular hour distance 0..6, ignoring mode. */
    fun hourDistance(a: String?, b: String?): Int? = signedSteps(a, b)?.let { abs(it) }
}

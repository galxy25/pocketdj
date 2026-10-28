package com.levi.pocketdj.data.collections

import java.text.Normalizer

/**
 * Typo-tolerant name matching for "filter this list by what I typed" fields (the Add-to sheet's
 * pocket/playlist search). Port of the iOS `FuzzyMatch`: three widening passes, the first hit
 * wins, scored higher the more literal it was:
 *  1. Literal — equal / prefix / substring of the compacted name.
 *  2. Subsequence — every query char in order, bonuses for contiguity and word starts ("fnm").
 *  3. Approximate substring — OSA distance (Levenshtein + adjacent transposition) with a free
 *     start/end in the candidate; the error budget scales with query length.
 *
 * Scores are only meaningful RELATIVE to each other; `null` means "no match".
 */
object FuzzyMatch {

    /** Diacritic-folded + whitespace-collapsed, CASE PRESERVED (word starts read off this). */
    fun normalize(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD)
            .filter { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }
            .split(Regex("\\s+"))
            .filter { it.isNotEmpty() }
            .joinToString(" ")

    /** Normalized, lowercased, stripped of every non-alphanumeric. */
    fun compact(s: String): List<Char> = prepare(s).first

    private fun prepare(s: String): Pair<List<Char>, Set<Int>> {
        val chars = ArrayList<Char>()
        val starts = HashSet<Int>()
        var atStart = true
        var previous: Char? = null
        for (ch in normalize(s)) {
            if (!(ch.isLetter() || ch.isDigit())) {
                atStart = true
                continue
            }
            val idx = chars.size
            val p = previous
            if (atStart) {
                starts += idx
            } else if (p != null && p.isDigit() != ch.isDigit()) {
                starts += idx
            } else if (p != null && p.isLowerCase() && ch.isUpperCase()) {
                starts += idx
            }
            atStart = false
            previous = ch
            chars += ch.lowercaseChar()
        }
        return chars to starts
    }

    /** `null` ⇒ no match. Higher = better. An EMPTY query matches everything at score 0. */
    fun score(query: String, candidate: String): Double? {
        val q = compact(query)
        if (q.isEmpty()) return 0.0
        val (c, starts) = prepare(candidate)
        if (c.isEmpty()) return null
        return literalScore(q, c) ?: subsequenceScore(q, c, starts) ?: approximateScore(q, c)
    }

    fun matches(query: String, candidate: String): Boolean = score(query, candidate) != null

    /** Filter + rank by [name]. Blank query ⇒ input untouched; ties keep the caller's order. */
    fun <T> rank(items: List<T>, query: String, name: (T) -> String): List<T> {
        if (query.isBlank()) return items
        return items.withIndex()
            .mapNotNull { (idx, item) -> score(query, name(item))?.let { Triple(idx, it, item) } }
            .sortedWith(compareBy<Triple<Int, Double, T>>({ -it.second }, { it.first }))
            .map { it.third }
    }

    private fun literalScore(q: List<Char>, c: List<Char>): Double? {
        if (q == c) return 1000.0
        if (c.size > q.size && c.subList(0, q.size) == q) return 900.0 - lengthPenalty(q.size, c.size)
        val at = firstIndex(q, c)
        if (at != null) return 800.0 - minOf(at, 40) - lengthPenalty(q.size, c.size)
        return null
    }

    private fun subsequenceScore(q: List<Char>, c: List<Char>, wordStarts: Set<Int>): Double? {
        var qi = 0
        var bonus = 0.0
        var lastHit = -2
        var gaps = 0.0
        for ((ci, ch) in c.withIndex()) {
            if (qi >= q.size) break
            if (ch != q[qi]) continue
            if (ci == lastHit + 1) bonus += 6
            if (ci in wordStarts) bonus += 8
            if (lastHit >= 0) gaps += (ci - lastHit - 1)
            lastHit = ci
            qi++
        }
        if (qi != q.size) return null
        return 500.0 + bonus - minOf(gaps, 60.0) - lengthPenalty(q.size, c.size)
    }

    private fun approximateScore(q: List<Char>, c: List<Char>): Double? {
        val budget = errorBudget(q.size)
        if (budget <= 0) return null
        val d = approximateDistance(q, c)
        if (d > budget) return null
        return 300.0 - d * 40.0 - lengthPenalty(q.size, c.size)
    }

    /** None below 4 chars; 1 up to 7; then one more per 4. */
    fun errorBudget(n: Int): Int = if (n < 4) 0 else maxOf(1, n / 4)

    /** Minimum OSA distance between [q] and ANY contiguous window of [c]. */
    fun approximateDistance(q: List<Char>, c: List<Char>): Int {
        if (q.isEmpty()) return 0
        if (c.isEmpty()) return q.size
        val n = c.size
        var prev2 = IntArray(n + 1)
        var prev = IntArray(n + 1)
        var cur = IntArray(n + 1)
        for (i in 1..q.size) {
            cur[0] = i
            for (j in 1..n) {
                val cost = if (q[i - 1] == c[j - 1]) 0 else 1
                var best = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if (i > 1 && j > 1 && q[i - 1] == c[j - 2] && q[i - 2] == c[j - 1]) {
                    best = minOf(best, prev2[j - 2] + 1)
                }
                cur[j] = best
            }
            val t = prev2
            prev2 = prev
            prev = cur
            cur = t
        }
        return prev.min()
    }

    private fun firstIndex(needle: List<Char>, hay: List<Char>): Int? {
        if (needle.size > hay.size) return null
        for (start in 0..(hay.size - needle.size)) {
            if (hay.subList(start, start + needle.size) == needle) return start
        }
        return null
    }

    private fun lengthPenalty(q: Int, c: Int): Double = minOf(maxOf(c - q, 0) * 0.5, 60.0)
}

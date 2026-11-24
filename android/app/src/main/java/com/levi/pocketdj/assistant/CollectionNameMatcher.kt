package com.levi.pocketdj.assistant

import com.levi.pocketdj.data.collections.FuzzyMatch

/**
 * Strict spoken-collection-name matching (port of iOS `CollectionEntity.rankByName`, commit
 * 922ea73c). Only literal hits count (the name equals / starts with / contains the request); a
 * whole-name typo runs only when nothing is literal. Initials / subsequence matching is NEVER
 * used: a spoken "Rap" must not land silently in "Rainy Afternoon Pop", nor may a typo buried in
 * a longer name. An exact name wins outright and is never ambiguous.
 */
object CollectionNameMatcher {

    private val quotes = "\"“”'‘’"

    /** Leading "my"/"the" and a trailing "playlist"/"pocket"/"collection" are ignored. */
    fun spokenName(raw: String): String {
        var q = raw.trim().trim { it in quotes }
        for (prefix in listOf("my ", "the ")) {
            if (q.lowercase().startsWith(prefix)) q = q.substring(prefix.length)
        }
        for (suffix in listOf(" playlist", " pocket", " collection")) {
            if (q.lowercase().endsWith(suffix)) q = q.substring(0, q.length - suffix.length)
        }
        return q.trim()
    }

    /** The best tier of [items] for a spoken name, best first (ties keep input order). */
    fun <T> rank(raw: String, items: List<T>, name: (T) -> String): List<T> =
        rankScored(raw, items, name).map { it.first }

    /** Like [rank] but with each item's score, so callers can break exact-score ties themselves. */
    fun <T> rankScored(raw: String, items: List<T>, name: (T) -> String): List<Pair<T, Double>> {
        val q = spokenName(raw)
        val qc = FuzzyMatch.compact(q)
        if (qc.isEmpty()) return emptyList()
        val candidates = items.map { it to FuzzyMatch.compact(name(it)) }

        fun contains(c: List<Char>): Boolean {
            if (c.size < qc.size) return false
            for (start in 0..(c.size - qc.size)) {
                if (c.subList(start, start + qc.size) == qc) return true
            }
            return false
        }

        var scored: List<Pair<T, Double>> = candidates.mapNotNull { (item, chars) ->
            if (!contains(chars)) null else FuzzyMatch.score(q, name(item))?.let { item to it }
        }
        if (scored.isEmpty()) {
            val budget = FuzzyMatch.errorBudget(qc.size)
            scored = candidates.mapNotNull { (item, chars) ->
                if (budget <= 0 || kotlin.math.abs(chars.size - qc.size) > budget) return@mapNotNull null
                val d = FuzzyMatch.approximateDistance(qc, chars)
                if (d <= budget) item to (300.0 - d * 40.0) else null
            }
        }
        val sorted = scored.sortedByDescending { it.second } // stable: ties keep input order
        val best = sorted.firstOrNull()?.second ?: return emptyList()
        val band = if (best >= 1000.0) 0.0 else 60.0
        return sorted.filter { best - it.second <= band }
    }
}

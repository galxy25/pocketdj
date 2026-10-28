package com.levi.pocketdj.data.games.inthepocket

/**
 * The cloud's round-learning formula, on device — so a round's lesson applies to the very next
 * round, before the cloud recomputes (and without the cloud at all). MUST match
 * `learnFromRounds` / `roundMultiplier` in scripts/lambda/listening-pockets/analyze.mjs.
 */
object InThePocketLearning {
    const val EARLY_SKIP_MAX_SONG = 2
    const val SMOOTHING = 1.0
    const val MIN_MULTIPLIER = 0.25
    const val MAX_MULTIPLIER = 2.0

    /** +1 pocket, −1 broke at song ≤ 2, 0 otherwise. */
    fun label(r: InThePocketRound): Int = when (val o = r.outcome) {
        InThePocketOutcome.Pocket -> 1
        is InThePocketOutcome.Broke -> if (o.at <= EARLY_SKIP_MAX_SONG) -1 else 0
        else -> 0
    }

    fun multiplier(pos: Int, neg: Int): Double {
        val m = 2 * (pos + SMOOTHING) / ((pos + neg) + 2 * SMOOTHING)
        return round3(minOf(MAX_MULTIPLIER, maxOf(MIN_MULTIPLIER, m)))
    }

    data class Weight(val pos: Int, val neg: Int, val multiplier: Double)

    /** `"dim\u0000value"` — the key used everywhere a target is addressed. */
    fun targetKey(dim: String, value: String) = "$dim\u0000$value"

    /** context key → "dim\0value" → weight. */
    fun contexts(rounds: List<InThePocketRound>): Map<String, Map<String, Weight>> {
        val counts = LinkedHashMap<String, LinkedHashMap<String, IntArray>>()
        for (r in rounds) {
            val l = label(r)
            if (l == 0) continue
            for (k in r.context.learningKeys) {
                val m = counts.getOrPut(k) { LinkedHashMap() }
                for (key in r.targets.map { targetKey(it.dim, it.value) }.toSet()) {
                    val c = m.getOrPut(key) { IntArray(2) }
                    if (l > 0) c[0] += 1 else c[1] += 1
                }
            }
        }
        return counts.mapValues { (_, m) ->
            m.mapValues { (_, c) -> Weight(c[0], c[1], multiplier(c[0], c[1])) }
        }
    }
}

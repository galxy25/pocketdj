package com.levi.pocketdj.data.pockets

/** Minute-budget fitting for a built pocket (iOS `PocketFitter`). Pure. */
object PocketFitter {
    /** Mirrors the realizer's unknown-length fallback (3:30). */
    const val FALLBACK_LENGTH_MS = 210_000L

    /** The default pocket length: "a ~90-minute pocket". */
    const val DEFAULT_MINUTES = 90

    /**
     * Greedy fit of ordered picks into the budget: keep order, skip anything that would overflow (a later
     * shorter song may still fit), and always keep the first pick so a valid plan never fits to zero.
     */
    fun fit(ids: List<String>, lengthMs: (String) -> Long?, budgetMs: Long): List<String> {
        val kept = ArrayList<String>()
        var total = 0L
        for (id in ids) {
            val len = lengthMs(id)?.takeIf { it > 0 } ?: FALLBACK_LENGTH_MS
            if (total + len <= budgetMs || kept.isEmpty()) {
                kept += id
                total += len
            }
        }
        return kept
    }

    fun budgetMs(minutes: Int): Long = maxOf(1, minutes).toLong() * 60_000L
}

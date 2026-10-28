package com.levi.pocketdj.auto

/** Car art rules: only https (cleartext is blocked in the head unit's art loader); first usable candidate wins. */
object AutoArtwork {
    /** Upgrades http:// to https:// and drops anything that is not a web url (file:, data:, blank, relative). */
    fun httpsOrNull(url: String?): String? {
        val u = url?.trim().orEmpty()
        return when {
            u.startsWith("https://", ignoreCase = true) -> u
            u.startsWith("http://", ignoreCase = true) -> "https://" + u.substring(7)
            else -> null
        }
    }

    /** First candidate (in the catalog's cdn-first order) that survives [httpsOrNull]. */
    fun pick(candidates: List<String>): String? = candidates.firstNotNullOfOrNull(::httpsOrNull)
}

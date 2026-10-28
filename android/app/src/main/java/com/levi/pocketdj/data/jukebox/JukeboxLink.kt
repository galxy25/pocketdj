package com.levi.pocketdj.data.jukebox

import java.net.URI

/**
 * A parsed jukebox deep link (iOS `JukeboxLink`). Three accepted forms:
 *  - `pocketdj://jukebox/<id>`
 *  - `pocketdj:///jukebox/<id>`
 *  - `https://jukebox.pocket-dj.com/<id>/` (optionally followed by `state.json` / more path)
 * The id must match the server shape `[a-z2-7]{4,32}` (lower case only) so an unrelated URL
 * is never misread as a jukebox link. A link only ever JOINS as a guest; it never confers a hostKey.
 *
 * Pure JVM (java.net.URI + string ops) so it is unit-testable.
 */
data class JukeboxLink(
    val jukeboxId: String,
    /** The https guest origin when the link was a universal link; null for the custom scheme. */
    val guestBase: String?,
) {
    /** `<guestBase>/<id>/state.json`; the canonical host when the link carried no origin. */
    val stateUrl: String
        get() = "${(guestBase ?: DEFAULT_GUEST_BASE).trimEnd('/')}/$jukeboxId/state.json"

    companion object {
        const val SCHEME = "pocketdj"
        const val UNIVERSAL_HOST = "jukebox.pocket-dj.com"
        const val DEFAULT_GUEST_BASE = "https://$UNIVERSAL_HOST"
        private const val ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"

        /** Server id shape: base32 `[a-z2-7]`, 4-32 chars. */
        fun isValidId(s: String): Boolean = s.length in 4..32 && s.all { it in ID_ALPHABET }

        /** Parse a deep-link URL; null when it is not a jukebox link. */
        fun parse(url: String): JukeboxLink? {
            val trimmed = url.trim()
            val colon = trimmed.indexOf(':')
            if (colon <= 0) return null
            val scheme = trimmed.substring(0, colon).lowercase()
            return when (scheme) {
                SCHEME -> parseCustom(trimmed.substring(colon + 1))
                "https", "http" -> parseUniversal(trimmed)
                else -> null
            }
        }

        /**
         * The debug / manual "Join by link or id" entry: a bare id (`exmkrd5a`) or any [parse]-able link.
         */
        fun parseLoose(input: String): JukeboxLink? {
            val t = input.trim()
            if (isValidId(t)) return JukeboxLink(t, null)
            return parse(t)
        }

        /** Rebuild the link for a persisted entry (its origin when known, else the canonical host). */
        fun forEntry(id: String, guestBase: String?): JukeboxLink? {
            if (!isValidId(id)) return null
            val base = guestBase?.takeIf { it.isNotBlank() }
            return JukeboxLink(id, base?.trimEnd('/'))
        }

        private fun segmentsOf(path: String): List<String> =
            path.substringBefore('#').substringBefore('?').split('/').filter { it.isNotEmpty() }

        private fun parseCustom(rest: String): JukeboxLink? {
            // `//jukebox/<id>` and `///jukebox/<id>` both reduce to ["jukebox", "<id>"].
            val segs = segmentsOf(rest)
            if (segs.size < 2 || !segs[0].equals("jukebox", ignoreCase = true)) return null
            val id = segs[1]
            return if (isValidId(id)) JukeboxLink(id, null) else null
        }

        private fun parseUniversal(url: String): JukeboxLink? {
            val uri = runCatching { URI(url) }.getOrNull() ?: return null
            if (uri.host?.lowercase() != UNIVERSAL_HOST) return null
            val id = segmentsOf(uri.rawPath ?: "").firstOrNull() ?: return null
            return if (isValidId(id)) JukeboxLink(id, DEFAULT_GUEST_BASE) else null
        }
    }
}

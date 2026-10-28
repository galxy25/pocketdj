package com.levi.pocketdj.data.games.friends

import java.net.URI

/**
 * A parsed Music with Friends deep link (iOS `MwFLink`):
 *  - `https://jukebox.pocket-dj.com/mwf/<id>/` (landing page / QR payload)
 *  - `pocketdj://mwf/<id>` (also tolerates `pocketdj:///mwf/<id>`)
 *
 * The literal `mwf` segment can never collide with a jukebox id (`[a-z2-7]{4,32}`).
 */
data class MwFLink(val sessionId: String, val guestBase: String?) {

    /** `<base>/mwf/<id>/state.json` (canonical host when the link carried no https origin). */
    val stateUrl: String
        get() = "${guestBase ?: "https://$UNIVERSAL_HOST"}/mwf/$sessionId/state.json"

    companion object {
        const val SCHEME = "pocketdj"
        const val UNIVERSAL_HOST = "jukebox.pocket-dj.com"
        private const val ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"

        fun isValidId(s: String): Boolean = s.length in 4..32 && s.all { it in ID_ALPHABET }

        fun parse(raw: String): MwFLink? {
            val uri = runCatching { URI(raw.trim()) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            val host = uri.host?.lowercase().orEmpty()
            val segments = (uri.path ?: "").split('/').filter { it.isNotEmpty() }
            return when (scheme) {
                SCHEME -> {
                    val parts = segments.toMutableList()
                    if (host == "mwf") {
                        // id is parts.first()
                    } else if (parts.firstOrNull()?.lowercase() == "mwf") {
                        parts.removeAt(0)
                    } else {
                        return null
                    }
                    val id = parts.firstOrNull()?.takeIf { isValidId(it) } ?: return null
                    MwFLink(id, null)
                }
                "https", "http" -> {
                    if (host != UNIVERSAL_HOST) return null
                    if (segments.firstOrNull()?.lowercase() != "mwf" || segments.size < 2) return null
                    val id = segments[1].takeIf { isValidId(it) } ?: return null
                    MwFLink(id, "https://$host")
                }
                else -> null
            }
        }
    }
}

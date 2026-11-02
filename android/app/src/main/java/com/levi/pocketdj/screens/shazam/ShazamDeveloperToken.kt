package com.levi.pocketdj.screens.shazam

import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Local sanity check of the ES256 developer JWT handed to ShazamKit (header + claims only;
 * the signature is never inspected or logged).
 *
 * The token is the same one MusicKit uses (rip server `GET /musickit-token`, key 9JRN4H68X4).
 * Apple answers `api.shazam.apple.com/.../match` with a bare 401 (no body) for every rejected
 * token, whether it is malformed or validly signed by a key whose Media ID does not have the
 * ShazamKit service. This check catches the malformed cases on the device so a 401 that
 * gets past it points at the portal config (see [UNAUTHORIZED_MESSAGE]).
 */
object ShazamDeveloperToken {
    /** Apple's cap for media-services developer tokens: 6 months (15 777 000 s). */
    const val MAX_LIFETIME_SEC = 15_777_000L

    data class Parts(val header: JsonObject, val claims: JsonObject) {
        val alg: String? get() = header.str("alg")
        val kid: String? get() = header.str("kid")
        val iss: String? get() = claims.str("iss")
        val iat: Long? get() = claims.num("iat")
        val exp: Long? get() = claims.num("exp")
    }

    /** Decodes header + claims, or null when [token] is not a three-segment JWT with JSON parts. */
    fun decode(token: String): Parts? {
        val seg = token.trim().split('.')
        if (seg.size != 3 || seg.any { it.isEmpty() }) return null
        return runCatching {
            val dec = Base64.getUrlDecoder()
            Parts(
                Json.parseToJsonElement(String(dec.decode(seg[0]))).jsonObject,
                Json.parseToJsonElement(String(dec.decode(seg[1]))).jsonObject,
            )
        }.getOrNull()
    }

    /** Human-readable problems with [token] at [nowSec]; empty when the shape is what Apple expects. */
    fun problems(token: String, nowSec: Long = System.currentTimeMillis() / 1000): List<String> {
        val p = decode(token) ?: return listOf("not a JWT")
        val out = mutableListOf<String>()
        if (p.alg != "ES256") out += "alg is ${p.alg ?: "missing"}, expected ES256"
        if (p.kid.isNullOrBlank()) out += "kid (key id) missing"
        if (p.iss.isNullOrBlank()) out += "iss (team id) missing"
        val iat = p.iat
        val exp = p.exp
        if (iat == null) out += "iat missing"
        if (exp == null) out += "exp missing"
        if (iat != null && iat > nowSec + CLOCK_SKEW_SEC) out += "iat is in the future"
        if (exp != null && exp <= nowSec) out += "expired"
        if (iat != null && exp != null && exp - iat > MAX_LIFETIME_SEC) out += "lifetime exceeds 6 months"
        return out
    }

    private const val CLOCK_SKEW_SEC = 300L

    private fun JsonObject.str(k: String) = this[k]?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }
    private fun JsonObject.num(k: String) = this[k]?.let { runCatching { it.jsonPrimitive.longOrNull }.getOrNull() }
}

/**
 * Shown when Shazam answers UNAUTHORIZED for a token that passed [ShazamDeveloperToken.problems]:
 * the signing key is fine for Apple Music but not provisioned for ShazamKit.
 */
const val UNAUTHORIZED_MESSAGE =
    "Shazam rejected the developer token (401). The signing key's Media ID needs the ShazamKit service enabled."

/** User-facing text for a ShazamKit `MatchError` (by enum name, so tests need no SDK types). */
fun shazamMatchErrorMessage(matchError: String?, fallback: String?): String = when (matchError) {
    "UNAUTHORIZED" -> UNAUTHORIZED_MESSAGE
    "MATCH_ATTEMPT_FAILED" -> "Couldn’t reach Shazam. Try again."
    "INVALID_SIGNATURE", "INVALID_SIGNATURE_DURATION" -> "Couldn’t hear enough of the song. Try again closer to the speaker."
    "PROVIDED_EMPTY_AUDIO_DATA" -> "The microphone returned no audio."
    else -> fallback?.takeIf { it.isNotBlank() } ?: "Recognition failed"
}

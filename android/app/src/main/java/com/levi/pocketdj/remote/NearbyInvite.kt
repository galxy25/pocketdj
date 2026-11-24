package com.levi.pocketdj.remote

import com.levi.pocketdj.screens.remote.RemoteInvite
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The invite token + the Nearby endpoint-name convention (P2-REM-9).
 *
 * A host mints a short [token]. The invite QR encodes `pocketdj://remote/join/<token>` and the code under it is the
 * token. The token itself never goes on the air: advertisements and connection requests carry only its [hash], so a
 * stranger scanning the radio sees a hash of a 32^8 token, and the host REJECTS a connection request whose hash differs.
 *
 * Endpoint name layout (one string, `|` separated): `<device name>|<token hash>|<mode>` where mode is `L` (Listen
 * Together) or `B` (Backseat). A joiner picking a host from the Nearby list has no token; it sends hash [OPEN_HASH] and
 * the host accepts that only while it allows open joins (the user confirmed the host by name + the auth digits).
 */
object NearbyInvite {
    const val URL_PREFIX = "pocketdj://remote/join/"
    const val TOKEN_LENGTH = 8
    /** No 0/O/1/I/L: a code read aloud or typed in a car. */
    private const val ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    const val OPEN_HASH = "-"
    private const val MAX_DEVICE_NAME = 40

    fun newToken(random: java.util.Random = SecureRandom()): String =
        buildString { repeat(TOKEN_LENGTH) { append(ALPHABET[random.nextInt(ALPHABET.length)]) } }

    fun invite(token: String): RemoteInvite = RemoteInvite(code = token, url = URL_PREFIX + token)

    /** First 8 hex chars of SHA-256 of the upper-cased token. */
    fun hash(token: String): String {
        val d = MessageDigest.getInstance("SHA-256").digest(token.trim().uppercase().toByteArray(Charsets.UTF_8))
        return d.take(4).joinToString("") { "%02x".format(it) }
    }

    fun endpointName(deviceName: String, hash: String, mode: RemoteSessionMode?): String {
        val safe = deviceName.replace("|", " ").trim().take(MAX_DEVICE_NAME).ifEmpty { "Android" }
        val m = when (mode) { RemoteSessionMode.LISTEN_TOGETHER -> "L"; RemoteSessionMode.BACKSEAT -> "B"; null -> "" }
        return "$safe|$hash|$m"
    }

    data class Endpoint(val deviceName: String, val hash: String?, val mode: RemoteSessionMode?)

    /** Never throws: a name that isn't ours parses with a null [Endpoint.hash] (and so never matches a token). */
    fun parseEndpointName(name: String): Endpoint {
        val parts = name.split('|')
        if (parts.size < 2) return Endpoint(name, null, null)
        val mode = when (parts.getOrNull(2)) { "L" -> RemoteSessionMode.LISTEN_TOGETHER; "B" -> RemoteSessionMode.BACKSEAT; else -> null }
        return Endpoint(parts[0], parts[1].ifEmpty { null }, mode)
    }

    /** The host-side connection-request check: accept the right token hash, or an open join when allowed. */
    fun accepts(requestHash: String?, expectedHash: String, allowOpen: Boolean): Boolean =
        requestHash == expectedHash || (allowOpen && requestHash == OPEN_HASH)
}

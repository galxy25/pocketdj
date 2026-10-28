package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.sync.ProfileSecretStore.Companion.toHex
import java.nio.ByteBuffer
import java.util.UUID
import java.util.zip.CRC32

/**
 * Device-link code (SVC-9): carries a profile's `profileId` + `secret` to another device with NO
 * server involvement. Binary layout (53 bytes): `version(1) | uuid(16) | secret(32) | crc32(4, BE)`
 * where the CRC covers the first 49 bytes, rendered in Crockford base32 (no I/L/O/U ambiguity),
 * grouped `XXXXX-XXXXX-...`. A mistyped code fails the checksum LOCALLY, before any network.
 *
 * Also has a URI form `pocketdj://link?code=<code>` (QR payload; also accepted by [decode]).
 */
object LinkCode {
    const val VERSION = 1
    const val URI_PREFIX = "pocketdj://link?code="
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private const val BODY = 1 + 16 + 32
    private const val TOTAL = BODY + 4

    sealed interface Decoded {
        data class Ok(val profileId: String, val secret: String) : Decoded {
            override fun toString() = "Ok($profileId, secret=redacted)"
        }
        data object BadFormat : Decoded
        data object BadChecksum : Decoded
        data object UnsupportedVersion : Decoded
    }

    /** [profileId] must be a UUID (any case); [secret] 64 hex chars. Returns the grouped code. */
    fun encode(profileId: String, secret: String): String {
        val uuid = UUID.fromString(profileId)
        require(secret.length == 64 && secret.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) { "secret must be 64 hex chars" }
        val buf = ByteBuffer.allocate(TOTAL)
        buf.put(VERSION.toByte()).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits)
        for (i in 0 until 32) buf.put(secret.substring(i * 2, i * 2 + 2).toInt(16).toByte())
        buf.putInt(crc(buf.array(), BODY).toInt())
        return base32(buf.array()).chunked(5).joinToString("-")
    }

    fun toUri(profileId: String, secret: String): String = URI_PREFIX + encode(profileId, secret)

    /** Accepts a grouped/ungrouped, any-case code, or the URI form. */
    fun decode(input: String): Decoded {
        val code = extractCode(input)
        val norm = code.uppercase().filterNot { it == '-' || it.isWhitespace() }
            .map { when (it) { 'O' -> '0'; 'I', 'L' -> '1'; else -> it } }
        if (norm.isEmpty() || norm.any { ALPHABET.indexOf(it) < 0 }) return Decoded.BadFormat
        val bytes = unbase32(norm.joinToString("")) ?: return Decoded.BadFormat
        if (bytes.size != TOTAL) return Decoded.BadFormat
        val want = ByteBuffer.wrap(bytes, BODY, 4).int.toLong() and 0xffffffffL
        if (want != crc(bytes, BODY)) return Decoded.BadChecksum
        if (bytes[0].toInt() != VERSION) return Decoded.UnsupportedVersion
        val bb = ByteBuffer.wrap(bytes, 1, 16)
        val id = UUID(bb.long, bb.long).toString()
        val secret = bytes.copyOfRange(17, BODY).toHex()
        return Decoded.Ok(id, secret)
    }

    private fun extractCode(input: String): String {
        val t = input.trim()
        if (!t.contains("://")) return t
        val m = Regex("[?&]code=([^&#]+)", RegexOption.IGNORE_CASE).find(t) ?: return ""
        return m.groupValues[1]
    }

    private fun crc(b: ByteArray, len: Int): Long = CRC32().also { it.update(b, 0, len) }.value

    private fun base32(b: ByteArray): String {
        val sb = StringBuilder()
        var acc = 0; var bits = 0
        for (x in b) {
            acc = (acc shl 8) or (x.toInt() and 0xff); bits += 8
            while (bits >= 5) { sb.append(ALPHABET[(acc shr (bits - 5)) and 31]); bits -= 5 }
            acc = acc and ((1 shl bits) - 1)
        }
        if (bits > 0) sb.append(ALPHABET[(acc shl (5 - bits)) and 31])
        return sb.toString()
    }

    private fun unbase32(s: String): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        var acc = 0; var bits = 0
        for (c in s) {
            acc = (acc shl 5) or ALPHABET.indexOf(c); bits += 5
            if (bits >= 8) { out.write((acc shr (bits - 8)) and 0xff); bits -= 8 }
            acc = acc and ((1 shl bits) - 1)
        }
        return if (acc != 0) null else out.toByteArray() // non-zero pad bits => not a code we produced
    }
}

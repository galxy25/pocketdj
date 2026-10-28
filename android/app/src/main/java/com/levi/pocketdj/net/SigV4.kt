package com.levi.pocketdj.net

import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Pure AWS Signature V4 signer (decision D8; shared by the diag uploader and online search).
 * No Android imports: JVM-testable against the AWS documentation vectors.
 */
object SigV4 {
    data class Creds(val accessKeyId: String, val secret: String)

    data class Signed(
        /** Headers to attach to the request (everything signed except `host`, set by the client). */
        val headers: Map<String, String>,
        val signedHeaders: String,
        val canonicalRequest: String,
        val stringToSign: String,
        val signature: String,
    )

    private val AMZ: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC)

    fun amzDate(epochMs: Long): String = AMZ.format(Instant.ofEpochMilli(epochMs))

    fun sha256Hex(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    private fun hmac(key: ByteArray, msg: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(msg.toByteArray(Charsets.UTF_8))
    }

    /** RFC 3986 percent-encoding (unreserved kept); `/` kept when [keepSlash] (paths). */
    fun encode(s: String, keepSlash: Boolean): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '_' || ch == '.' || ch == '~' ||
                (keepSlash && ch == '/')
            ) sb.append(ch) else sb.append('%').append("%02X".format(c))
        }
        return sb.toString()
    }

    /**
     * Sign a request. [extraHeaders] are additional headers to sign (names case-insensitive).
     * `host`, `x-amz-content-sha256` and `x-amz-date` are always signed.
     */
    fun sign(
        method: String,
        host: String,
        path: String,
        body: ByteArray,
        region: String,
        service: String,
        creds: Creds,
        epochMs: Long,
        query: Map<String, String> = emptyMap(),
        extraHeaders: Map<String, String> = emptyMap(),
    ): Signed {
        val amz = amzDate(epochMs)
        val short = amz.substring(0, 8)
        val payloadHash = sha256Hex(body)

        val all = sortedMapOf<String, String>()
        extraHeaders.forEach { (k, v) -> all[k.lowercase()] = v.trim().replace(Regex("\\s+"), " ") }
        all["host"] = host
        all["x-amz-content-sha256"] = payloadHash
        all["x-amz-date"] = amz

        val canonicalHeaders = all.entries.joinToString("") { "${it.key}:${it.value}\n" }
        val signedHeaders = all.keys.joinToString(";")
        val canonicalQuery = query.entries
            .map { encode(it.key, false) to encode(it.value, false) }
            .sortedWith(compareBy({ it.first }, { it.second }))
            .joinToString("&") { "${it.first}=${it.second}" }
        val canonicalUri = encode(path.ifEmpty { "/" }, true)
        val canonicalRequest = listOf(method, canonicalUri, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash)
            .joinToString("\n")

        val scope = "$short/$region/$service/aws4_request"
        val stringToSign = "AWS4-HMAC-SHA256\n$amz\n$scope\n" + sha256Hex(canonicalRequest.toByteArray(Charsets.UTF_8))
        val kDate = hmac("AWS4${creds.secret}".toByteArray(Charsets.UTF_8), short)
        val kRegion = hmac(kDate, region)
        val kService = hmac(kRegion, service)
        val kSigning = hmac(kService, "aws4_request")
        val signature = hex(hmac(kSigning, stringToSign))

        val out = linkedMapOf<String, String>()
        extraHeaders.forEach { (k, v) -> out[k] = v }
        out["x-amz-date"] = amz
        out["x-amz-content-sha256"] = payloadHash
        out["Authorization"] =
            "AWS4-HMAC-SHA256 Credential=${creds.accessKeyId}/$scope, SignedHeaders=$signedHeaders, Signature=$signature"
        return Signed(out, signedHeaders, canonicalRequest, stringToSign, signature)
    }
}

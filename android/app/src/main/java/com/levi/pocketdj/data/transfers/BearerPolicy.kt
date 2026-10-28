package com.levi.pocketdj.data.transfers

import java.net.URI

/**
 * The bearer authenticates to the rip server — it must never ride to S3, which 400s BOTH a
 * presigned URL carrying a second auth mechanism AND a plain public-bucket GET carrying a
 * non-AWS Authorization header. Either error's small XML body used to be finalized as the
 * "downloaded" mp3 (the 2026-09-01 poisoned-burns bug). Pure so the regression test pins it.
 */
object BearerPolicy {
    /** [ripsBaseHost] is the (possibly CDN/own-domain) public rips bucket host after an endpoint flip. */
    fun shouldAttachBearer(url: String, token: String, ripsBaseHost: String?): Boolean {
        if (token.isEmpty()) return false
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        if (uri.rawQuery?.contains("X-Amz-Signature") == true) return false
        val host = uri.host?.lowercase()
        if (host != null && host.endsWith("amazonaws.com")) return false
        if (host != null && ripsBaseHost != null && host == ripsBaseHost.lowercase()) return false
        return true
    }

    /** Host of a base URL string, or null. */
    fun hostOf(base: String): String? = runCatching { URI(base.trim()).host }.getOrNull()
}

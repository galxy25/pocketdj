package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.PdjJson
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Resolves a 30-second Apple Music **preview** URL for a song's `appleMusicId`
 * (Apple "store id") — the emulator-OK AM path and the graceful fallback for a
 * signed-out / unsubscribed / x86_64 user (specs/applemusic.md §6.3). Previews
 * are plain progressive audio URLs: no Music-User-Token, no DRM, no native SDK,
 * so they play through the existing ExoPlayer path.
 *
 * Two resolution routes, tried in order:
 *  1. **Dev-token** — `GET api.music.apple.com/v1/catalog/{sf}/songs/{id}` with
 *     `Authorization: Bearer <developerToken>`; reads
 *     `data[0].attributes.previews[0].url`. Needs only the developer token.
 *  2. **Tokenless** — `GET itunes.apple.com/lookup?id={id}` → `results[0].previewUrl`.
 *     Needs no token at all — the zero-config emulator path.
 *
 * Resolved URLs are cached in memory keyed by `appleMusicId` (stable for a
 * session). Every network touch is guarded — a failure returns null, and the
 * caller degrades (no crash, specs/applemusic.md §6.6).
 */
class AppleMusicPreviewResolver(
    http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
    /** Supplies a pre-fetched developer token, or null when none is warm. */
    private val developerTokenProvider: suspend () -> String?,
    private val storefront: String = "us",
    /** Overridable for tests (default: the real Apple hosts). */
    private val catalogApiBase: String = "https://api.music.apple.com",
    private val itunesLookupBase: String = "https://itunes.apple.com/lookup",
) {
    private val shortClient: OkHttpClient =
        http.newBuilder().callTimeout(12, TimeUnit.SECONDS).build()

    private val cache = ConcurrentHashMap<String, String>()

    /** A preview URL for [appleMusicId], or null when none resolves. */
    suspend fun previewUrl(appleMusicId: String): String? {
        if (appleMusicId.isBlank()) return null
        cache[appleMusicId]?.let { return it }
        val resolved = withContext(Dispatchers.IO) {
            resolveViaDeveloperToken(appleMusicId) ?: resolveViaItunes(appleMusicId)
        }
        if (resolved != null) cache[appleMusicId] = resolved
        return resolved
    }

    /** Cancellable GET: cancelling the coroutine cancels the OkHttp call (a probe budget really stops it). */
    private suspend fun fetchBody(request: Request): String? =
        kotlinx.coroutines.suspendCancellableCoroutine { cont ->
            val call = shortClient.newCall(request)
            cont.invokeOnCancellation { runCatching { call.cancel() } }
            call.enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: java.io.IOException) {
                    if (cont.isActive) cont.resumeWith(Result.success(null))
                }

                override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                    val body = runCatching {
                        response.use { if (it.isSuccessful) it.body?.string().orEmpty() else null }
                    }.getOrNull()
                    if (cont.isActive) cont.resumeWith(Result.success(body))
                }
            })
        }

    private suspend fun resolveViaDeveloperToken(id: String): String? {
        val token = runCatching { developerTokenProvider() }.getOrNull()?.takeIf { it.isNotBlank() }
            ?: return null
        val url = "${catalogApiBase.trimEnd('/')}/v1/catalog/$storefront/songs/$id"
        val request = Request.Builder().url(url).header("Authorization", "Bearer $token").get().build()
        val body = fetchBody(request) ?: return null
        return runCatching {
            val root = json.parseToJsonElement(body).jsonObject
            root["data"]?.jsonArray?.firstOrNull()?.jsonObject
                ?.get("attributes")?.jsonObject
                ?.get("previews")?.jsonArray?.firstOrNull()?.jsonObject
                ?.get("url")?.jsonPrimitive?.content
                ?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    private suspend fun resolveViaItunes(id: String): String? {
        val sep = if (itunesLookupBase.contains('?')) "&" else "?"
        val url = "$itunesLookupBase${sep}id=$id"
        val body = fetchBody(Request.Builder().url(url).get().build()) ?: return null
        return runCatching {
            val root = json.parseToJsonElement(body).jsonObject
            root["results"]?.jsonArray?.firstOrNull()?.jsonObject
                ?.get("previewUrl")?.jsonPrimitive?.content
                ?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }
}

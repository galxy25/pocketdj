package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.PdjJson
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class JukeboxGuestException(val kind: Kind, val code: Int?, message: String) : Exception(message) {
    enum class Kind { Ended, RateLimited, Http, Transport, BadUrl, Undecodable, NotAcceptingRequests }
    val isEnded: Boolean get() = kind == Kind.Ended
}

/**
 * Guest ("client join") verbs against the PUBLIC jukebox surface (iOS `JukeboxClient.guestState` /
 * `submitGuestRequest`): read `<guestBase>/<id>/state.json` (cache-busted, no auth) and POST
 * `<apiBase>/jukebox/<id>/request`. No hostKey ever rides these calls.
 */
class JukeboxGuestClient(
    http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
    /** The install id: stable per-install `clientId` for server pacing + `X-PocketDJ-Device`. */
    private val installId: suspend () -> String,
    /** The configured broker URL (Settings), the fallback when `state.apiBase` is absent. */
    private val configuredBase: suspend () -> String,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val client: OkHttpClient =
        http.newBuilder().callTimeout(TIMEOUT_S, TimeUnit.SECONDS).build()

    /** Read the public state. 404/410 throw [JukeboxGuestException.Kind.Ended]. */
    suspend fun guestState(link: JukeboxLink): JukeboxGuestState = guestStateAt(link.stateUrl)

    /** Read a state.json at an explicit absolute URL (cache-busted). */
    suspend fun guestStateAt(stateUrl: String): JukeboxGuestState {
        val url = cacheBustedUrl(stateUrl, clock()) ?: throw badUrl()
        val request = Request.Builder()
            .url(url)
            .header("Cache-Control", "no-cache")
            .header("X-PocketDJ-Device", installId())
            .get()
            .build()
        return execute(request) { JukeboxGuestState.decode(json, it) }
    }

    /**
     * Submit a request. [stateApiBase] comes from the session's state.json; blank falls back to the
     * configured broker URL; both blank -> [JukeboxGuestException.Kind.NotAcceptingRequests].
     * Returns the server's request id (null if the broker didn't send one).
     */
    suspend fun submitRequest(
        jukeboxId: String,
        stateApiBase: String?,
        title: String,
        artist: String,
    ): String? {
        val id = installId()
        val base = resolveApiBase(stateApiBase, configuredBase())
            ?: throw JukeboxGuestException(
                JukeboxGuestException.Kind.NotAcceptingRequests, null, NOT_ACCEPTING_MESSAGE,
            )
        val url = requestUrl(base, jukeboxId) ?: throw badUrl()
        val request = Request.Builder()
            .url(url)
            .header("X-PocketDJ-Device", id)
            .post(requestBody(title, artist, id).toRequestBody(JSON_MEDIA_TYPE))
            .build()
        return execute(request) { text ->
            runCatching {
                json.parseToJsonElement(text).jsonObject["requestId"]?.jsonPrimitive?.content
            }.getOrNull()
        }
    }

    private fun badUrl() =
        JukeboxGuestException(JukeboxGuestException.Kind.BadUrl, null, "This jukebox link is invalid.")

    private suspend fun <T> execute(request: Request, decode: (String) -> T): T =
        withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute().use { response ->
                    val text = response.body?.string().orEmpty()
                    if (!response.isSuccessful) throw mapError(response.code, text)
                    try {
                        decode(text)
                    } catch (e: Exception) {
                        throw JukeboxGuestException(
                            JukeboxGuestException.Kind.Undecodable, response.code,
                            "Undecodable jukebox response",
                        )
                    }
                }
            } catch (e: IOException) {
                throw JukeboxGuestException(
                    JukeboxGuestException.Kind.Transport, null,
                    e.message ?: "Couldn't reach the jukebox",
                )
            }
        }

    private fun mapError(code: Int, body: String): JukeboxGuestException {
        val server = runCatching {
            json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
        return when (code) {
            404, 410 -> JukeboxGuestException(JukeboxGuestException.Kind.Ended, code, ENDED_MESSAGE)
            429 -> JukeboxGuestException(
                JukeboxGuestException.Kind.RateLimited, code,
                server?.takeIf { it.isNotBlank() } ?: RATE_LIMIT_MESSAGE,
            )
            else -> JukeboxGuestException(
                JukeboxGuestException.Kind.Http, code,
                server?.takeIf { it.isNotBlank() } ?: "Jukebox server error ($code)",
            )
        }
    }

    companion object {
        const val ENDED_MESSAGE = "This jukebox has ended."
        const val RATE_LIMIT_MESSAGE = "Too many requests — wait a moment and try again."
        const val NOT_ACCEPTING_MESSAGE = "This jukebox isn't taking requests"
        private const val TIMEOUT_S = 12L
        private val JSON_MEDIA_TYPE = "application/json".toMediaType()

        /** Append a `_` timestamp param so a CDN copy is never served stale. */
        fun cacheBustedUrl(stateUrl: String, nowMs: Long): okhttp3.HttpUrl? =
            stateUrl.toHttpUrlOrNull()?.newBuilder()?.addQueryParameter("_", nowMs.toString())?.build()

        /** `state.apiBase` wins; else the configured broker URL; blank -> null. */
        fun resolveApiBase(stateApiBase: String?, configured: String): String? {
            val fromState = stateApiBase?.trim()?.trimEnd('/').orEmpty()
            if (fromState.isNotEmpty()) return fromState
            val fallback = configured.trim().trimEnd('/')
            return fallback.ifEmpty { null }
        }

        fun requestUrl(apiBase: String, jukeboxId: String): okhttp3.HttpUrl? =
            apiBase.trim().trimEnd('/').toHttpUrlOrNull()?.newBuilder()
                ?.addPathSegment("jukebox")?.addPathSegment(jukeboxId)?.addPathSegment("request")
                ?.build()

        /** `{title, artist, clientId}` — the exact shape the broker's public endpoint reads. */
        fun requestBody(title: String, artist: String, clientId: String): String =
            buildJsonObject {
                put("title", title)
                put("artist", artist)
                put("clientId", clientId)
            }.toString()
    }
}

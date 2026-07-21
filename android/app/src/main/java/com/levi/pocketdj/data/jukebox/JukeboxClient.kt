package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.PdjJson
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * HTTP client for the jukebox broker (specs/jukebox.md §2, §7). The broker is
 * the reused `scripts/jukebox-server.mjs` (protocol version 2); Android is a
 * new host ("DJ") client speaking the same API the iOS `JukeboxClient` speaks.
 *
 * Auth (jukebox.md §2.2): the server-level token is the bearer on create (and
 * sent on health, harmless); the per-session `hostKey` is the bearer on every
 * other host route. `Authorization` is OMITTED ENTIRELY when the credential is
 * empty. `X-PocketDJ-Device` rides every call; `X-PocketDJ-Profile` is omitted
 * on Android P1 (no profiles).
 */
class JukeboxClient(
    http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
    /** Pulls the live Settings values (URL/token) + install id per call. */
    private val configProvider: suspend () -> Config,
) {
    data class Config(
        val baseUrl: String,
        val token: String,
        val installId: String,
    ) {
        val normalizedBase: String get() = JukeboxUrls.normalizedBase(baseUrl)
        val configured: Boolean get() = normalizedBase.isNotEmpty()
    }

    /** [code] is the HTTP status (null for local/transport failures). */
    class JukeboxException(val code: Int?, message: String) : Exception(message)

    /** 12 s doctrine: an asleep/unreachable broker fails fast (jukebox.md §7). */
    private val shortClient: OkHttpClient =
        http.newBuilder().callTimeout(SHORT_TIMEOUT_S, TimeUnit.SECONDS).build()

    /** 30 s for create (two S3 uploads) and end (jukebox.md §7). */
    private val longClient: OkHttpClient =
        http.newBuilder().callTimeout(LONG_TIMEOUT_S, TimeUnit.SECONDS).build()

    suspend fun isConfigured(): Boolean = configProvider().configured

    /** `GET /health` — the Settings "test connection" affordance. */
    suspend fun health(): JukeboxHealth {
        val config = requireConfig()
        val url = JukeboxUrls.health(config.normalizedBase) ?: throw invalidUrl()
        val request = builder(config.installId, bearer = config.token).url(url).get().build()
        return execute(shortClient, request) { body -> json.decodeFromString<JukeboxHealth>(body) }
    }

    /**
     * `POST /jukebox` — create a session (jukebox.md §2.3 #2). Always
     * `timeless:false` on Android P1; `requiresToken` is sent as intent (the
     * server ignores it today and does not echo it back).
     */
    suspend fun createSession(name: String, requiresToken: Boolean): JukeboxSessionInfo {
        val config = requireConfig()
        val url = JukeboxUrls.create(config.normalizedBase) ?: throw invalidUrl()
        val body = buildJsonObject {
            put("name", name)
            put("timeless", false)
            put("requiresToken", requiresToken)
        }.toString().toRequestBody(JSON_MEDIA_TYPE)
        val request = builder(config.installId, bearer = config.token).url(url).post(body).build()
        return execute(longClient, request) { text ->
            json.decodeFromString<JukeboxSessionInfo>(text)
        }
    }

    /** `POST /jukebox/{id}/state` — hostKey bearer (jukebox.md §2.3 #3). */
    suspend fun postState(session: JukeboxSessionInfo, payload: JukeboxStatePayload) {
        val config = requireConfig()
        val url = JukeboxUrls.state(config.normalizedBase, session.jukeboxId) ?: throw invalidUrl()
        val body = json.encodeToString(JukeboxStatePayload.serializer(), payload)
            .toRequestBody(JSON_MEDIA_TYPE)
        val request = builder(config.installId, bearer = session.hostKey).url(url).post(body).build()
        execute(shortClient, request) { }
    }

    /** `GET /jukebox/{id}/requests?since=` — every request with seq > since. */
    suspend fun requests(session: JukeboxSessionInfo, since: Long): JukeboxRequestsPage {
        val config = requireConfig()
        val url = JukeboxUrls.requests(config.normalizedBase, session.jukeboxId, since)
            ?: throw invalidUrl()
        val request = builder(config.installId, bearer = session.hostKey).url(url).get().build()
        return execute(shortClient, request) { text ->
            json.decodeFromString<JukeboxRequestsPage>(text)
        }
    }

    /** `POST /jukebox/{id}/requests/{reqId}/decision` (jukebox.md §2.3 #5). */
    suspend fun decide(
        session: JukeboxSessionInfo,
        requestId: String,
        action: JukeboxDecisionAction,
    ) {
        val config = requireConfig()
        val url = JukeboxUrls.decision(config.normalizedBase, session.jukeboxId, requestId)
            ?: throw invalidUrl()
        val body = buildJsonObject { put("action", action.wire) }
            .toString().toRequestBody(JSON_MEDIA_TYPE)
        val request = builder(config.installId, bearer = session.hostKey).url(url).post(body).build()
        execute(shortClient, request) { }
    }

    /** `POST /jukebox/{id}/end` — 30 s timeout (jukebox.md §4.1). */
    suspend fun end(session: JukeboxSessionInfo) {
        val config = requireConfig()
        val url = JukeboxUrls.end(config.normalizedBase, session.jukeboxId) ?: throw invalidUrl()
        val request = builder(config.installId, bearer = session.hostKey)
            .url(url)
            .post(ByteArray(0).toRequestBody(JSON_MEDIA_TYPE))
            .build()
        execute(longClient, request) { }
    }

    private suspend fun requireConfig(): Config {
        val config = configProvider()
        if (!config.configured) {
            throw JukeboxException(null, "Jukebox server URL is not set — check Settings.")
        }
        return config
    }

    private fun invalidUrl() =
        JukeboxException(null, "Jukebox server URL is invalid — check Settings.")

    private fun builder(installId: String, bearer: String): Request.Builder {
        val builder = Request.Builder().header("X-PocketDJ-Device", installId)
        if (bearer.isNotEmpty()) builder.header("Authorization", "Bearer $bearer")
        return builder
    }

    private suspend fun <T> execute(
        client: OkHttpClient,
        request: Request,
        decode: (String) -> T,
    ): T = withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw JukeboxException(response.code, errorMessage(response.code, text))
            }
            runCatching { decode(text) }.getOrElse {
                throw JukeboxException(response.code, "Undecodable jukebox server response")
            }
        }
    }

    private fun errorMessage(code: Int, body: String): String {
        val serverError = runCatching {
            json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
        return when {
            code == 401 || code == 403 -> "Unauthorized — check the jukebox token in Settings"
            code == 404 || code == 410 -> "This jukebox has ended."
            serverError != null -> serverError
            else -> "Jukebox server error ($code)"
        }
    }

    private companion object {
        const val SHORT_TIMEOUT_S = 12L
        const val LONG_TIMEOUT_S = 30L
        val JSON_MEDIA_TYPE = "application/json".toMediaType()
    }
}

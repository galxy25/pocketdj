package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.PdjJson
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * HTTP client for the user's rip server (specs/playback.md §4). Protocol v2.
 *
 * Auth contract (load-bearing): `Authorization: Bearer <token>` is OMITTED
 * ENTIRELY when the token is empty — a tokened server 401s a bare "Bearer ",
 * and a tokenless server needs no header. `X-PocketDJ-Device` rides every call;
 * `X-PocketDJ-Profile` is omitted on Android P1 (no profiles).
 */
class RipServerClient(
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
        /** Trim whitespace and ONE trailing slash before concatenating paths. */
        val normalizedBase: String get() = baseUrl.trim().removeSuffix("/")
        val configured: Boolean get() = normalizedBase.isNotEmpty()
    }

    class RipServerException(val code: Int?, message: String) : Exception(message)

    /** 12 s doctrine: an unreachable server fails fast instead of hanging the UI. */
    private val shortClient: OkHttpClient =
        http.newBuilder().callTimeout(12, TimeUnit.SECONDS).build()

    suspend fun isConfigured(): Boolean = configProvider().configured

    /**
     * `GET /health` — Settings "test connection" affordance. Pass [candidateUrl]
     * (+ [candidateToken]) to probe a typed-but-unsaved server WITHOUT
     * committing it to Settings — a failed test must not persist a bad URL.
     */
    suspend fun health(candidateUrl: String? = null, candidateToken: String? = null): RipServerHealth {
        val config = if (candidateUrl != null) {
            Config(
                baseUrl = candidateUrl,
                token = candidateToken.orEmpty().trim(),
                installId = configProvider().installId,
            ).also {
                if (!it.configured) throw RipServerException(null, "No import server configured (Settings)")
            }
        } else {
            requireConfig()
        }
        val request = builder(config, url(config, "health")).get().build()
        return execute(request) { body -> json.decodeFromString<RipServerHealth>(body) }
    }

    /**
     * `POST /rip` — trigger (or join/short-circuit) a rip. Returns the job view;
     * `isReady` with a `url` means already ripped — play it directly.
     * Studio ids are fenced client-side and never reach the network.
     */
    suspend fun requestRip(songId: String): RipJob {
        require(!PlayResolver.isStudioId(songId)) {
            "Studio ids are device-local (not rippable): $songId"
        }
        val config = requireConfig()
        val body = buildJsonObject { put("songId", songId) }.toString()
            .toRequestBody("application/json".toMediaType())
        val request = builder(config, url(config, "rip")).post(body).build()
        return execute(request) { text -> json.decodeFromString<RipJob>(text) }
    }

    /** `GET /jobs/<jobId>` — poll a rip. The id is percent-encoded in the path. */
    suspend fun job(jobId: String): RipJob {
        val config = requireConfig()
        val request = builder(config, url(config, "jobs", jobId)).get().build()
        return execute(request) { text -> json.decodeFromString<RipJob>(text) }
    }

    /**
     * Foreground wait (iOS contract): poll every 1 s up to 1800 tries (~30 min);
     * returns the durable URL on `ready`; THROWS on `phase == "error"` (only the
     * foreground wait does — the server may still re-queue in the background).
     *
     * A single dropped poll (flaky Funnel, brief network change) must NOT abort
     * a minutes-long rip wait — like [pollUntilDurable], each poll is wrapped;
     * only [maxPollFailures] CONSECUTIVE failures give up (server truly gone).
     */
    suspend fun awaitReady(
        jobId: String,
        pollMs: Long = 1_000,
        maxTries: Int = 1_800,
        maxPollFailures: Int = 10,
    ): String {
        var consecutiveFailures = 0
        repeat(maxTries) {
            val result = runCatching { job(jobId) }
            result.exceptionOrNull()?.let { if (it is kotlinx.coroutines.CancellationException) throw it }
            val view = result.getOrNull()
            if (view == null) {
                consecutiveFailures += 1
                if (consecutiveFailures >= maxPollFailures) {
                    throw result.exceptionOrNull() as? RipServerException
                        ?: RipServerException(null, "Import server unreachable while waiting for the rip")
                }
            } else {
                consecutiveFailures = 0
                view.url?.takeIf { view.isReady }?.let { return it }
                if (view.phase == RipJob.PHASE_ERROR) {
                    throw RipServerException(null, view.error ?: "Rip failed")
                }
            }
            delay(pollMs)
        }
        throw RipServerException(null, "Rip timed out")
    }

    /**
     * Background poll (iOS contract): every 2 s up to 1800 tries (~1 h), used
     * after handing back a live stream so playback can swap to the durable mp3.
     * Does NOT stop on `phase == "error"` — the server auto-heals and re-queues
     * failed jobs (error → queued).
     */
    fun pollUntilDurable(
        scope: CoroutineScope,
        jobId: String,
        pollMs: Long = 2_000,
        maxTries: Int = 1_800,
        onDurable: suspend (String) -> Unit,
    ): Job = scope.launch {
        repeat(maxTries) {
            val view = runCatching { job(jobId) }.getOrNull()
            view?.url?.takeIf { view.isReady }?.let {
                onDurable(it)
                return@launch
            }
            delay(pollMs)
        }
    }

    private suspend fun requireConfig(): Config {
        val config = configProvider()
        if (!config.configured) {
            throw RipServerException(null, "No import server configured (Settings)")
        }
        return config
    }

    private fun url(config: Config, vararg segments: String): HttpUrl {
        val base = config.normalizedBase.toHttpUrlOrNull()
            ?: throw RipServerException(null, "Import server URL is invalid — check Settings.")
        return base.newBuilder().apply { segments.forEach(::addPathSegment) }.build()
    }

    private fun builder(config: Config, url: HttpUrl): Request.Builder {
        val builder = Request.Builder()
            .url(url)
            .header("X-PocketDJ-Device", config.installId)
        if (config.token.isNotEmpty()) {
            builder.header("Authorization", "Bearer ${config.token}")
        }
        return builder
    }

    private suspend fun <T> execute(request: Request, decode: (String) -> T): T =
        withContext(Dispatchers.IO) {
            shortClient.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    throw RipServerException(response.code, errorMessage(response.code, text))
                }
                runCatching { decode(text) }.getOrElse {
                    throw RipServerException(response.code, "Undecodable server response")
                }
            }
        }

    private fun errorMessage(code: Int, body: String): String {
        val serverError = runCatching {
            json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
        return when {
            code == 401 || code == 403 -> "Unauthorized — check the import-server token in Settings"
            serverError != null -> serverError
            else -> "Rip failed ($code)"
        }
    }
}

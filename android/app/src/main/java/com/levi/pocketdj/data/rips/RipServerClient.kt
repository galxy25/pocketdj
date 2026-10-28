package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.stems.BatchStemItem
import com.levi.pocketdj.data.stems.BatchStemResponse
import com.levi.pocketdj.data.stems.BatchStemResult
import com.levi.pocketdj.data.stems.StemClient
import com.levi.pocketdj.data.stems.StemJob
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
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

    /** One /jobs poll must not outlive the poll cadence by much on a dead link. */
    private val pollClient: OkHttpClient =
        http.newBuilder().callTimeout(RipSettings.JOB_POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS).build()

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
        return execute(request, pollClient) { text -> json.decodeFromString<RipJob>(text) }
    }

    /**
     * Interactive ▶ wait (iOS `ensureURL` contract): poll every 1 s, bounded by WALL-CLOCK
     * [maxWaitMs] (20 s) — a count of iterations would let a dead link park the UI for minutes.
     * Returns [RipWaitOutcome.Ready] with the durable URL on `ready`; THROWS on
     * `phase == "error"` (only this foreground wait does — the server may still re-queue in the
     * background); when the deadline passes with the job still working returns
     * [RipWaitOutcome.StillRipping] (NOT a failure: the caller hands the job to RipJobTracker).
     *
     * A single dropped poll must not abort the wait; only [maxPollFailures] CONSECUTIVE failures
     * give up (server truly gone). [clock] is injectable so tests drive a virtual clock.
     */
    suspend fun awaitReadyInteractive(
        jobId: String,
        maxWaitMs: Long = RipSettings.INTERACTIVE_WAIT_MS,
        pollMs: Long = RipSettings.INTERACTIVE_POLL_MS,
        maxPollFailures: Int = RipSettings.MAX_POLL_FAILURES,
        clock: () -> Long = System::currentTimeMillis,
    ): RipWaitOutcome {
        val deadline = clock() + maxWaitMs.coerceAtLeast(1)
        var consecutiveFailures = 0
        while (clock() < deadline) {
            delay(pollMs)
            val result = runCatching { job(jobId) }
            result.exceptionOrNull()?.let { if (it is kotlinx.coroutines.CancellationException) throw it }
            val view = result.getOrNull()
            if (view == null) {
                consecutiveFailures += 1
                if (consecutiveFailures >= maxPollFailures) {
                    throw result.exceptionOrNull() as? RipServerException
                        ?: RipServerException(null, "Import server unreachable while waiting for the rip")
                }
                continue
            }
            consecutiveFailures = 0
            view.url?.takeIf { view.isReady }?.let { return RipWaitOutcome.Ready(it) }
            if (view.phase == RipJob.PHASE_ERROR) {
                throw RipServerException(null, view.error ?: "Rip failed")
            }
        }
        return RipWaitOutcome.StillRipping(jobId)
    }

    /**
     * `GET /rips/presign?songId=&ttl=` — the rips bucket is private, so a cached song's playable
     * URL costs one bearer-gated round trip. [ttlSeconds] null = server default (1 h).
     */
    suspend fun presign(songId: String, ttlSeconds: Int? = null): String {
        val config = requireConfig()
        val url = url(config, "rips", "presign").newBuilder().apply {
            addQueryParameter("songId", songId)
            if (ttlSeconds != null) addQueryParameter("ttl", ttlSeconds.toString())
        }.build()
        val request = builder(config, url).get().build()
        return execute(request) { text ->
            json.parseToJsonElement(text).jsonObject["url"]?.jsonPrimitive?.content
                ?.takeIf { it.isNotBlank() } ?: error("no url")
        }
    }

    /**
     * Batch-enqueue a collection (`POST /rip-collection`). Dedups ids (order kept) and fences
     * device-local ids BEFORE the network. A 404 (older server) / unconfigured / transport
     * failure falls back to a per-song `/rip` loop that synthesizes the counts; a non-2xx
     * answer yields an empty result (iOS). [isRipped] short-circuits already-ripped songs in
     * the fallback.
     */
    suspend fun ripCollection(
        songIds: List<String>,
        isRipped: (String) -> Boolean = { false },
    ): BatchRipResult {
        val ids = songIds.filterNot(::isDeviceLocalId).distinct()
        if (ids.isEmpty()) return BatchRipResult()
        val config = configProvider()
        if (!config.configured) return ripCollectionFallback(ids, isRipped)
        return try {
            val body = buildJsonObject {
                put("songIds", kotlinx.serialization.json.JsonArray(ids.map(::JsonPrimitive)))
            }.toString().toRequestBody("application/json".toMediaType())
            val request = builder(config, url(config, "rip-collection")).post(body).build()
            val (code, text) = withContext(Dispatchers.IO) {
                shortClient.newCall(request).execute().use { it.code to it.body?.string().orEmpty() }
            }
            when {
                code == 404 -> ripCollectionFallback(ids, isRipped)
                code !in 200..299 -> BatchRipResult()
                else -> {
                    val decoded = json.decodeFromString<BatchRipResponse>(text)
                    BatchRipResult(
                        results = decoded.results,
                        ready = decoded.counts.ready,
                        queued = decoded.counts.queued,
                        inflight = decoded.counts.inflight,
                        unknown = decoded.counts.unknown,
                        total = decoded.counts.total,
                    )
                }
            }
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            ripCollectionFallback(ids, isRipped)
        }
    }

    private suspend fun ripCollectionFallback(ids: List<String>, isRipped: (String) -> Boolean): BatchRipResult {
        val configured = configProvider().configured
        val items = ids.map { id ->
            when {
                isRipped(id) -> BatchRipItem(id, "ready")
                configured -> {
                    val job = try {
                        requestRip(id)
                    } catch (error: Exception) {
                        if (error is kotlinx.coroutines.CancellationException) throw error
                        null
                    }
                    val status = if (job?.isReady == true) "ready" else RipPhases.batchStatus(job?.phase)
                    BatchRipItem(id, status, job?.jobId, job?.url)
                }
                else -> BatchRipItem(id, "unknown")
            }
        }
        fun count(status: String) = items.count { it.status == status }
        return BatchRipResult(
            results = items,
            ready = count("ready"), queued = count("queued"),
            inflight = count("inflight"), unknown = count("unknown"),
            total = items.size,
        )
    }

    /**
     * STOP in-flight rips (`POST /rip-cancel`): the server drops still-queued matching jobs and
     * kills the running worker. Idempotent, dedups ids, no-op without a server; an older server
     * that 404s is a silent no-op. If the answer is undecodable but 2xx, every requested id is
     * reported canceled (best effort).
     */
    suspend fun cancelRips(songIds: List<String>): List<CancelItem> {
        val ids = songIds.distinct()
        if (ids.isEmpty()) return emptyList()
        val config = configProvider()
        if (!config.configured) return emptyList()
        return try {
            val body = buildJsonObject {
                put("songIds", kotlinx.serialization.json.JsonArray(ids.map(::JsonPrimitive)))
            }.toString().toRequestBody("application/json".toMediaType())
            val request = builder(config, url(config, "rip-cancel")).post(body).build()
            val (code, text) = withContext(Dispatchers.IO) {
                shortClient.newCall(request).execute().use { it.code to it.body?.string().orEmpty() }
            }
            if (code !in 200..299) return emptyList()
            runCatching { json.decodeFromString<CancelResponse>(text).results }
                .getOrElse { ids.map { CancelItem(it, "canceled") } }
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            emptyList()
        }
    }

    /**
     * `POST /stemify` — fire-and-forget stem request for ONE song (iOS `RipsStore.stemify`).
     * Returns the job view, or null when refused / unreachable / undecodable (never throws except
     * cancellation). Fenced ids never reach the network.
     */
    suspend fun requestStemify(songId: String): StemJob? {
        if (StemClient.isFenced(songId)) return null
        val config = configProvider()
        if (!config.configured) return null
        return try {
            val body = buildJsonObject { put("songId", songId) }.toString()
                .toRequestBody("application/json".toMediaType())
            val request = builder(config, url(config, "stemify")).post(body).build()
            execute(request) { text -> json.decodeFromString<StemJob>(text) }
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            null
        }
    }

    /** `GET /jobs/<id>` decoded as a stem job (the stem phases are not rip phases). */
    suspend fun stemJob(jobId: String): StemJob {
        val config = requireConfig()
        val request = builder(config, url(config, "jobs", jobId)).get().build()
        return execute(request, pollClient) { text -> json.decodeFromString<StemJob>(text) }
    }

    /**
     * `POST /stemify-collection`. Dedups, fences studio/device-local ids, 404 (older server) /
     * transport failure -> per-song fallback via [fallbackOne]; non-2xx -> empty; the over-cap
     * envelope yields `needsConfirm` (re-call with [confirmLarge]).
     */
    suspend fun stemifyCollection(
        songIds: List<String>,
        confirmLarge: Boolean = false,
        isStemmed: (String) -> Boolean = { false },
        fallbackOne: suspend (String) -> StemJob? = { requestStemify(it) },
    ): BatchStemResult {
        val ids = songIds.filterNot(StemClient::isFenced).distinct()
        if (ids.isEmpty()) return BatchStemResult()
        val config = configProvider()
        if (!config.configured) return stemifyFallback(ids, false, isStemmed, fallbackOne)
        return try {
            val body = buildJsonObject {
                put("songIds", kotlinx.serialization.json.JsonArray(ids.map(::JsonPrimitive)))
                if (confirmLarge) put("confirmLarge", true)
            }.toString().toRequestBody("application/json".toMediaType())
            val request = builder(config, url(config, "stemify-collection")).post(body).build()
            val (code, text) = withContext(Dispatchers.IO) {
                shortClient.newCall(request).execute().use { it.code to it.body?.string().orEmpty() }
            }
            when {
                code == 404 -> stemifyFallback(ids, true, isStemmed, fallbackOne)
                code !in 200..299 -> BatchStemResult()
                else -> {
                    val d = json.decodeFromString<BatchStemResponse>(text)
                    if (d.needsConfirm == true) {
                        BatchStemResult(needsConfirm = true, count = d.count ?: ids.size, cap = d.cap ?: 0)
                    } else {
                        BatchStemResult(
                            results = d.results,
                            ready = d.counts.ready, queued = d.counts.queued, inflight = d.counts.inflight,
                            ripping = d.counts.ripping, needsCut = d.counts.needsCut,
                            ineligible = d.counts.ineligible, unknown = d.counts.unknown, total = d.counts.total,
                        )
                    }
                }
            }
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            stemifyFallback(ids, true, isStemmed, fallbackOne)
        }
    }

    private suspend fun stemifyFallback(
        ids: List<String>,
        hasServer: Boolean,
        isStemmed: (String) -> Boolean,
        fallbackOne: suspend (String) -> StemJob?,
    ): BatchStemResult {
        val items = ids.map { id ->
            when {
                isStemmed(id) -> BatchStemItem(id, "ready")
                hasServer -> {
                    val job = fallbackOne(id)
                    BatchStemItem(id, StemClient.batchStatus(job?.phase), job?.jobId)
                }
                else -> BatchStemItem(id, "unknown")
            }
        }
        fun count(status: String) = items.count { it.status == status }
        return BatchStemResult(
            results = items, ready = count("ready"), queued = count("queued"),
            ripping = count("ripping"), ineligible = count("ineligible"), unknown = count("unknown"),
            total = items.size,
        )
    }

    /** Studio ids and "Pocket DJ" profile ids (pdj_) are device-local and never rip. */
    private fun isDeviceLocalId(id: String): Boolean =
        PlayResolver.isStudioId(id) || id.startsWith("pdj_")

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

    private suspend fun <T> execute(request: Request, client: OkHttpClient = shortClient, decode: (String) -> T): T =
        withContext(Dispatchers.IO) {
            client.newCall(request).execute().use { response ->
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

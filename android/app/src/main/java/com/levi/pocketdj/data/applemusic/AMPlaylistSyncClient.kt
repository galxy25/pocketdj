package com.levi.pocketdj.data.applemusic

import android.content.Context
import com.levi.pocketdj.data.config.EndpointKey
import com.levi.pocketdj.data.config.RemoteEndpoints
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** A library playlist read by PULL (iOS `AMPlaylistSyncClient.RemotePlaylist`). */
@Serializable
data class AmRemotePlaylist(
    val id: String,
    val name: String,
    val canEdit: Boolean? = null,
    val description: String? = null,
    val trackCatalogIds: List<String> = emptyList(),
    val trackTitles: List<String>? = null,
)

/** One entry of the PUSH payload; [localPlaylistIds]/[localPocketIds] are a client-only round-trip handle. */
data class AmOutgoingPlaylist(
    val name: String,
    val description: String? = null,
    val trackCatalogIds: List<String> = emptyList(),
    /** Per-catalog-id song identity for the server's NAME+ARTIST duplicate gate. */
    val trackMeta: List<TrackMeta> = emptyList(),
    val localPlaylistIds: List<String> = emptyList(),
    val localPocketIds: List<String> = emptyList(),
) {
    data class TrackMeta(val id: String, val n: String, val a: String)
}

/** Per-playlist outcome of the idempotent push. */
@Serializable
data class AmPushResult(
    val playlists: List<Row> = emptyList(),
    val errors: List<Failure> = emptyList(),
) {
    @Serializable
    data class Row(val name: String, val id: String? = null, val created: Boolean = false, val added: Int = 0, val total: Int? = null)

    @Serializable
    data class Failure(val name: String, val error: String)
}

/** Server-published progress for a running job - feeds the step-by-step UI. */
@Serializable
data class AmJobProgress(val label: String, val done: Int? = null, val total: Int? = null) {
    val display: String
        get() = when {
            done != null && total != null && total > 0 -> "$label ($done/$total)"
            done != null && done > 0 -> "$label ($done)"
            else -> label
        }
}

/** Client failure modes. Only [JobGone], [Worker] and 4xx [Http] are PROOF the job is dead. */
sealed class AmSyncException(message: String) : Exception(message) {
    class Http(val code: Int, val body: String) :
        AmSyncException("Apple Music sync failed (HTTP $code)${if (body.isEmpty()) "" else ": ${body.take(200)}"}")

    class Stalled(val last: String) :
        AmSyncException("Apple Music sync stopped making progress (last step: $last). Tap Sync to resume where it left off.")

    class Worker(val msg: String) : AmSyncException("Apple Music sync failed: ${msg.take(240)}")

    class JobGone : AmSyncException("The previous sync expired — tap Sync to start again.")

    class NotSignedIn : AmSyncException("Sign in to Apple Music (Settings ▸ Apple Music) before syncing.")
}

/** Where the active jobId lives between taps/launches (iOS UserDefaults `pdj.amsync.activeJob.<op>`). */
interface AmJobStore {
    fun load(op: String): StoredJob?
    fun store(op: String, job: StoredJob)
    fun clear(op: String)

    data class StoredJob(val jobId: String, val atMs: Long)
}

class InMemoryAmJobStore : AmJobStore {
    private val m = java.util.concurrent.ConcurrentHashMap<String, AmJobStore.StoredJob>()
    override fun load(op: String) = m[op]
    override fun store(op: String, job: AmJobStore.StoredJob) { m[op] = job }
    override fun clear(op: String) { m.remove(op) }
}

class SharedPrefsAmJobStore(context: Context) : AmJobStore {
    private val prefs = context.applicationContext.getSharedPreferences("pdj-amsync", Context.MODE_PRIVATE)
    override fun load(op: String): AmJobStore.StoredJob? {
        val id = prefs.getString("activeJob.$op.id", null) ?: return null
        return AmJobStore.StoredJob(id, prefs.getLong("activeJob.$op.at", 0L))
    }
    override fun store(op: String, job: AmJobStore.StoredJob) {
        prefs.edit().putString("activeJob.$op.id", job.jobId).putLong("activeJob.$op.at", job.atMs).apply()
    }
    override fun clear(op: String) { prefs.edit().remove("activeJob.$op.id").remove("activeJob.$op.at").apply() }
}

/**
 * HTTP client for the WS2 Apple Music playlist-sync Lambda (iOS `AMPlaylistSyncClient`).
 *
 * POST /pull|/push returns `{jobId}` (202) in <1 s; the server works in checkpointed chunks and
 * publishes `{label, done, total}`; this client polls `GET /job/{jobId}` and gives up only when
 * progress STALLS ([stallTimeoutMs] with no advance), never on a wall clock. The active jobId is
 * remembered so a re-tap or relaunch RE-ATTACHES instead of starting over. PUSH is idempotent
 * server-side (create-if-absent + append-only-missing). The Music-User-Token is sent per call and
 * never stored server-side.
 *
 * [baseProvider] is read LIVE per submit/poll start; a poll loop captures its job URL once so an
 * endpoint flip never strands a running job. [clockMs]/[sleep] are seams for deterministic tests.
 */
class AMPlaylistSyncClient(
    private val http: OkHttpClient,
    private val tokens: AppleMusicTokens,
    private val jobs: AmJobStore,
    private val baseProvider: suspend () -> String = { RemoteEndpoints.url(EndpointKey.AM_PLAYLIST_SYNC_BASE) },
    private val stallTimeoutMs: Long = 180_000,
    private val pollIntervalMs: Long = 2_000,
    private val clockMs: () -> Long = System::currentTimeMillis,
    private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true; explicitNulls = false }

    /** PULL - the user's Apple Music library playlists. */
    suspend fun pull(onProgress: ((AmJobProgress) -> Unit)? = null): List<AmRemotePlaylist> {
        val result = runJob("pull", null, onProgress)
        val list = (result as? JsonObject)?.get("playlists") as? JsonArray ?: throw AmSyncException.Worker("bad pull result")
        return list.map { json.decodeFromJsonElement(AmRemotePlaylist.serializer(), it) }
    }

    /** PUSH - idempotently mirror [playlists] into the Apple Music library. */
    suspend fun push(playlists: List<AmOutgoingPlaylist>, onProgress: ((AmJobProgress) -> Unit)? = null): AmPushResult {
        if (playlists.isEmpty()) return AmPushResult()
        val payload = buildJsonArray {
            for (pl in playlists) add(
                buildJsonObject {
                    put("name", pl.name)
                    put("trackCatalogIds", JsonArray(pl.trackCatalogIds.map { JsonPrimitive(it) }))
                    pl.description?.let { put("description", it) }
                    if (pl.trackMeta.isNotEmpty()) {
                        put(
                            "trackMeta",
                            JsonArray(pl.trackMeta.map { m -> buildJsonObject { put("id", m.id); put("n", m.n); put("a", m.a) } }),
                        )
                    }
                },
            )
        }
        val result = runJob("push", buildJsonObject { put("playlists", payload) }, onProgress)
        return json.decodeFromJsonElement(AmPushResult.serializer(), result)
    }

    // MARK: Job lifecycle (attach-or-submit, then poll)

    /** A still-plausible jobId from a previous attempt: re-attach within the hour, else a fresh sync. */
    internal fun storedJobId(op: String): String? {
        val j = jobs.load(op) ?: return null
        return j.jobId.takeIf { clockMs() - j.atMs < RESUME_WINDOW_MS }
    }

    /**
     * PROOF the job is dead server-side? Only then may the stored id be cleared. A Wi-Fi blip, a
     * gateway 502 or a stall MUST keep it: clearing and resubmitting while the worker chain is
     * alive runs TWO pushes concurrently against the same library (double-appends).
     */
    internal fun isTerminal(e: Throwable): Boolean = when (e) {
        is AmSyncException.JobGone, is AmSyncException.Worker -> true
        is AmSyncException.Http -> e.code in 400..499
        else -> false
    }

    private suspend fun runJob(op: String, body: JsonObject?, onProgress: ((AmJobProgress) -> Unit)?): JsonElement {
        // RESUME: attach to an unfinished job rather than re-submitting (no double work/pushes).
        storedJobId(op)?.let { existing ->
            try {
                val r = poll(existing, onProgress)
                jobs.clear(op)
                return r
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!isTerminal(e)) throw e // stall/transient: id survives
                jobs.clear(op) // dead for sure - fall through to a fresh submit
            }
        }
        val mut = tokens.musicUserToken() ?: throw AmSyncException.NotSignedIn()
        val payload = buildJsonObject {
            body?.forEach { (k, v) -> put(k, v) }
            put("musicUserToken", mut)
        }
        val jobId = submit(op, payload)
        jobs.store(op, AmJobStore.StoredJob(jobId, clockMs()))
        try {
            val r = poll(jobId, onProgress)
            jobs.clear(op)
            return r
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (isTerminal(e)) jobs.clear(op) // otherwise the id survives for re-attach
            throw e
        }
    }

    private suspend fun baseUrl(): String = baseProvider().trimEnd('/')

    private suspend fun submit(op: String, body: JsonObject): String = withContext(Dispatchers.IO) {
        val req = Request.Builder().url("${baseUrl()}/$op")
            .post(body.toString().toRequestBody("application/json".toMediaType())).build()
        http.newBuilder().callTimeout(30, java.util.concurrent.TimeUnit.SECONDS).build().newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (resp.code != 200 && resp.code != 202) throw AmSyncException.Http(resp.code, text)
            val id = runCatching { (json.parseToJsonElement(text) as JsonObject)["jobId"]?.let { (it as? JsonPrimitive)?.contentOrNull } }.getOrNull()
            id?.takeIf { it.isNotEmpty() } ?: throw IOException("sync submit response had no jobId")
        }
    }

    /** One poll round-trip. null = a missed poll (transient). Throws on 404 / hard 4xx. */
    private suspend fun pollOnce(jobUrl: String): JsonObject? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url(jobUrl).get().build()
            http.newBuilder().callTimeout(20, java.util.concurrent.TimeUnit.SECONDS).build().newCall(req).execute().use { resp ->
                val code = resp.code
                val text = resp.body?.string().orEmpty()
                if (code == 404) throw AmSyncException.JobGone()
                if (code != 200 && code in 400..499 && code != 429) throw AmSyncException.Http(code, text)
                if (code != 200) return@use null // 5xx / 429 - retry
                json.parseToJsonElement(text) as? JsonObject
            }
        } catch (e: AmSyncException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null // IOException / torn decode - treat as a missed poll
        }
    }

    /**
     * Poll GET /job/{jobId} until done. The deadline is STALL-based: it resets whenever the
     * published progress changes. TRANSIENT failures are ABSORBED (sleep + re-poll): the server
     * worker keeps running whether or not we watch, so one blipped poll never aborts a live sync.
     */
    private suspend fun poll(jobId: String, onProgress: ((AmJobProgress) -> Unit)?): JsonElement {
        val jobUrl = "${baseUrl()}/job/$jobId"
        var lastKey = ""
        var lastLabel = "starting"
        var stallDeadline = clockMs() + stallTimeoutMs
        while (true) {
            val env = pollOnce(jobUrl)
            val progress = (env?.get("progress") as? JsonObject)?.let {
                runCatching { json.decodeFromJsonElement(AmJobProgress.serializer(), it) }.getOrNull()
            }
            if (progress != null) {
                onProgress?.invoke(progress)
                lastLabel = progress.display
                val key = "${progress.label}|${progress.done ?: -1}|${progress.total ?: -1}"
                if (key != lastKey) {
                    lastKey = key
                    stallDeadline = clockMs() + stallTimeoutMs
                }
            }
            when ((env?.get("status") as? JsonPrimitive)?.contentOrNull) {
                "done" -> {
                    val result = env?.get("result")
                    if (result != null && result !is JsonNull) return result
                    throw AmSyncException.Worker("job finished without a result")
                }
                "error" -> throw AmSyncException.Worker((env["error"] as? JsonPrimitive)?.contentOrNull ?: "unknown worker error")
                else -> { // pending | running | missed poll
                    if (clockMs() >= stallDeadline) throw AmSyncException.Stalled(lastLabel)
                    sleep(pollIntervalMs)
                }
            }
        }
    }

    companion object {
        /** Jobs expire server-side after a day; we re-attach within the hour. */
        const val RESUME_WINDOW_MS = 3_600_000L
    }
}

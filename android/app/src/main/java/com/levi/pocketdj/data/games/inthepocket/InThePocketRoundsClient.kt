package com.levi.pocketdj.data.games.inthepocket

import com.levi.pocketdj.data.pockets.PocketsCredentials
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * `POST /pockets/rounds` — the rounds half of the listening-pockets upload (port of
 * `ListeningPocketsService.uploadRounds` + `ListeningPocketsClient.postRounds`).
 *
 * Rules (all load-bearing):
 *  - a round is ACKNOWLEDGED only on 2xx, by its fingerprint; a round whose fingerprint moved
 *    (feedback / rating edited) is re-sent;
 *  - ANY failure (a 404 from a backend without the route above all, 5xx, network) leaves the rest
 *    queued, silently; 404 additionally flips [roundsServiceAvailable];
 *  - at most [BATCH_CAP] rounds per POST;
 *  - rounds started before the "Delete cloud data" floor never upload again;
 *  - acknowledgements are DEVICE-LOCAL (`pocketdj-in-the-pocket-sync.json`, never CloudSync'd).
 */
class InThePocketRoundsClient(
    private val http: Call.Factory,
    private val baseUrl: () -> String,
    private val syncFile: File,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val deviceId: suspend () -> String? = { null },
) {
    private val mutex = Mutex()
    private val ackLock = Any()
    private var sentRounds: Map<String, String> = emptyMap()
    private var uploadFloorMs: Double? = null

    /** Bumped by [setUploadFloor] ("Delete cloud data"): an in-flight flush then records no acks. */
    private val epoch = java.util.concurrent.atomic.AtomicLong(0)
    @Volatile private var loaded = false

    private val _available = MutableStateFlow(true)

    /** False once the route answered 404. */
    val roundsServiceAvailable: StateFlow<Boolean> = _available.asStateFlow()

    /** Round id -> fingerprint the server acknowledged. */
    val acknowledged: Map<String, String> get() = synchronized(ackLock) { ensureLoaded(); sentRounds }

    /** "Delete cloud data": nothing started before [ms] uploads again. */
    fun setUploadFloor(ms: Double?) = synchronized(ackLock) {
        ensureLoaded(); uploadFloorMs = ms; epoch.incrementAndGet(); persist()
    }

    /**
     * Upload every wire whose fingerprint moved. Returns true when at least one batch was acknowledged.
     * Single-flight: concurrent calls queue behind each other (the second then finds nothing pending).
     */
    suspend fun flush(creds: PocketsCredentials, wires: List<InThePocketRoundWire>, installId: String): Boolean =
        mutex.withLock {
            val startEpoch = epoch.get()
            val deviceIdValue = deviceId()
            val now = clock().toDouble()
            val floor = maxOf(now - WINDOW_DAYS * 86_400_000.0, synchronized(ackLock) { ensureLoaded(); uploadFloorMs } ?: 0.0)
            val eligible = wires.filter { it.startedAtMs.toDouble() >= floor }
            val ids = eligible.mapTo(HashSet()) { it.id }
            synchronized(ackLock) {
                val pruned = sentRounds.filterKeys { it in ids }
                if (pruned.size != sentRounds.size) { sentRounds = pruned; persist() }
            }
            var pending = eligible.filter { synchronized(ackLock) { sentRounds[it.id] } != it.fingerprint }
            var sentAny = false
            while (pending.isNotEmpty()) {
                val slice = pending.take(BATCH_CAP)
                val batch = InThePocketRoundsBatch(deviceIdValue, installId, clock(), slice)
                when (post(batch, creds)) {
                    in 200..299 -> Unit
                    404 -> { _available.value = false; return@withLock sentAny }
                    else -> return@withLock sentAny
                }
                val stale = synchronized(ackLock) {
                    if (epoch.get() != startEpoch) true else {
                        sentRounds = sentRounds + slice.associate { it.id to it.fingerprint }
                        persist()
                        false
                    }
                }
                // The floor moved mid-flight (Delete cloud data): never ack rounds it excludes.
                if (stale) return@withLock sentAny
                pending = pending.drop(slice.size)
                sentAny = true
                _available.value = true
            }
            sentAny
        }

    /** HTTP status, or -1 on a transport failure. */
    internal suspend fun post(batch: InThePocketRoundsBatch, creds: PocketsCredentials): Int =
        withContext(Dispatchers.IO) {
            val body = batch.toJson().toString().toRequestBody("application/json".toMediaType())
            val b = Request.Builder().url(baseUrl().trimEnd('/') + "/pockets/rounds").post(body)
                .header("Authorization", "Bearer ${creds.key}")
                .header(PROFILE_HEADER, creds.profileId)
            if (creds.enrollSecret.isNotEmpty()) b.header(ENROLL_HEADER, creds.enrollSecret)
            batch.deviceId?.takeIf { it.isNotEmpty() }?.let { b.header(DEVICE_HEADER, it) }
            try {
                http.newCall(b.build()).execute().use { it.code }
            } catch (_: IOException) {
                -1
            } catch (_: IllegalArgumentException) {
                -1
            }
        }

    private fun ensureLoaded() {
        if (loaded) return
        loaded = true
        val obj = runCatching { Json.parseToJsonElement(syncFile.readText()).jsonObject }.getOrNull() ?: return
        sentRounds = (obj["sentRounds"] as? JsonObject)?.mapNotNull { (k, v) ->
            (v as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.let { k to it }
        }?.toMap() ?: emptyMap()
        uploadFloorMs = (obj["uploadFloorMs"] as? JsonPrimitive)?.doubleOrNull
    }

    private fun persist() {
        val doc = JsonObject(buildMap {
            put("sentRounds", JsonObject(sentRounds.mapValues { JsonPrimitive(it.value) }))
            uploadFloorMs?.let { put("uploadFloorMs", JsonPrimitive(it)) }
        })
        runCatching {
            val tmp = File(syncFile.parentFile, syncFile.name + ".tmp")
            tmp.writeText(doc.toString())
            if (!tmp.renameTo(syncFile)) { syncFile.writeText(doc.toString()); tmp.delete() }
        }
    }

    companion object {
        const val BATCH_CAP = 50
        const val WINDOW_DAYS = 90.0
        const val PROFILE_HEADER = "X-PocketDJ-Profile"
        const val ENROLL_HEADER = "X-PocketDJ-Enroll"
        const val DEVICE_HEADER = "X-PocketDJ-Device"
    }
}

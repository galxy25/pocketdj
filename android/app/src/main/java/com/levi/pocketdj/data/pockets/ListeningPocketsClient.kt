package com.levi.pocketdj.data.pockets

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Async client for the listening-pockets Lambda (`/pockets` routes on the rec-engine HTTP API). Port of
 * apple ListeningPocketsClient.swift. Auth is the rec engine's: `Authorization: Bearer <key>` plus the
 * rec-engine-SCOPED profile id in `X-PocketDJ-Profile`, and the enrollment secret on the two routes
 * that can create or destroy state (POST /pockets/events, DELETE /pockets/state).
 *
 * A 404 is its own case ([ClientError.NotFound]): until the routes are deployed the rec engine's
 * `$default` route answers every pockets path with not-found — "not available yet", silent.
 */
class ListeningPocketsClient(
    private val http: Call.Factory,
    private val baseUrl: () -> String,
    private val deviceId: () -> String? = { null },
) {
    sealed class ClientError(message: String) : Exception(message) {
        data class Http(val code: Int) : ClientError("HTTP $code")
        data object NotFound : ClientError("not found")
        data object KeyMismatch : ClientError("key mismatch")
        data object EnrollmentRequired : ClientError("enrollment required")
        data object ProfileCapReached : ClientError("profile cap reached")
        data object BadResponse : ClientError("bad response")
    }

    private fun request(
        path: String, method: String, creds: PocketsCredentials, body: String? = null, enroll: Boolean = false,
    ): Request {
        val b = Request.Builder().url(baseUrl().trimEnd('/') + "/" + path)
            .header("Authorization", "Bearer ${creds.key}")
        if (enroll && creds.enrollSecret.isNotEmpty()) b.header(ENROLL_HEADER, creds.enrollSecret)
        creds.profileId.trim().takeIf { it.isNotEmpty() }?.let { b.header(PROFILE_HEADER, it) }
        deviceId()?.takeIf { it.isNotEmpty() }?.let { b.header(DEVICE_HEADER, it) }
        val rb = body?.toRequestBody(JSON)
        when (method) {
            "GET" -> b.get()
            "DELETE" -> b.delete(rb ?: ByteArray(0).toRequestBody())
            else -> b.method(method, rb ?: ByteArray(0).toRequestBody())
        }
        return b.build()
    }

    /** Run a request → the 2xx body; 403 / 404 / other non-2xx map to distinct [ClientError]s. */
    private suspend fun runRaw(req: Request, timeoutSec: Long = DEFAULT_TIMEOUT_S): String {
        val (code, text) = exec(req, timeoutSec)
        if (code == 403) throw map403(text)
        if (code == 404) throw ClientError.NotFound
        if (code !in 200..299) throw ClientError.Http(code)
        return text
    }

    /** Cancellation-aware call with a per-call timeout (iOS: 20 s default, 30 s events, 12 s health). */
    private suspend fun exec(req: Request, timeoutSec: Long): Pair<Int, String> =
        suspendCancellableCoroutine { cont ->
            val call = http.newCall(req)
            call.timeout().timeout(timeoutSec, TimeUnit.SECONDS)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resumeWithException(e)
                }
                override fun onResponse(call: Call, response: Response) {
                    try {
                        val r = response.use { it.code to (it.body?.string().orEmpty()) }
                        if (cont.isActive) cont.resume(r)
                    } catch (e: IOException) {
                        if (cont.isActive) cont.resumeWithException(e)
                    }
                }
            })
        }

    /** `POST /pockets/events` (≤1000 events from this client). Carries the enrollment secret. */
    suspend fun postEvents(batch: ListeningPocketsUploadBatch, creds: PocketsCredentials): ListeningPocketsUploadResponse {
        val text = runRaw(request("pockets/events", "POST", creds, batch.toJson().toString(), enroll = true), EVENTS_TIMEOUT_S)
        return ListeningPocketsUploadResponse.parse(runCatching { Json.parseToJsonElement(text) }.getOrNull())
    }

    /** `GET /pockets/results` — decoded document AND raw text (the service caches the text). */
    suspend fun results(creds: PocketsCredentials): Pair<ListeningPocketsResults, String> {
        val text = runRaw(request("pockets/results", "GET", creds))
        val decoded = ListeningPocketsResults.parse(text) ?: throw ClientError.BadResponse
        return decoded to text
    }

    /** `DELETE /pockets/state` — "Delete cloud data"; the enrollment secret authorizes it. */
    suspend fun deleteState(creds: PocketsCredentials) {
        runRaw(request("pockets/state", "DELETE", creds, enroll = true))
    }

    /** `GET /pockets/health` — unauthenticated reachability probe. */
    suspend fun health(): Boolean {
        return try {
            val req = Request.Builder().url(baseUrl().trimEnd('/') + "/pockets/health").get().build()
            val (code, text) = exec(req, HEALTH_TIMEOUT_S)
            if (code !in 200..299) return false
            val o = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            (o?.get("ok") as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull == true
        } catch (_: IOException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    companion object {
        private const val DEFAULT_TIMEOUT_S = 20L
        private const val EVENTS_TIMEOUT_S = 30L
        private const val HEALTH_TIMEOUT_S = 12L
        const val PROFILE_HEADER = "X-PocketDJ-Profile"
        const val ENROLL_HEADER = "X-PocketDJ-Enroll"
        const val DEVICE_HEADER = "X-PocketDJ-Device"
        private val JSON = "application/json".toMediaType()

        internal fun map403(body: String): ClientError {
            val err = runCatching { ((Json.parseToJsonElement(body) as? JsonObject)?.get("error") as? JsonPrimitive)?.content }.getOrNull()
            return when (err) {
                "enrollment-required" -> ClientError.EnrollmentRequired
                "profile-cap-reached" -> ClientError.ProfileCapReached
                else -> ClientError.KeyMismatch
            }
        }
    }
}

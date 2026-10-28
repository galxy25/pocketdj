package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.config.EndpointKey
import com.levi.pocketdj.data.config.REC_ENGINE_ENROLL_SECRET
import com.levi.pocketdj.data.config.RemoteEndpoints
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Thin async client for the PocketDJ recommendation engine (iOS `RecEngineClient`). NOT gated
 * itself: the privacy gate lives in [RecommendationService], the only caller.
 *
 * Per call: `Authorization: Bearer <key>`, `X-PocketDJ-Profile: <scoped profile id>` (the caller
 * passes the HMAC-derived id, never the broadcast one), `X-PocketDJ-Device`. The enrollment secret
 * rides ONLY on `POST /events` and `DELETE /state`.
 *
 * A 403 is not one condition: the body names it (`enrollment-required` vs `key-mismatch`) and
 * the recoveries differ, so it maps to distinct [ClientError]s.
 */
class RecEngineClient(
    private val http: OkHttpClient,
    /** Base URL, read LIVE per request (remote endpoints); a blank/invalid base fails as BadResponse. */
    private val base: () -> String = { RemoteEndpoints.url(EndpointKey.REC_ENGINE_BASE) },
    private val enrollSecret: () -> String = { REC_ENGINE_ENROLL_SECRET },
    private val deviceId: () -> String,
    private val json: Json = PdjJson.lenient,
) {
    sealed class ClientError(message: String) : Exception(message) {
        data class Http(val code: Int) : ClientError("HTTP $code")
        data object KeyMismatch : ClientError("key-mismatch")

        /** The deployed enrollment secret rotated; only an app update carries the new one. */
        data object EnrollmentRequired : ClientError("enrollment-required")
        data object BadResponse : ClientError("bad-response")
    }

    private fun url(vararg segments: String, query: List<Pair<String, String>> = emptyList()): HttpUrl {
        val root = base().trim().trimEnd('/').toHttpUrlOrNull() ?: throw ClientError.BadResponse
        return root.newBuilder().apply {
            segments.forEach(::addPathSegments)
            query.forEach { (k, v) -> addQueryParameter(k, v) }
        }.build()
    }

    private fun request(
        path: String, method: String, key: String, profileId: String,
        query: List<Pair<String, String>> = emptyList(), body: String? = null, enroll: Boolean = false,
    ): Request {
        val b = Request.Builder().url(url(path, query = query))
            .header("Authorization", "Bearer $key")
            .header("X-PocketDJ-Device", deviceId())
        if (profileId.isNotBlank()) b.header("X-PocketDJ-Profile", profileId)
        val secret = enrollSecret()
        if (enroll && secret.isNotEmpty()) b.header(ENROLL_HEADER, secret)
        val rb = body?.toRequestBody(JSON_TYPE)
        b.method(method, rb ?: if (method == "DELETE" || method == "GET") null else ByteArray(0).toRequestBody(null))
        if (body != null) b.header("Content-Type", "application/json")
        return b.build()
    }

    private suspend fun run(req: Request, timeoutSec: Long): JsonElement {
        val client = http.newBuilder().callTimeout(timeoutSec, TimeUnit.SECONDS).build()
        val (code, text) = client.newCall(req).await()
        if (code == 403) throw map403(text)
        if (code !in 200..299) throw ClientError.Http(code)
        return runCatching { json.parseToJsonElement(text) }.getOrNull() ?: throw ClientError.BadResponse
    }

    /** `POST /events` — carries the enrollment secret (the first upload CREATES server state). */
    suspend fun postEvents(batch: RecUploadBatch, key: String, profileId: String): RecUploadResponse {
        val body = json.encodeToString(batch)
        return RecWire.uploadResponse(
            run(request("events", "POST", key, profileId, body = body, enroll = true), timeoutSec = 30),
        )
    }

    /** `GET /recs/songs?limit=N` — the For You list. */
    suspend fun forYou(limit: Int, key: String, profileId: String): RecSongsResponse =
        RecWire.songsResponse(
            run(request("recs/songs", "GET", key, profileId, query = listOf("limit" to limit.toString())), 20),
        )

    /** `GET /recs/similar` — Gem Collector's cloud booster; SHORT timeout (rides a timed round). */
    suspend fun similarToCollections(collectionIds: List<String>, limit: Int, key: String, profileId: String): RecSongsResponse =
        RecWire.songsResponse(
            run(
                request(
                    "recs/similar", "GET", key, profileId,
                    query = listOf("collectionIds" to collectionIds.joinToString(","), "limit" to limit.toString()),
                ),
                timeoutSec = 6,
            ),
        )

    /** `GET /recs/collections?songId=S` — collection suggestions for one song. */
    suspend fun collectionSuggestions(songId: String, key: String, profileId: String): RecCollectionsResponse =
        RecWire.collectionsResponse(
            run(request("recs/collections", "GET", key, profileId, query = listOf("songId" to songId)), 20),
        )

    /** `DELETE /state` — "Delete cloud data". Carries the enrollment secret so a wedged key can still erase. */
    suspend fun deleteState(key: String, profileId: String) {
        run(request("state", "DELETE", key, profileId, enroll = true), 20)
    }

    /** `GET /health` — unauthenticated reachability probe. */
    suspend fun health(): Boolean = try {
        val req = Request.Builder().url(url("health")).get().build()
        val el = run(req, 12)
        RecWire.uploadResponse(el).ok == true
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (_: Exception) {
        false
    }

    companion object {
        const val ENROLL_HEADER = "X-PocketDJ-Enroll"
        private val JSON_TYPE = "application/json".toMediaType()

        /** The body names WHICH refusal; anything unrecognized keeps the old key-mismatch mapping. */
        internal fun map403(body: String): ClientError {
            val kind = runCatching {
                (PdjJson.lenient.parseToJsonElement(body) as? kotlinx.serialization.json.JsonObject)
                    ?.get("error")?.let { it as? kotlinx.serialization.json.JsonPrimitive }?.takeIf { it.isString }?.content
            }.getOrNull()
            return if (kind == "enrollment-required") ClientError.EnrollmentRequired else ClientError.KeyMismatch
        }
    }
}

private suspend fun Call.await(): Pair<Int, String> = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { runCatching { cancel() } }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            response.use {
                val text = runCatching { it.body?.string().orEmpty() }.getOrElse { e ->
                    if (cont.isActive) cont.resumeWithException(e)
                    return
                }
                if (cont.isActive) cont.resume(it.code to text)
            }
        }
    })
}

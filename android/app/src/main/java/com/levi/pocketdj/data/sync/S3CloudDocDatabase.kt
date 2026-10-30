package com.levi.pocketdj.data.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import okio.GzipSink
import okio.buffer
import java.io.IOException

/**
 * [CloudDocDatabase] over the `pocketdj-profile-sync` Lambda (docs/design/profile-sync-s3.md).
 *
 * - No `profileSyncBase` => [accountAvailable] is false and NO request is ever made (sync disabled).
 * - Auth on every route: `X-PocketDJ-Profile` + `Authorization: Bearer <secret>`.
 * - PUT bodies are gzipped (`Content-Encoding: gzip`; API Gateway's 6 MB ceiling vs a ~4 MB doc).
 *   GET relies on OkHttp's transparent `Accept-Encoding: gzip` + inflate.
 * - A 401 flips [unauthorized] (=> [accountAvailable] false) until [clearUnauthorized] (relink).
 */
class S3CloudDocDatabase(
    private val baseUrl: () -> String?,
    private val profileId: () -> String,
    private val secrets: ProfileSecretStore,
    private val http: OkHttpClient,
    private val enrollment: Enrollment? = null,
    private val deviceName: () -> String = { "Android" },
) : CloudDocDatabase {

    // Persisted (per profile id) so "Profile not authorized - relink" survives a process restart.
    private val _unauthorized = MutableStateFlow(runCatching { secrets.unauthorizedFor(profileId()) }.getOrDefault(false))
    /** True after a 401 (or an enroll 409): Settings shows "Profile not authorized - relink". */
    val unauthorized: StateFlow<Boolean> = _unauthorized.asStateFlow()

    fun clearUnauthorized() {
        _unauthorized.value = false
        secrets.clearUnauthorized()
    }

    private fun markUnauthorized() {
        _unauthorized.value = true
        runCatching { secrets.markUnauthorized(profileId()) }
    }

    private fun base(): String? = baseUrl()?.trimEnd('/')?.takeIf { it.isNotEmpty() }

    override suspend fun accountAvailable(): Boolean {
        if (base() == null) return false
        if (_unauthorized.value) return false
        val id = profileId()
        if (enrollment != null) {
            when (enrollment.ensureEnrolled(id)) {
                Enrollment.Outcome.Enrolled, Enrollment.Outcome.AlreadyEnrolled -> Unit
                Enrollment.Outcome.RelinkRequired -> { markUnauthorized(); return false }
                else -> return false
            }
        }
        return secrets.hasSecret()
    }

    private fun req(path: String): Request.Builder =
        Request.Builder().url((base() ?: throw IOException("Sync isn't configured (no profileSyncBase)")) + path)
            .header("X-PocketDJ-Profile", profileId().lowercase())
            .header("Authorization", "Bearer " + secrets.secret())

    private suspend fun <T> call(request: Request, handle: (okhttp3.Response) -> T): T = withContext(Dispatchers.IO) {
        try {
            http.newCall(request).execute().use { r ->
                if (r.code == 401) {
                    // A 401 for an identity we've since replaced (link in flight) says nothing about the current one.
                    if (sentIdentityIsCurrent(request)) markUnauthorized()
                    throw IOException("Profile not authorized (401)")
                }
                handle(r)
            }
        } catch (e: CancellationException) {
            throw e
        }
    }

    private fun sentIdentityIsCurrent(request: Request): Boolean =
        request.header("X-PocketDJ-Profile") == profileId().lowercase() &&
            request.header("Authorization") == "Bearer " + secrets.secret()

    override suspend fun fetchMeta(keys: List<String>): Map<String, Double> {
        if (keys.isEmpty()) return emptyMap()
        keys.forEach(::checkKey)
        val r = req("/meta?keys=" + keys.joinToString(",")).get().build()
        return call(r) { resp ->
            if (!resp.isSuccessful) throw IOException("meta failed: HTTP ${resp.code}")
            val obj = Json.parseToJsonElement(resp.body!!.string()).jsonObject
            obj.entries.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.doubleOrNull?.let { k to it } }.toMap()
        }
    }

    override suspend fun fetch(key: String): CloudDoc? {
        checkKey(key)
        return call(req("/doc/$key").get().build()) { resp ->
            when {
                resp.code == 404 -> null
                !resp.isSuccessful -> throw IOException("fetch $key failed: HTTP ${resp.code}")
                else -> CloudDoc(
                    key = key,
                    payload = resp.body!!.bytes(),
                    modifiedAtMs = resp.header(MODIFIED_AT)?.trim()?.toDoubleOrNull() ?: 0.0,
                    deviceName = resp.header(DEVICE).orEmpty(),
                )
            }
        }
    }

    override suspend fun save(doc: CloudDoc) {
        checkKey(doc.key)
        val body = gzip(doc.payload)
        val r = req("/doc/${doc.key}")
            .header("Content-Encoding", "gzip")
            .header(MODIFIED_AT, formatMs(doc.modifiedAtMs))
            .header(DEVICE, headerSafe(doc.deviceName.ifEmpty { deviceName() }))
            .put(body).build()
        call(r) { resp -> if (!resp.isSuccessful) throw IOException("save ${doc.key} failed: HTTP ${resp.code}") }
    }

    override suspend fun delete(key: String) {
        checkKey(key)
        call(req("/doc/$key").delete().build()) { resp ->
            // Idempotent: a missing doc is success (the server always answers 200; tolerate 404 too).
            if (!resp.isSuccessful && resp.code != 404) throw IOException("delete $key failed: HTTP ${resp.code}")
        }
    }

    override suspend fun deleteAll(keys: List<String>) { keys.forEach { delete(it) } }

    /** Wipes the whole server-side profile prefix (account deletion). The id can be re-enrolled after. */
    suspend fun deleteProfile() {
        call(req("/profile").delete().build()) { resp ->
            if (!resp.isSuccessful) throw IOException("delete profile failed: HTTP ${resp.code}")
        }
    }

    /**
     * Retry of an interrupted account deletion with the OLD identity (the tombstone's id + secret),
     * independent of the current profile. @return true when the erasure is final: server success, or
     * 401/404 (the credential/profile no longer exists server-side, retrying can never help).
     * Network errors and 5xx throw so the tombstone survives.
     */
    suspend fun deleteProfileAs(profileId: String, secret: String): Boolean {
        val b = base() ?: throw IOException("no profile-sync endpoint")
        val request = Request.Builder().url("$b/profile")
            .header("X-PocketDJ-Profile", profileId.lowercase())
            .header("Authorization", "Bearer $secret")
            .delete().build()
        return withContext(Dispatchers.IO) {
            http.newCall(request).execute().use { r ->
                when {
                    r.isSuccessful || r.code == 404 || r.code == 401 -> true
                    else -> throw IOException("delete profile failed: HTTP ${r.code}")
                }
            }
        }
    }

    private fun checkKey(key: String) = require(KEY_RE.matches(key)) { "bad doc key '$key'" }

    companion object {
        const val MODIFIED_AT = "X-PocketDJ-Modified-At"
        const val DEVICE = "X-PocketDJ-Device"
        private val KEY_RE = Regex("^[a-z0-9-]{1,40}$")

        /** Integral ms render without exponent/decimals (the server also accepts fractions). */
        internal fun formatMs(ms: Double): String =
            if (ms.isFinite() && ms >= 0 && ms == Math.floor(ms) && ms < 1e15) ms.toLong().toString()
            else java.math.BigDecimal(ms.coerceAtLeast(0.0)).setScale(0, java.math.RoundingMode.HALF_UP).toPlainString()

        /** OkHttp rejects non-ASCII header values; the server also strips them and caps at 100. */
        internal fun headerSafe(s: String): String =
            s.filter { it.code in 0x20..0x7e }.take(100)

        internal fun gzip(bytes: ByteArray): RequestBody {
            val buf = Buffer()
            GzipSink(buf).buffer().use { it.write(bytes) }
            return buf.readByteArray().toRequestBody("application/json".toMediaType())
        }
    }
}

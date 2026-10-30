package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.credentials.SecretStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * One-time profile enrollment with the `pocketdj-profile-sync` Lambda: `POST /enroll
 * {profileId, secretHash}` with the capability header `X-PocketDJ-Enroll`. Runs ONCE per profile id
 * ([ProfileSecretStore.enrolledProfileId] short-circuits every later call with no network).
 *
 * - 200 -> enrolled (idempotent same-hash replies count).
 * - 5xx / IO error -> retried with backoff up to [maxAttempts], then [Outcome.Failed] (NOT remembered;
 *   the next pass retries).
 * - 401/403 (bad/missing capability token) and 429 (cap) -> [Outcome.Refused], sticky for this process
 *   so the 20 s tick does not hammer the endpoint.
 * - 409 -> the server holds a DIFFERENT secret for this id: [Outcome.RelinkRequired], remembered.
 */
class Enrollment(
    private val secrets: ProfileSecretStore,
    private val baseUrl: () -> String?,
    private val enrollToken: () -> String,
    private val http: OkHttpClient,
    private val maxAttempts: Int = 3,
    private val backoff: suspend (attempt: Int) -> Unit = { delay(500L shl it) },
) {
    sealed interface Outcome {
        data object Enrolled : Outcome
        data object AlreadyEnrolled : Outcome
        /** No profileSyncBase in the endpoint doc: sync is disabled. */
        data object Disabled : Outcome
        /** No enroll capability token provisioned on this build/device. */
        data object NotConfigured : Outcome
        data class Refused(val code: Int) : Outcome
        data object RelinkRequired : Outcome
        data class Failed(val message: String) : Outcome
    }

    private val mutex = Mutex()
    @Volatile private var refused: Outcome.Refused? = null

    suspend fun ensureEnrolled(profileId: String): Outcome = mutex.withLock {
        val id = profileId.lowercase()
        val base = baseUrl()?.trimEnd('/')?.takeIf { it.isNotEmpty() } ?: return Outcome.Disabled
        if (secrets.enrolledProfileId() == id) return Outcome.AlreadyEnrolled
        if (secrets.relinkRequiredFor(id)) return Outcome.RelinkRequired
        refused?.let { return it }
        val token = enrollToken()
        if (token.isEmpty()) return Outcome.NotConfigured

        val secret = secrets.secretOrMint()
        val body = buildJsonObject {
            put("profileId", id)
            put("secretHash", ProfileSecretStore.sha256Hex(secret))
        }.toString().toRequestBody("application/json".toMediaType())
        var last = "no attempt"
        for (attempt in 0 until maxAttempts) {
            if (attempt > 0) backoff(attempt - 1)
            val code = try {
                withContext(Dispatchers.IO) {
                    http.newCall(
                        Request.Builder().url("$base/enroll").header(ENROLL_HEADER, token).post(body).build(),
                    ).execute().use { it.code }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                last = e.javaClass.simpleName
                continue
            }
            when {
                code in 200..299 -> { secrets.markEnrolled(id); return Outcome.Enrolled }
                code == 409 -> { secrets.markRelinkRequired(id); return Outcome.RelinkRequired }
                code == 401 || code == 403 || code == 429 -> return Outcome.Refused(code).also { refused = it }
                code >= 500 -> last = "HTTP $code"
                else -> return Outcome.Failed("HTTP $code")
            }
        }
        Outcome.Failed(last)
    }

    /** Test/relink seam: forget the sticky refusal. */
    fun resetRefusal() { refused = null }

    companion object {
        const val ENROLL_HEADER = "X-PocketDJ-Enroll"

        /**
         * Token provider: the endpoints-doc capability ([fromDoc], ANS-SYNC-1) wins; the [SecretStore] value is only a
         * manual/debug provisioning fallback. Never hard-coded.
         */
        fun tokenFrom(store: SecretStore, fromDoc: () -> String = { "" }): () -> String = {
            fromDoc().ifEmpty { store.get(ProfileSecretStore.ENROLL_TOKEN) }
        }
    }
}

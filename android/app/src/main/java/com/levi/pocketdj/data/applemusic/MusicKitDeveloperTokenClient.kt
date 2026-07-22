package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.settings.AppSettingsStore
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Fetches + caches the Apple Music **developer token** (ES256 JWT) from the
 * user-configured rip server's `GET /musickit-token` endpoint
 * (specs/applemusic.md §4, §5). Modelled on [RipServerClient]: same
 * baseUrl/token/installId [RipServerClient.Config], the same header rules
 * (bearer omitted when the rip token is empty; `X-PocketDJ-Device` always sent),
 * and the same 12-second short-timeout doctrine.
 *
 * The SDK's `TokenProvider.getDeveloperToken()` is called SYNCHRONOUSLY per
 * playback, so [cachedTokenOrNull] must return a PRE-FETCHED value — callers
 * [prewarm] on sign-in and at launch; the SDK callback never blocks on the
 * network (specs/applemusic.md §5, risk 4).
 */
class MusicKitDeveloperTokenClient(
    http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
    private val configProvider: suspend () -> RipServerClient.Config,
    /** Optional cold-start cache: seed from / persist to Settings across launches. */
    private val settings: AppSettingsStore? = null,
) {
    @Serializable
    data class TokenResponse(
        val token: String,
        /** Epoch-ms expiry (the server returns `exp * 1000`). */
        val expiresAt: Long? = null,
        val ttlSec: Long? = null,
    )

    private data class Cached(val token: String, val expiresAtMs: Long)

    @Volatile
    private var cached: Cached? = null

    private val shortClient: OkHttpClient =
        http.newBuilder().callTimeout(12, TimeUnit.SECONDS).build()

    /** Non-blocking, synchronous read for the SDK `TokenProvider` — the last
     *  pre-fetched token, or null when none is warm yet / it fully expired. */
    fun cachedTokenOrNull(): String? =
        cached?.takeIf { it.token.isNotBlank() && it.expiresAtMs > System.currentTimeMillis() }?.token

    /**
     * A valid developer token: returns the cached one while it has > 24 h left,
     * otherwise fetches from the rip server, caches in memory, and (when wired)
     * persists to Settings for the next cold start. Throws
     * [RipServerClient.RipServerException] when no server is configured or the
     * fetch fails — the caller degrades to preview / no-AM.
     */
    suspend fun developerToken(): String {
        seedFromSettings()
        cached?.let { if (it.expiresAtMs - System.currentTimeMillis() > REFRESH_LEAD_MS) return it.token }

        val config = configProvider()
        if (!config.configured) {
            throw RipServerClient.RipServerException(null, "No import server configured (Settings) — it mints the Apple Music token")
        }
        val response = execute(config)
        val expiresAtMs = response.expiresAt
            ?: (System.currentTimeMillis() + (response.ttlSec ?: DEFAULT_TTL_SEC) * 1000)
        cached = Cached(response.token, expiresAtMs)
        settings?.setAppleMusicDeveloperToken(response.token, expiresAtMs)
        return response.token
    }

    /**
     * Best-effort pre-fetch for launch / sign-in. Never throws — a warm cache is
     * an optimization, and its absence simply defers the fetch to first AM play.
     */
    suspend fun prewarm() {
        runCatching { developerToken() }
    }

    private suspend fun seedFromSettings() {
        if (cached != null) return
        val s = settings?.current() ?: return
        if (s.appleMusicDeveloperToken.isNotBlank() && s.appleMusicDeveloperTokenExpiresAt > 0L) {
            cached = Cached(s.appleMusicDeveloperToken, s.appleMusicDeveloperTokenExpiresAt)
        }
    }

    private suspend fun execute(config: RipServerClient.Config): TokenResponse =
        withContext(Dispatchers.IO) {
            val request = builder(config, url(config)).get().build()
            shortClient.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    throw RipServerClient.RipServerException(
                        response.code,
                        if (response.code == 401 || response.code == 403) {
                            "Unauthorized — check the import-server token in Settings"
                        } else {
                            "Could not mint an Apple Music token (${response.code})"
                        },
                    )
                }
                runCatching { json.decodeFromString<TokenResponse>(text) }.getOrElse {
                    throw RipServerClient.RipServerException(response.code, "Undecodable token response")
                }
            }
        }

    private fun url(config: RipServerClient.Config): HttpUrl {
        val base = config.normalizedBase.toHttpUrlOrNull()
            ?: throw RipServerClient.RipServerException(null, "Import server URL is invalid — check Settings.")
        return base.newBuilder().addPathSegment("musickit-token").build()
    }

    private fun builder(config: RipServerClient.Config, url: HttpUrl): Request.Builder {
        val b = Request.Builder().url(url).header("X-PocketDJ-Device", config.installId)
        if (config.token.isNotEmpty()) b.header("Authorization", "Bearer ${config.token}")
        return b
    }

    private companion object {
        /** Refetch when the cached token has less than 24 h of life left. */
        const val REFRESH_LEAD_MS = 24L * 3600 * 1000
        const val DEFAULT_TTL_SEC = 150L * 24 * 3600
    }
}

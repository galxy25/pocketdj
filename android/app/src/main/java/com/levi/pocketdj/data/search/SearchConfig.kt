package com.levi.pocketdj.data.search

import com.levi.pocketdj.data.config.EndpointKey
import com.levi.pocketdj.data.config.RemoteEndpoints
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.CacheControl
import okhttp3.OkHttpClient
import okhttp3.Request

/** The resolved endpoint values a search needs. */
data class ResolvedSearchConfig(
    val host: String = DEFAULT_HOST,
    val region: String = "us-west-2",
    val index: String = "pocketdj",
) {
    companion object {
        const val DEFAULT_HOST = "mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws"
    }
}

/**
 * Holder for the online-search endpoint config (iOS `SearchConfig` actor). Resolution:
 * per-user host override -> `search-config.json` (fetched bypassing every HTTP cache; deploys
 * before 2026-10 served it `max-age=31536000,immutable`) -> baked default. Memoised; reloaded
 * when the remote-endpoint generation (the active searchConfigURL + env) changes.
 *
 * [fetch] is the test seam: returns the JSON body for a URL or null on any failure.
 */
class SearchConfig(
    private val fetch: suspend (url: String) -> String?,
    private val generation: () -> String = ::remoteGeneration,
    private val configUrl: () -> String = { RemoteEndpoints.url(EndpointKey.SEARCH_CONFIG_URL) },
) {
    private val lock = Any()
    private var userHost: String? = null
    private var loaded: ResolvedSearchConfig? = null
    private var loadedGeneration: String? = null

    suspend fun resolved(): ResolvedSearchConfig {
        val gen = generation()
        val cached = synchronized(lock) { loaded?.takeIf { loadedGeneration == gen } }
        val base = cached ?: load().also {
            synchronized(lock) { loaded = it; loadedGeneration = gen }
        }
        val u = synchronized(lock) { userHost }
        return if (u != null) base.copy(host = u) else base
    }

    /** Set (or clear with blank) the per-user override; stores the bare host. */
    fun setUserHost(raw: String?) {
        synchronized(lock) { userHost = normalizeHost(raw) }
    }

    private suspend fun load(): ResolvedSearchConfig {
        val text = runCatching { fetch(configUrl()) }.getOrNull() ?: return ResolvedSearchConfig()
        return parse(text)
    }

    companion object {
        fun remoteGeneration(): String =
            RemoteEndpoints.current.env + "|" + RemoteEndpoints.url(EndpointKey.SEARCH_CONFIG_URL)

        /** Accepts a bare host or full URL; strips scheme and any path. Blank -> null. */
        fun normalizeHost(raw: String?): String? {
            var s = raw?.trim().orEmpty()
            if (s.isEmpty()) return null
            val i = s.indexOf("://")
            if (i >= 0) s = s.substring(i + 3)
            val slash = s.indexOf('/')
            if (slash >= 0) s = s.substring(0, slash)
            return s.ifEmpty { null }
        }

        private val parser = Json { ignoreUnknownKeys = true }

        /** Only non-empty fields overlay the defaults; garbage keeps the defaults. */
        fun parse(text: String): ResolvedSearchConfig {
            val obj = runCatching { parser.parseToJsonElement(text) as? JsonObject }.getOrNull()
                ?: return ResolvedSearchConfig()
            fun f(k: String) = (obj[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.takeIf { it.isNotEmpty() }
            val d = ResolvedSearchConfig()
            return ResolvedSearchConfig(f("host") ?: d.host, f("region") ?: d.region, f("index") ?: d.index)
        }

        /** Production fetcher: NO cache, 15 s budget, 2xx only. */
        fun httpFetcher(http: OkHttpClient): suspend (String) -> String? = { url ->
            withContext(Dispatchers.IO) {
                runCatching {
                    val client = http.newBuilder().callTimeout(15, java.util.concurrent.TimeUnit.SECONDS).build()
                    val req = Request.Builder().url(url).cacheControl(CacheControl.FORCE_NETWORK).build()
                    client.newCall(req).execute().use { r -> if (r.isSuccessful) r.body?.string() else null }
                }.getOrNull()
            }
        }
    }
}

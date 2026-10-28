package com.levi.pocketdj.data.config

import java.io.File
import java.net.URI
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.CacheControl
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * REMOTE ENDPOINT CONFIG (docs/design/remote-endpoints.md) — the Android twin of the Swift
 * `EndpointResolver` and the PWA `src/config/endpointSchema.ts` (the canonical rules).
 *
 * Schema v1: `{"v":1,"env":"blue","endpoints":{"catalogBase":"https://…",…},"aliases":{…}}`.
 * Resolution order: last-good fetched doc (persisted) → compiled-in defaults (green). A fetched
 * doc is accepted only if `v == 1`, `env` is non-empty, every required key is present and every
 * URL is https on an allowlisted host; otherwise it is ignored.
 */
enum class EndpointKey(val wire: String) {
    CATALOG_BASE("catalogBase"),
    CATALOG_BASE_DEV("catalogBaseDev"),
    RIPS_BASE("ripsBase"),
    AM_PLAYLIST_SYNC_BASE("amPlaylistSyncBase"),
    REC_ENGINE_BASE("recEngineBase"),
    LISTENING_POCKETS_BASE("listeningPocketsBase"),
    DIAG_LOGS_BASE("diagLogsBase"),
    SEARCH_CONFIG_URL("searchConfigURL");

    companion object {
        val REQUIRED = listOf(CATALOG_BASE, RIPS_BASE, AM_PLAYLIST_SYNC_BASE, REC_ENGINE_BASE, DIAG_LOGS_BASE)
    }
}

/** A validated v1 document. Optional keys derive from the SAME doc (never from blue). */
data class EndpointConfig(
    val env: String,
    val endpoints: Map<EndpointKey, String>,
    val catalogAliases: Set<String> = emptySet(),
    val catalogDevAliases: Set<String> = emptySet(),
) {
    fun url(key: EndpointKey): String = endpoints[key] ?: when (key) {
        EndpointKey.CATALOG_BASE_DEV -> url(EndpointKey.CATALOG_BASE)
        EndpointKey.LISTENING_POCKETS_BASE -> url(EndpointKey.REC_ENGINE_BASE)
        EndpointKey.SEARCH_CONFIG_URL -> url(EndpointKey.CATALOG_BASE) + "/search-config.json"
        else -> COMPILED_IN.endpoints.getValue(key) // unreachable: required keys
    }

    companion object {
        const val SCHEMA_VERSION = 1

        /** Today's values (green, 623170744161). Must equal config/endpoints.green.json. */
        val COMPILED_IN = EndpointConfig(
            env = "green",
            endpoints = mapOf(
                EndpointKey.CATALOG_BASE to "https://d1j6qufkowz1xq.cloudfront.net",
                EndpointKey.CATALOG_BASE_DEV to "https://d1zb3ydtksjw1r.cloudfront.net",
                EndpointKey.RIPS_BASE to "https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com",
                EndpointKey.AM_PLAYLIST_SYNC_BASE to "https://webhj3e832.execute-api.us-west-2.amazonaws.com",
                EndpointKey.REC_ENGINE_BASE to "https://kwgk9osywa.execute-api.us-west-2.amazonaws.com",
                EndpointKey.LISTENING_POCKETS_BASE to "https://kwgk9osywa.execute-api.us-west-2.amazonaws.com",
                EndpointKey.DIAG_LOGS_BASE to "https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com",
                EndpointKey.SEARCH_CONFIG_URL to "https://d1j6qufkowz1xq.cloudfront.net/search-config.json",
            ),
        )

        /** Retired blue catalog hosts: persisted Settings sources saved against them still rebase. */
        val LEGACY_BLUE_CATALOG_HOST = "d2p4cubg6se03u.cloudfront.net"
        val LEGACY_BLUE_CATALOG_DEV_HOST = "djictbz9w796r.cloudfront.net"

        private val POCKET_DJ = Regex("^[a-z0-9-]+(\\.[a-z0-9-]+)*\\.pocket-dj\\.com$")
        private val CLOUDFRONT = Regex("^[a-z0-9]+\\.cloudfront\\.net$")
        private val EXECUTE_API = Regex("^[a-z0-9]+\\.execute-api\\.us-west-2\\.amazonaws\\.com$")
        private val S3_BUCKET = Regex("^pocketdj-[a-z0-9-]+\\.s3\\.us-west-2\\.amazonaws\\.com$")

        fun isAllowedHost(raw: String): Boolean {
            val h = raw.lowercase()
            return h == "pocket-dj.com" || POCKET_DJ.matches(h) || CLOUDFRONT.matches(h) ||
                EXECUTE_API.matches(h) || S3_BUCKET.matches(h)
        }

        /** https + allowlisted host; no userinfo/port/query/fragment; trailing slash trimmed. */
        fun normalize(raw: JsonElement?): String? {
            val s = (raw as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
            if (s.isEmpty()) return null
            val u = runCatching { URI(s) }.getOrNull() ?: return null
            if (!u.scheme.equals("https", ignoreCase = true)) return null
            val host = u.host ?: return null
            if (!isAllowedHost(host)) return null
            if (u.rawUserInfo != null || u.port != -1 || u.rawQuery != null || u.rawFragment != null) return null
            return s.trimEnd('/')
        }

        sealed interface Decoded {
            data class Ok(val config: EndpointConfig) : Decoded
            data class Rejected(val reason: String) : Decoded
        }

        private val parser = Json { ignoreUnknownKeys = true }

        fun decode(text: String): Decoded {
            val doc = runCatching { parser.parseToJsonElement(text) }.getOrNull() as? JsonObject
                ?: return Decoded.Rejected("not json")
            val v = doc["v"] as? JsonPrimitive
            if (v == null || v.isString || v.booleanOrNull != null || v.intOrNull != SCHEMA_VERSION) {
                return Decoded.Rejected("unsupported v")
            }
            val env = (doc["env"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.trim()
            if (env.isNullOrEmpty()) return Decoded.Rejected("missing env")
            val eps = doc["endpoints"] as? JsonObject ?: return Decoded.Rejected("missing endpoints")
            val out = mutableMapOf<EndpointKey, String>()
            for (key in EndpointKey.entries) {
                val raw = eps[key.wire]
                if (raw == null) {
                    if (key in EndpointKey.REQUIRED) return Decoded.Rejected("missing ${key.wire}")
                    continue
                }
                out[key] = normalize(raw) ?: return Decoded.Rejected("rejected ${key.wire}")
            }
            val aliases = doc["aliases"] as? JsonObject
            fun hosts(k: String): Set<String> = ((aliases?.get(k) as? JsonArray) ?: JsonArray(emptyList()))
                .mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.lowercase() }
                .filter(::isAllowedHost).toSet()
            return Decoded.Ok(EndpointConfig(env, out, hosts("catalogBase"), hosts("catalogBaseDev")))
        }
    }
}

enum class EndpointSource(val label: String) { COMPILED_IN("compiled-in"), CACHED("cached"), REMOTE("remote") }

/**
 * Process-wide resolver. Every [Endpoints] accessor reads [current] at REQUEST time, so a new
 * config applies to the next request; in-flight work keeps the URL it started with. Defaults to
 * compiled-in (pure JVM tests need no setup); [install] loads the persisted last-good doc.
 */
object RemoteEndpoints {
    const val REMOTE_URL = "https://app.pocket-dj.com/config/endpoints.json"
    const val MIN_REFRESH_INTERVAL_MS = 15 * 60 * 1000L

    @Volatile var current: EndpointConfig = EndpointConfig.COMPILED_IN
        private set
    @Volatile var source: EndpointSource = EndpointSource.COMPILED_IN
        private set
    @Volatile var lastOutcome: String = "not fetched"
        private set
    @Volatile private var lastFetchAtMs: Long? = null
    @Volatile private var cacheFile: File? = null
    private val seenCatalogHosts = mutableSetOf<String>()
    private val seenCatalogDevHosts = mutableSetOf<String>()
    private val lock = Any()

    val summary: String get() = "env=${current.env} source=${source.label} fetch=$lastOutcome"

    fun url(key: EndpointKey): String = current.url(key)

    /** Logs bucket name (host label before `.s3.`), e.g. `pocketdj-logs-623170744161`. */
    val diagBucket: String
        get() = runCatching { URI(url(EndpointKey.DIAG_LOGS_BASE)).host.substringBefore(".s3.") }
            .getOrDefault("pocketdj-logs-623170744161")

    /** Load the persisted last-good doc (if any, and still valid) from [file]. */
    fun install(file: File) = synchronized(lock) {
        cacheFile = file
        val text = runCatching { file.readText() }.getOrNull() ?: return@synchronized
        val cache = runCatching { parser.parseToJsonElement(text).jsonObject }.getOrNull() ?: return@synchronized
        val docText = (cache["doc"] as? JsonPrimitive)?.contentOrNull ?: return@synchronized
        val decoded = EndpointConfig.decode(docText) as? EndpointConfig.Companion.Decoded.Ok ?: return@synchronized
        current = decoded.config
        source = EndpointSource.CACHED
        seenCatalogHosts += hostList(cache["seenCatalogHosts"])
        seenCatalogDevHosts += hostList(cache["seenCatalogDevHosts"])
    }

    /** Validate + apply [text]; persists it on success. Returns whether the active config changed. */
    fun apply(text: String): Boolean = synchronized(lock) {
        when (val d = EndpointConfig.decode(text)) {
            is EndpointConfig.Companion.Decoded.Rejected -> {
                lastOutcome = "rejected (${d.reason})"
                false
            }
            is EndpointConfig.Companion.Decoded.Ok -> {
                val changed = d.config != current
                current = d.config
                source = EndpointSource.REMOTE
                lastOutcome = "accepted"
                listOf(d.config.url(EndpointKey.CATALOG_BASE), EndpointConfig.COMPILED_IN.url(EndpointKey.CATALOG_BASE))
                    .mapNotNull(::hostOf).forEach { seenCatalogHosts += it }
                listOf(d.config.url(EndpointKey.CATALOG_BASE_DEV), EndpointConfig.COMPILED_IN.url(EndpointKey.CATALOG_BASE_DEV))
                    .mapNotNull(::hostOf).forEach { seenCatalogDevHosts += it }
                persist(text)
                changed
            }
        }
    }

    /**
     * Fetch [REMOTE_URL] and apply it. Blocking (call from IO). Throttled unless [force]; never
     * throws. Returns whether the active config changed.
     */
    fun refresh(http: OkHttpClient, force: Boolean = false, nowMs: Long = System.currentTimeMillis(),
                url: String = REMOTE_URL): Boolean {
        synchronized(lock) {
            val last = lastFetchAtMs
            if (!force && last != null && nowMs - last < MIN_REFRESH_INTERVAL_MS) return false
            lastFetchAtMs = nowMs
        }
        return try {
            val req = Request.Builder().url(url).cacheControl(CacheControl.FORCE_NETWORK).build()
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    lastOutcome = "http ${resp.code}"
                    false
                } else {
                    // SPA fallback answers a missing file with index.html (200) — decode rejects it.
                    apply(resp.body?.string().orEmpty())
                }
            }
        } catch (e: Exception) {
            lastOutcome = "network error"
            false
        }
    }

    /**
     * Rebase a persisted built-in catalog URL (Settings sources store the host) onto the live
     * catalog base of the same tier. Unknown hosts (custom sources) pass through untouched.
     */
    fun rebaseCatalogUrl(raw: String): String {
        val host = hostOf(raw) ?: return raw
        val cfg = current
        val prod = synchronized(lock) {
            setOfNotNull(hostOf(EndpointConfig.COMPILED_IN.url(EndpointKey.CATALOG_BASE)), EndpointConfig.LEGACY_BLUE_CATALOG_HOST) + cfg.catalogAliases + seenCatalogHosts
        }
        val dev = synchronized(lock) {
            setOfNotNull(hostOf(EndpointConfig.COMPILED_IN.url(EndpointKey.CATALOG_BASE_DEV)), EndpointConfig.LEGACY_BLUE_CATALOG_DEV_HOST) + cfg.catalogDevAliases + seenCatalogDevHosts
        }
        val target = when (host) {
            in prod -> cfg.url(EndpointKey.CATALOG_BASE)
            in dev -> cfg.url(EndpointKey.CATALOG_BASE_DEV)
            else -> return raw
        }
        if (hostOf(target) == host) return raw
        val u = runCatching { URI(raw) }.getOrNull() ?: return raw
        val tail = (u.rawPath ?: "") + (u.rawQuery?.let { "?$it" } ?: "") + (u.rawFragment?.let { "#$it" } ?: "")
        return target.trimEnd('/') + tail
    }

    /** Test seam: back to a fresh compiled-in, uninstalled state. */
    fun resetForTests() = synchronized(lock) {
        current = EndpointConfig.COMPILED_IN
        source = EndpointSource.COMPILED_IN
        lastOutcome = "not fetched"
        lastFetchAtMs = null
        cacheFile = null
        seenCatalogHosts.clear()
        seenCatalogDevHosts.clear()
    }

    /** Test seam: activate [config] directly (no persistence). */
    fun setForTests(config: EndpointConfig) = synchronized(lock) {
        current = config
        source = EndpointSource.REMOTE
    }

    private val parser = Json { ignoreUnknownKeys = true }

    private fun hostOf(url: String): String? = runCatching { URI(url).host?.lowercase() }.getOrNull()

    private fun hostList(e: JsonElement?): List<String> =
        (e as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.lowercase() } ?: emptyList()

    private fun persist(docText: String) {
        val file = cacheFile ?: return
        val body = buildJsonObject {
            put("doc", docText)
            put("seenCatalogHosts", buildJsonArray { seenCatalogHosts.sorted().forEach { add(JsonPrimitive(it)) } })
            put("seenCatalogDevHosts", buildJsonArray { seenCatalogDevHosts.sorted().forEach { add(JsonPrimitive(it)) } })
        }
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".part")
            tmp.writeText(body.toString())
            if (!tmp.renameTo(file)) { file.writeText(body.toString()); tmp.delete() }
        }
    }
}

package com.levi.pocketdj.data.catalog

import com.levi.pocketdj.data.PdjJson
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromStream
import okhttp3.CacheControl
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Per-source-URL offline-first catalog loader — the Android mirror of iOS
 * `CatalogService` (specs/catalog.md §6–§7).
 *
 * - Explicit file cache (NOT the HTTP cache — URLCache-style caches refuse
 *   tens-of-MB bodies): one `<sha256(url)>.json` of raw response bytes plus a
 *   sibling `<sha256>.meta.json` holding the `ETag`/`Last-Modified` validators.
 * - Conditional GET: 304 serves the cached bytes; 2xx decodes then persists —
 *   bytes are cached ONLY after a successful full decode, atomically.
 * - Any network/decode failure serves the last-good cache; throws only when no
 *   cache exists.
 * - Decode strategy for the ~33 MB index: buffer the network body to a temp file
 *   (never a String copy), then stream-decode from disk off the main thread.
 */
class CatalogService(
    private val cacheDir: File,
    private val http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
) {
    @Serializable
    data class Validators(
        val lastModified: String? = null,
        val etag: String? = null,
    )

    /** Decoded catalog + whether it came from the network or the disk cache. */
    data class Loaded(val index: IndexJson, val fromCache: Boolean)

    init {
        cacheDir.mkdirs()
    }

    fun cacheFile(url: String): File = File(cacheDir, sha256Hex(url) + ".json")

    private fun metaFile(url: String): File = File(cacheDir, sha256Hex(url) + ".meta.json")

    /** Decode the cached document for [url], or null (absent/corrupt). Blocking IO. */
    fun cachedIndexOrNull(url: String): IndexJson? {
        val file = cacheFile(url)
        if (!file.isFile) return null
        return runCatching { decodeFile(file) }.getOrNull()
    }

    /**
     * Load one source URL per the iOS algorithm (catalog.md §6): conditional GET
     * → 304 serves cache → 2xx decode-then-cache → failure serves last-good.
     */
    suspend fun load(url: String): Loaded = withContext(Dispatchers.IO) {
        val validators = readValidators(url)
        val request = Request.Builder()
            .url(url)
            .cacheControl(CacheControl.FORCE_NETWORK)
            .apply {
                validators?.etag?.let { header("If-None-Match", it) }
                validators?.lastModified?.let { header("If-Modified-Since", it) }
            }
            .build()

        try {
            http.newCall(request).execute().use { response ->
                when {
                    response.code == 304 -> {
                        val cached = cachedIndexOrNull(url)
                            ?: throw IOException("304 with no usable cache for $url")
                        Loaded(cached, fromCache = true)
                    }

                    response.isSuccessful -> {
                        val body = response.body ?: throw IOException("Empty body for $url")
                        val temp = File.createTempFile("catalog-", ".part", cacheDir)
                        try {
                            temp.outputStream().buffered().use { out ->
                                body.byteStream().copyTo(out)
                            }
                            val decoded = decodeFile(temp)
                            // Persist only after a successful decode; best-effort —
                            // a cache-write failure never fails the load.
                            runCatching {
                                Files.move(
                                    temp.toPath(),
                                    cacheFile(url).toPath(),
                                    StandardCopyOption.REPLACE_EXISTING,
                                    StandardCopyOption.ATOMIC_MOVE,
                                )
                                writeValidators(
                                    url,
                                    Validators(
                                        lastModified = response.header("Last-Modified"),
                                        etag = response.header("ETag"),
                                    ),
                                )
                            }
                            Loaded(decoded, fromCache = false)
                        } finally {
                            temp.delete()
                        }
                    }

                    else -> {
                        val cached = cachedIndexOrNull(url)
                            ?: throw IOException("HTTP ${response.code} for $url and no cache")
                        Loaded(cached, fromCache = true)
                    }
                }
            }
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            cachedIndexOrNull(url)?.let { Loaded(it, fromCache = true) } ?: throw error
        }
    }

    /** Wipe the whole cache directory (Settings "Reset all app state"). */
    fun clearCache() {
        cacheDir.listFiles()?.forEach { it.delete() }
    }

    @OptIn(ExperimentalSerializationApi::class)
    private fun decodeFile(file: File): IndexJson =
        file.inputStream().buffered().use { stream ->
            json.decodeFromStream<IndexJson>(stream)
        }

    private fun readValidators(url: String): Validators? {
        val file = metaFile(url)
        if (!file.isFile) return null
        return runCatching { json.decodeFromString<Validators>(file.readText()) }.getOrNull()
    }

    private fun writeValidators(url: String, validators: Validators) {
        val temp = File.createTempFile("meta-", ".part", cacheDir)
        temp.writeText(json.encodeToString(validators))
        Files.move(
            temp.toPath(),
            metaFile(url).toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
        )
    }

    companion object {
        /** Stable cache-file naming — SHA-256 of the URL string, never hashCode(). */
        fun sha256Hex(value: String): String =
            MessageDigest.getInstance("SHA-256")
                .digest(value.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
    }
}

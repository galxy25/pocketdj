package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.rips.RipManifestEntry
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.coroutines.coroutineContext

/** Disk is full (ENOSPC). Aborts the rest of a burn run. */
class OutOfSpaceException(message: String = "No space left on device") : IOException(message)

/** True for [OutOfSpaceException] or any IOException in the cause chain reporting ENOSPC. */
fun isOutOfSpace(t: Throwable?): Boolean {
    var cur = t
    var guard = 0
    while (cur != null && guard++ < 8) {
        if (cur is OutOfSpaceException) return true
        val m = cur.message.orEmpty()
        if (cur is IOException && (m.contains("No space left", ignoreCase = true) || m.contains("ENOSPC"))) return true
        cur = cur.cause
    }
    return false
}

/**
 * The slice of the rips plane the burn store needs. Keeps [BurnStore] JVM-testable and the
 * bearer-never-rides-to-S3 invariant in one place (the implementation uses a plain client).
 */
interface BurnRips {
    suspend fun hasServer(): Boolean
    fun entry(songId: String): RipManifestEntry?

    /** A durable download URL: presigned (6 h, one retry) when a server exists, else direct. */
    suspend fun durableUrl(songId: String): String?
    fun stemUrls(songId: String): Map<String, String>?
    fun beatgridUrl(songId: String): String?
    fun urlForKey(key: String): String

    /** Streams [url] to [dest] (atomic, non-2xx and error documents rejected). Returns bytes. */
    suspend fun download(url: String, dest: File): Long

    /** Small body (beat-grid json) — throws on non-2xx. */
    suspend fun downloadBytes(url: String): ByteArray

    /** HEAD Last-Modified as epoch-ms; null offline/missing. */
    suspend fun lastModifiedMs(url: String): Double?
}

/** OkHttp-backed [BurnRips]. [http] must NOT attach auth (S3 rejects bearer + presign, 2026-09-01). */
class HttpBurnRips(
    private val http: OkHttpClient,
    private val manifestEntry: (String) -> RipManifestEntry?,
    private val serverConfigured: suspend () -> Boolean,
    private val presign: suspend (songId: String, ttlSeconds: Int) -> String,
    private val ripsBase: () -> String,
) : BurnRips {
    override suspend fun hasServer() = serverConfigured()
    override fun entry(songId: String) = manifestEntry(songId)

    override suspend fun durableUrl(songId: String): String? {
        val entry = manifestEntry(songId) ?: return null
        if (!serverConfigured()) return urlForKey(entry.key)
        repeat(2) {
            val u = try {
                presign(songId, 21_600)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            if (u != null) return u
        }
        return null
    }

    override fun stemUrls(songId: String) = manifestEntry(songId)?.stemUrls(ripsBase())
    override fun beatgridUrl(songId: String) = manifestEntry(songId)?.beatgridUrl(ripsBase())
    override fun urlForKey(key: String) = "${ripsBase().trimEnd('/')}/${key.removePrefix("/")}"

    override suspend fun download(url: String, dest: File): Long = withContext(Dispatchers.IO) {
        dest.parentFile?.mkdirs()
        val part = File(dest.parentFile, dest.name + ".part")
        try {
            http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                if (!resp.isSuccessful) throw IOException("HTTP ${resp.code}")
                val body = resp.body ?: throw IOException("empty body")
                part.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    body.byteStream().use { input ->
                        while (true) {
                            coroutineContext.ensureActive()
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                        }
                    }
                }
            }
            // Never finalize an S3 XML/HTML error document as audio.
            if (BurnReconciler.isPoisoned(part)) throw IOException("server returned an error document")
            Files.move(part.toPath(), dest.toPath(), StandardCopyOption.REPLACE_EXISTING)
            dest.length()
        } finally {
            if (part.exists()) part.delete()
        }
    }

    override suspend fun downloadBytes(url: String): ByteArray = withContext(Dispatchers.IO) {
        http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
            if (!resp.isSuccessful) throw IOException("HTTP ${resp.code}")
            resp.body?.bytes() ?: throw IOException("empty body")
        }
    }

    override suspend fun lastModifiedMs(url: String): Double? = withContext(Dispatchers.IO) {
        runCatching {
            http.newCall(Request.Builder().url(url).head().build()).execute().use { resp ->
                if (resp.code != 200) null else resp.headers.getDate("Last-Modified")?.time?.toDouble()
            }
        }.getOrNull()
    }
}

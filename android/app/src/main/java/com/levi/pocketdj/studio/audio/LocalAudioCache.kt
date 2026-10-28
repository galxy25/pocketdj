package com.levi.pocketdj.studio.audio

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap

/** A song's carve source on the device. [offsetMs] is the analog album offset (0 for a standalone cut / digital). */
data class LocalSource(val file: File, val isCut: Boolean, val offsetMs: Int)

/** The "burn rung" phases of the New-sample-from-track sheet (iOS ready / needsBurn / burning / burnFailed / ripFirst). */
sealed class SourcePhase {
    data class Ready(val source: LocalSource) : SourcePhase()
    object NeedsBurn : SourcePhase()
    object Burning : SourcePhase()
    data class Failed(val message: String) : SourcePhase()
    object RipFirst : SourcePhase()
}

/** What a burn/download attempt reported (mirrors BurnResult's carve-relevant counters). */
data class PrepareOutcome(
    val ok: Boolean,
    val notRipped: Boolean = false,
    val folderUnavailable: Boolean = false,
    val outOfSpace: Boolean = false,
)

/**
 * The 'burn' rung of the sample source ladder (local -> download -> 'Rip first'). It owns the phase
 * decision, the user-facing failure copy, and an atomic in-flight-deduped downloader used when the burn
 * folder is unreachable (the track is fetched into app cache instead). Collaborators are injected so
 * the whole ladder is JVM-testable; the app wires [Backend] to BurnStore + the rips manifest.
 */
class LocalAudioCache(
    private val dir: File,
    private val http: OkHttpClient,
    private val backend: Backend,
    private val io: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.IO,
) {
    interface Backend {
        /** Burned/cached file for [songId], preferring the standalone cut. Null when none. */
        fun local(songId: String): LocalSource?
        /** True when the rips manifest has an entry (something exists to download). */
        fun inManifest(songId: String): Boolean
        /** Burn one song via the burn store. */
        suspend fun burn(songId: String, title: String, artist: String): PrepareOutcome
        /** Durable (presigned) URL for the song's audio; null when none. */
        suspend fun durableUrl(songId: String): String?
        /** Analog album offset (BurnStore.startMs) for a non-cut source. */
        fun startMs(songId: String): Int = 0
    }

    private val scope = CoroutineScope(SupervisorJob() + io)
    private val inFlight = ConcurrentHashMap<String, CompletableDeferred<File>>()

    /** Initial phase for a picked song: Ready if on disk, NeedsBurn if in the manifest, else RipFirst. */
    fun phaseFor(songId: String): SourcePhase {
        backend.local(songId)?.let { return SourcePhase.Ready(it) }
        return if (backend.inManifest(songId)) SourcePhase.NeedsBurn else SourcePhase.RipFirst
    }

    /** Burn-on-demand then re-resolve. Failure copy matches iOS `burnThenReady`. */
    suspend fun prepare(songId: String, title: String, artist: String): SourcePhase {
        backend.local(songId)?.let { return SourcePhase.Ready(it) }
        if (!backend.inManifest(songId)) return SourcePhase.RipFirst
        val r = try { backend.burn(songId, title, artist) } catch (e: Exception) { return SourcePhase.Failed(GENERIC) }
        if (r.ok) backend.local(songId)?.let { return SourcePhase.Ready(it) }
        if (r.folderUnavailable) {
            // Burn folder unreachable: fall back to the app-cache download rung.
            val url = runCatching { backend.durableUrl(songId) }.getOrNull()
            if (url != null) {
                val f = runCatching { fetch(songId, url, "mp3") }.getOrNull()
                if (f != null) return SourcePhase.Ready(LocalSource(f, isCut = false, offsetMs = backend.startMs(songId)))
            }
            return SourcePhase.Failed(FOLDER)
        }
        return SourcePhase.Failed(
            when {
                r.notRipped -> NOT_RIPPED
                r.outOfSpace -> SPACE
                else -> GENERIC
            },
        )
    }

    /**
     * Download [url] to `<dir>/<key>.<ext>`. Writes `<name>.part` then atomically renames, so a partial
     * file is never visible under the final name; a non-2xx / HTML error body / IO failure deletes the
     * partial and throws. Concurrent callers for the same key share ONE request. A finished file is reused.
     */
    suspend fun fetch(key: String, url: String, ext: String = "mp3"): File {
        val dest = File(dir, "$key.$ext")
        if (dest.isFile && dest.length() > 0) return dest
        val mine = CompletableDeferred<File>()
        val existing = inFlight.putIfAbsent(dest.path, mine)
        if (existing != null) return existing.await()
        try {
            val f = withContext(io) { download(url, dest) }
            mine.complete(f)
            return f
        } catch (t: Throwable) {
            mine.completeExceptionally(t)
            throw t
        } finally {
            inFlight.remove(dest.path)
        }
    }

    fun isInFlight(key: String, ext: String = "mp3") = inFlight.containsKey(File(dir, "$key.$ext").path)

    private fun download(url: String, dest: File): File {
        dir.mkdirs()
        val part = File(dir, dest.name + ".part")
        part.delete()
        try {
            http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                if (!resp.isSuccessful) throw IOException("HTTP ${resp.code}")
                val ct = resp.header("Content-Type").orEmpty().lowercase()
                if (ct.startsWith("text/html") || ct.contains("json") || ct.contains("xml")) throw IOException("error document ($ct)")
                val body = resp.body ?: throw IOException("empty body")
                body.byteStream().use { input -> part.outputStream().use { out -> input.copyTo(out) } }
            }
            if (part.length() == 0L) throw IOException("empty download")
            Files.move(part.toPath(), dest.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            return dest
        } catch (t: Throwable) {
            part.delete()
            throw t
        }
    }

    /** Remove stale `.part` files (a killed download) at launch. */
    fun sweepPartials(): Int = dir.listFiles { f -> f.name.endsWith(".part") }?.count { it.delete() } ?: 0

    companion object {
        const val NOT_RIPPED = "There’s nothing prepared for this track yet, so there’s nothing to burn."
        const val FOLDER = "Your burn folder isn’t reachable right now (Settings ▸ Storage)."
        const val SPACE = "Not enough space to burn this track."
        const val GENERIC = "Couldn’t burn this track for carving."

        /**
         * File-relative carve window (the analog-offset contract): a shared album file needs the song's
         * startMs added; a standalone cut already starts at the song's 0:00.
         */
        fun fileWindow(src: LocalSource, regionStartMs: Int, regionEndMs: Int): Pair<Int, Int> {
            val off = if (src.isCut) 0 else src.offsetMs
            return (off + regionStartMs) to (off + regionEndMs)
        }
    }
}

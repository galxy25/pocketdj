package com.levi.pocketdj.data.lyrics

import com.levi.pocketdj.data.catalog.IndexSong
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Fetches a song's lyrics from the catalog CDN (`{catalogBase}/lyrics/<songId>.txt`) ON DEMAND -
 * only when a song's detail opens - and caches the text on disk so a re-open is instant and works
 * offline. Mirrors iOS `LyricsStore` / the PWA. Only songs whose index `lyricsStatus == "found"`
 * have a file; the rest are never fetched.
 *
 * Tiers: memory -> `filesDir/lyrics-cache/<safeId>.txt` -> network (then persisted). A non-2xx
 * response or blank body is a miss and is NEVER cached.
 */
class LyricsStore(
    private val cacheDir: File?,
    private val baseUrl: () -> String,
    private val fetch: (url: String) -> ByteArray?,
) {
    private val memory = ConcurrentHashMap<String, String>()

    /** Lyrics for [song], or null (not found / offline miss). Never fetches unless status == found. */
    suspend fun lyrics(song: IndexSong): String? {
        if (song.lyricsStatus != "found") return null
        val id = song.id
        memory[id]?.let { return it }
        return withContext(Dispatchers.IO) {
            readDisk(id)?.let { memory[id] = it; return@withContext it }
            val url = baseUrl().trimEnd('/') + "/lyrics/" + id + ".txt"
            val bytes = runCatching { fetch(url) }.getOrNull() ?: return@withContext null
            val text = bytes.toString(Charsets.UTF_8)
            if (text.isBlank()) return@withContext null
            memory[id] = text
            writeDisk(id, bytes)
            text
        }
    }

    /** Drop the in-memory tier (after the disk cache is cleared). */
    fun clearMemory() = memory.clear()

    /** Delete every cached lyrics file (Settings > Storage). */
    fun clearDisk() {
        memory.clear()
        cacheDir?.listFiles()?.forEach { it.delete() }
    }

    private fun readDisk(id: String): String? {
        val f = fileFor(id) ?: return null
        if (!f.isFile) return null
        val text = runCatching { f.readText(Charsets.UTF_8) }.getOrNull() ?: return null
        return text.takeIf { it.isNotBlank() }
    }

    private fun writeDisk(id: String, bytes: ByteArray) {
        val f = fileFor(id) ?: return
        runCatching {
            f.parentFile?.mkdirs()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(f)) { f.writeBytes(bytes); tmp.delete() }
        }
    }

    private fun fileFor(id: String): File? = cacheDir?.let { File(it, safeName(id) + ".txt") }

    companion object {
        const val DIR_NAME = "lyrics-cache"

        /** iOS parity: ':' and '/' become '_'; '\\' is also flattened defensively. */
        fun safeName(songId: String): String =
            songId.replace(':', '_').replace('/', '_').replace('\\', '_')

        /** Real GET; any non-2xx (404 / AccessDenied body) is a miss. */
        fun httpFetcher(client: OkHttpClient): (String) -> ByteArray? = { url ->
            client.newCall(Request.Builder().url(url).build()).execute().use { r ->
                if (r.isSuccessful) r.body?.bytes() else null
            }
        }
    }
}

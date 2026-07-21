package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.config.Endpoints
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.CacheControl
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Holds the rips manifest — the map from songId → playable audio
 * (specs/playback.md §2). Offline-first, same doctrine as the catalog cache:
 * a fetch failure keeps the last good copy (in memory and on disk); the disk
 * copy is written only after a successful decode.
 *
 * Refresh at app launch and after any rip job completes.
 */
class RipsRepository(
    private val cacheDir: File,
    private val http: OkHttpClient,
    private val json: Json = PdjJson.lenient,
    private val scope: CoroutineScope,
) {
    private val _manifest = MutableStateFlow<RipsManifest>(emptyMap())
    val manifest: StateFlow<RipsManifest> = _manifest.asStateFlow()

    private val manifestFile = File(cacheDir, "rips-manifest.json")

    init {
        cacheDir.mkdirs()
    }

    fun entry(songId: String): RipManifestEntry? = _manifest.value[songId]

    /** True when a public rip exists (metadata-only rows render no ▶ otherwise). */
    fun isPlayable(songId: String): Boolean =
        !PlayResolver.isStudioId(songId) && _manifest.value.containsKey(songId)

    /** Seed from the disk copy, then refresh from the network — call at launch. */
    fun loadAtLaunch() {
        scope.launch {
            seedFromDisk()
            runCatching { refresh() }
        }
    }

    private suspend fun seedFromDisk() = withContext(Dispatchers.IO) {
        if (_manifest.value.isNotEmpty() || !manifestFile.isFile) return@withContext
        runCatching {
            json.decodeFromString<RipsManifest>(manifestFile.readText())
        }.onSuccess { decoded ->
            if (_manifest.value.isEmpty()) _manifest.value = decoded
        }
    }

    /**
     * Fetch the manifest with cache-busting. Failure is silent (mirror iOS —
     * "Manifest fetch failure → keep cached copy"): the previous in-memory or
     * on-disk manifest is kept and returned.
     */
    suspend fun refresh(): RipsManifest = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(Endpoints.RIPS_MANIFEST_URL)
            .cacheControl(CacheControl.FORCE_NETWORK)
            .build()
        try {
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) error("HTTP ${response.code} fetching rips manifest")
                val text = response.body?.string() ?: error("Empty rips manifest body")
                val decoded = json.decodeFromString<RipsManifest>(text)
                _manifest.value = decoded
                // Persist raw bytes only after the decode succeeded; best-effort.
                runCatching {
                    val temp = File.createTempFile("rips-", ".part", cacheDir)
                    temp.writeText(text)
                    Files.move(
                        temp.toPath(),
                        manifestFile.toPath(),
                        StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.ATOMIC_MOVE,
                    )
                }
                decoded
            }
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            // Keep the previous in-memory manifest; try disk if we have nothing.
            if (_manifest.value.isEmpty()) seedFromDisk()
            _manifest.value
        }
    }
}

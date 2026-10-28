package com.levi.pocketdj.studio.packs

import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.studio.StudioFiles
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.StudioRoots
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Observable pack state (rows render straight off this). */
data class InstrumentPackState(
    /** Decoded index; null until the first fetch OR cache load. */
    val index: InstrumentPackIndex? = null,
    val isRefreshing: Boolean = false,
    /** Slugs of banks present on disk. */
    val downloadedSlugs: Set<String> = emptySet(),
    /** In-flight progress per BANK key 0..1 (the bank is the download unit). */
    val progressByBank: Map<String, Double> = emptyMap(),
    /** Last failure per bank key (cleared on retry). */
    val errorByBank: Map<String, String> = emptyMap(),
) {
    val packs: List<InstrumentPack> get() = index?.packs.orEmpty()
    val attribution: String? get() = index?.attribution?.takeIf { it.isNotEmpty() }

    fun isDownloaded(p: InstrumentPack) = p.bankKey.isNotEmpty() && InstrumentBankNaming.slug(p.bankKey) in downloadedSlugs
    fun isDownloading(p: InstrumentPack) = p.bankKey in progressByBank
    fun progress(p: InstrumentPack): Double? = progressByBank[p.bankKey]
    fun error(p: InstrumentPack): String? = errorByBank[p.bankKey]
}

/**
 * Instrument-pack client: index offline-first (network, validated body cached on disk as the offline
 * fallback), streamed bank download (never a 32 MB `ByteArray`) with progress, SHA-256 verify and an atomic
 * install into the app-managed `studio/instruments/` root under `instrument-<slug>.sf2`. Dedupe is by
 * `bankKey`: packs sharing a bank share one file, one download, one delete; the disk is the ledger.
 */
class InstrumentPackStore(
    private val roots: StudioRoots,
    private val cacheFile: File,
    private val scope: CoroutineScope,
    private val client: Call.Factory = defaultClient(),
    private val indexUrl: () -> String = { Endpoints.INSTRUMENTS_INDEX_URL },
    private val bankUrl: (String) -> String = { Endpoints.instrumentBankUrl(it) },
    private val io: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.IO,
    private val log: (String) -> Unit = {},
) {
    private val _state = MutableStateFlow(InstrumentPackState())
    val state: StateFlow<InstrumentPackState> = _state.asStateFlow()
    private val jobs = HashMap<String, Job>()
    private val lock = Any()

    init {
        // OFFLINE-FIRST: serve the last good index immediately (a few KB), refreshIndex upgrades it.
        loadCachedIndex()?.let { idx -> _state.update { it.copy(index = idx) } }
        rescanDownloads()
    }

    // ---- index

    /** Network first; on ANY failure the last-good cache stands in. Only a validated (decodes + non-empty) body is cached. */
    suspend fun refreshIndex() {
        if (_state.value.isRefreshing) return
        _state.update { it.copy(isRefreshing = true) }
        try {
            withContext(io) {
                try {
                    val req = Request.Builder().url(indexUrl()).header("Cache-Control", "no-cache").build()
                    val text = client.newCall(req).execute().use { r ->
                        if (!r.isSuccessful) throw InstrumentPackError.BadResponse
                        r.body?.string() ?: throw InstrumentPackError.BadResponse
                    }
                    val idx = InstrumentPackIndex.decode(text)?.takeIf { it.packs.isNotEmpty() } ?: throw InstrumentPackError.BadResponse
                    _state.update { it.copy(index = idx) }
                    runCatching { writeAtomic(cacheFile, text.toByteArray()) }
                    log("packs: index v${idx.version} — ${idx.packs.size} packs, ${idx.sharedBanks.size} banks")
                } catch (e: CancellationException) { throw e } catch (e: Exception) {
                    if (_state.value.index == null) loadCachedIndex()?.let { c -> _state.update { it.copy(index = c) } }
                    log("packs: index fetch failed — ${e.message}")
                }
            }
        } finally {
            _state.update { it.copy(isRefreshing = false) }
        }
    }

    private fun loadCachedIndex(): InstrumentPackIndex? =
        runCatching { InstrumentPackIndex.decode(cacheFile.readText()) }.getOrNull()?.takeIf { it.packs.isNotEmpty() }

    fun bank(key: String): InstrumentBank? = _state.value.index?.sharedBanks?.firstOrNull { it.key == key }

    // ---- lookup

    /** The LOCAL SoundFont file for a pack's bank, or null until downloaded. */
    fun localBankFile(pack: InstrumentPack): File? {
        if (pack.bankKey.isEmpty()) return null
        val f = StudioFiles.appFile(roots, StudioFamily.INSTRUMENTS, InstrumentBankNaming.localFileName(pack.bankKey)) ?: return null
        return f.takeIf { it.isFile }
    }

    /** The bank for an INSTRUMENT (its covering pack's downloaded bank), or null -> "download the pack first". */
    fun localBankFile(instrument: InstrumentKey): File? =
        _state.value.packs.firstOrNull { it.instrument == instrument }?.let { localBankFile(it) }

    fun pack(instrument: InstrumentKey): InstrumentPack? = _state.value.packs.firstOrNull { it.instrument == instrument }

    /** Rebuild the downloaded set from disk (init; and after the Storage manager swept the folder). */
    fun rescanDownloads() {
        val names = runCatching { roots.appDir(StudioFamily.INSTRUMENTS).list() }.getOrDefault(emptyList())
        val slugs = names.mapNotNull { StudioFolders.fileId(StudioFamily.INSTRUMENTS, it) }.toSet()
        _state.update { it.copy(downloadedSlugs = slugs) }
    }

    // ---- download

    /**
     * Download a pack — i.e. its BANK. Idempotent + deduped: an already-downloaded bank returns at once (the
     * second pack sharing it is instantly "downloaded"); an in-flight bank is joined (every row watches the same progress).
     */
    fun download(pack: InstrumentPack): Job? {
        val key = pack.bankKey
        if (key.isEmpty()) { setError(key, InstrumentPackError.NotDownloadable.description); return null }
        val slug = InstrumentBankNaming.slug(key)
        if (slug in _state.value.downloadedSlugs) return null
        val dest = StudioFiles.appFile(roots, StudioFamily.INSTRUMENTS, InstrumentBankNaming.localFileName(key))
        if (dest == null) { setError(key, InstrumentPackError.FileSystem.description); return null }
        synchronized(lock) {
            jobs[key]?.let { return it }
            if (dest.isFile) { _state.update { it.copy(downloadedSlugs = it.downloadedSlugs + slug) }; return null }
            val expected = bank(key)?.sha256.orEmpty()
            if (expected.isEmpty()) log("packs: WARNING no sha256 for $key — installing unverified")
            _state.update { it.copy(progressByBank = it.progressByBank + (key to 0.0), errorByBank = it.errorByBank - key) }
            val job = scope.launch(io, start = kotlinx.coroutines.CoroutineStart.LAZY) {
                val outcome = try {
                    downloadTo(bankUrl(key), dest, expected) { f -> _state.update { it.copy(progressByBank = it.progressByBank + (key to f)) } }
                    null
                } catch (e: CancellationException) { throw e } catch (e: Exception) { e }
                finish(key, slug, outcome)
            }
            jobs[key] = job
            job.invokeOnCompletion { c -> if (c is CancellationException) finish(key, slug, c) }
            job.start()
            return job
        }
    }

    /** Cancel a pack's in-flight bank download (a user action: no error surfaced). */
    fun cancelDownload(pack: InstrumentPack) { synchronized(lock) { jobs[pack.bankKey] }?.cancel() }

    private fun finish(key: String, slug: String, error: Throwable?) {
        synchronized(lock) { jobs.remove(key) }
        _state.update { s ->
            var n = s.copy(progressByBank = s.progressByBank - key)
            when {
                error == null -> { n = n.copy(downloadedSlugs = n.downloadedSlugs + slug); log("packs: download OK $key") }
                error is CancellationException -> log("packs: download cancelled $key")
                else -> { n = n.copy(errorByBank = n.errorByBank + (key to ((error as? InstrumentPackError)?.description ?: (error.message ?: "Download failed")))); log("packs: download FAILED $key — ${error.message}") }
            }
            n
        }
    }

    private fun setError(key: String, msg: String) = _state.update { it.copy(errorByBank = it.errorByBank + (key to msg)) }

    /** Stream [url] to a staging file NEXT TO [dest] (same volume => atomic rename), then verify + install. */
    private fun downloadTo(url: String, dest: File, expectedSha: String, onProgress: (Double) -> Unit) {
        val dir = dest.parentFile ?: throw InstrumentPackError.FileSystem
        dir.mkdirs()
        val staging = File(dir, ".pack-staging-${UUID.randomUUID()}.tmp")
        try {
            val req = Request.Builder().url(url).build()
            client.newCall(req).execute().use { r ->
                if (!r.isSuccessful) throw InstrumentPackError.BadResponse
                val body = r.body ?: throw InstrumentPackError.BadResponse
                val total = body.contentLength()
                var read = 0L
                var last = -1.0
                body.byteStream().use { input ->
                    staging.outputStream().use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            read += n
                            if (total > 0) {
                                val f = read.toDouble() / total
                                if (f >= last + 0.01 || f >= 1.0) { last = f; onProgress(f.coerceAtMost(1.0)) }
                            }
                        }
                    }
                }
                if (total > 0 && read != total) throw IOException("truncated: $read of $total")
            }
            installBank(staging, dest, expectedSha)
        } finally {
            staging.delete()
        }
    }

    /** Delete a bank's file (packs referencing it flip back to downloadable). */
    fun deleteBank(bankKey: String) {
        if (bankKey.isEmpty()) return
        StudioFiles.appFile(roots, StudioFamily.INSTRUMENTS, InstrumentBankNaming.localFileName(bankKey))?.delete()
        _state.update { it.copy(downloadedSlugs = it.downloadedSlugs - InstrumentBankNaming.slug(bankKey)) }
        log("packs: deleted bank $bankKey")
    }

    /** On-disk bytes of downloaded banks (strict-shape scan; foreign files never count). */
    fun usageBytes(): Long = StudioFolders.usageBytes(roots, StudioFamily.INSTRUMENTS)

    companion object {
        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()

        /**
         * Verify then atomically install [staged] as [dest]. A digest mismatch deletes the bytes and throws
         * (unverified data never lands under a real name); a bank another pack already installed is success.
         * [staged] is consumed (moved or deleted) either way.
         */
        fun installBank(staged: File, dest: File, expectedSha256: String) {
            try {
                if (expectedSha256.isNotEmpty() && sha256Hex(staged) != expectedSha256.lowercase()) throw InstrumentPackError.ShaMismatch
                if (dest.exists()) { staged.delete(); return }
                if (!staged.renameTo(dest)) throw InstrumentPackError.FileSystem
            } catch (e: Exception) {
                staged.delete()
                throw e
            }
        }

        /** Streaming SHA-256 (lowercase hex), 1 MB chunks. */
        fun sha256Hex(file: File): String {
            val md = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buf = ByteArray(1 shl 20)
                while (true) { val n = input.read(buf); if (n < 0) break; md.update(buf, 0, n) }
            }
            return md.digest().joinToString("") { "%02x".format(it) }
        }

        private fun writeAtomic(dest: File, bytes: ByteArray) {
            dest.parentFile?.mkdirs()
            val tmp = File(dest.parentFile, ".${dest.name}.${UUID.randomUUID()}.tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(dest)) { tmp.delete(); throw IOException("rename failed") }
        }
    }
}

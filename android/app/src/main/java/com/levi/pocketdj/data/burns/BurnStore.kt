package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.edition.SongVariant
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.data.transfers.TransferCoordinator
import com.levi.pocketdj.data.transfers.TransferKind
import com.levi.pocketdj.data.transfers.TransferRecord
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The ONE offline store (decision D5). Port of iOS `BurnStore` minus the background
 * `TransferCoordinator` path (that is SVC-3): `burn(songs)` is the in-process SERIAL loop, which
 * is exactly the iOS `transfers == nil` path.
 *
 * Invariants carried over verbatim:
 *  - Files keyed analog -> ONE shared `<album>-<albumId>.mp3` (written once, freed with the LAST
 *    referencing song) / digital -> `<descriptive>-<songId>.mp3`; id suffix + ext never truncated.
 *  - Burn NEVER blocks on a rip: a song not in the manifest becomes an error item and the loop
 *    continues.
 *  - STOP is checked at the TOP of each iteration only (the in-flight item is fully written and
 *    recorded; no orphan sidecar).
 *  - Disk-full aborts the remainder; a folder probe failure aborts with one clear flag.
 *  - Items resolve against the root they were ACTUALLY written to (`wasAppStorage`); an
 *    unreachable root is skipped, never pruned.
 *  - Ledger JSON is the iOS `BurnStore.Document` shape (`pocketdj-burns.json`).
 */
class BurnStore(
    private val ledgerFile: File,
    private val folder: BurnFolder,
    private val rips: BurnRips,
    /** Catalog lookup (song, album) for a BASE song id. */
    private val lookup: (String) -> Pair<IndexSong?, IndexAlbum?> = { null to null },
    private val clock: () -> Long = System::currentTimeMillis,
    writerExecutor: Executor = VersionedJsonWriter.DIRECT,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /** SVC-3: when set, downloads run as WorkManager jobs that survive process death (iOS `transfers`). */
    private val transfers: TransferCoordinator? = null,
) {
    private val json = PdjJson.lenient
    private val writer = VersionedJsonWriter(ledgerFile, writerExecutor)
    private val version = AtomicLong()

    private val _items = MutableStateFlow<Map<String, BurnItem>>(emptyMap())
    val items: StateFlow<Map<String, BurnItem>> = _items.asStateFlow()

    private val _pending = MutableStateFlow<Map<String, PendingBurn>>(emptyMap())
    val pendingAfterRip: StateFlow<Map<String, PendingBurn>> = _pending.asStateFlow()

    private val _progress = MutableStateFlow<BurnProgress?>(null)
    val progress: StateFlow<BurnProgress?> = _progress.asStateFlow()

    @Volatile
    var stopRequested: Boolean = false
        private set

    /** Fan-out AFTER an adopted/finalized `.ready` item landed (collection mix downloader). */
    @Volatile
    var onAnyBurnFinalized: ((songId: String, bytes: Long) -> Unit)? = null

    private val runLock = Mutex()

    /** True only while an in-process burn loop holds the run lock (NOT background transfers). */
    val loopActive: Boolean get() = runLock.isLocked
    private val localMemo = ConcurrentHashMap<String, Any>()
    private val none = Any()

    private val now: Double get() = clock().toDouble()

    init {
        transfers?.let { t ->
            t.onBurnFinalized = { rec, bytes -> finalizeTransfer(rec, bytes) }
            t.onBurnFailed = { rec, msg -> failTransfer(rec, msg) }
            t.onProgress = { e, f ->
                _progress.value = if (e > 0 && f < e) BurnProgress(f, e, "Downloading…") else null
            }
        }
        if (ledgerFile.isFile) {
            try {
                val doc = json.decodeFromString(BurnDocument.serializer(), ledgerFile.readText())
                _items.value = LinkedHashMap<String, BurnItem>().also { m -> doc.items.forEach { m.putIfAbsent(it.songId, it) } }
                _pending.value = LinkedHashMap<String, PendingBurn>().also { m -> (doc.pendingAfterRip ?: emptyList()).forEach { m.putIfAbsent(it.songId, it) } }
            } catch (e: Exception) {
                // Undecodable (corrupt / future schema): keep it aside so the next save() can't destroy it.
                runCatching { ledgerFile.renameTo(File(ledgerFile.parentFile, ledgerFile.name + ".corrupt-" + clock())) }
            }
        }
    }

    // ---- persistence --------------------------------------------------------------------------

    private fun save() {
        val doc = BurnDocument(
            items = _items.value.values.sortedBy { it.downloadedAt },
            pendingAfterRip = _pending.value.values.sortedBy { it.requestedAtMs },
        )
        writer.write(version.incrementAndGet()) { json.encodeToString(BurnDocument.serializer(), doc) }
    }

    /** Barrier write (ON_STOP): nothing queued can be lost to a process kill. */
    fun flush() {
        val doc = BurnDocument(
            items = _items.value.values.sortedBy { it.downloadedAt },
            pendingAfterRip = _pending.value.values.sortedBy { it.requestedAtMs },
        )
        writer.flushNow(version.incrementAndGet()) { json.encodeToString(BurnDocument.serializer(), doc) }
    }

    private fun setItem(item: BurnItem) {
        _items.update { it + (item.songId to item) }
        localMemo.clear()
    }

    private fun dropItems(ids: Collection<String>) {
        _items.update { it - ids.toSet() }
        localMemo.clear()
    }

    private fun patchItem(songId: String, f: (BurnItem) -> BurnItem) {
        _items.update { m -> m[songId]?.let { m + (songId to f(it)) } ?: m }
        localMemo.clear()
    }

    private fun itemDir(item: BurnItem): File? = folder.dirFor(item.wasAppStorage)

    // ---- STOP ---------------------------------------------------------------------------------

    /** Idempotent; the loop honours it at the top of the next iteration. */
    fun requestStop() {
        stopRequested = true
        // iOS parity: Stop also cancels in-flight background transfers and drops their rows.
        if (transfers != null) {
            val pending = _items.value.values.filter { it.state == BurnState.DOWNLOADING }.map { it.songId }
            if (pending.isNotEmpty()) cancelTransfers(pending)
        }
    }

    // ---- local resolution ---------------------------------------------------------------------

    /** The burned audio file iff a READY item's file still exists (memoized per items change). */
    fun localUrl(songId: String): File? {
        val memo = localMemo[songId]
        if (memo != null) return if (memo === none) null else memo as File
        val item = _items.value[songId]
        val resolved = if (item != null && item.state == BurnState.READY) {
            itemDir(item)?.let { File(it, item.audioFileName) }?.takeIf { it.exists() }
        } else null
        localMemo[songId] = resolved ?: none
        return resolved
    }

    fun hasLocalFile(songId: String): Boolean = localUrl(songId) != null

    /** Playback resolution (uncached; the moment of use re-checks the disk). */
    fun localUrlForPlayback(songId: String): File? {
        val item = _items.value[songId]?.takeIf { it.state == BurnState.READY } ?: return null
        return itemDir(item)?.let { File(it, item.audioFileName) }?.takeIf { it.exists() }
    }

    /** Prefers the standalone per-song cut (plays from 0:00); [CutResolved.isCut] => do NOT apply startMs. */
    fun localUrlPreferringCut(songId: String): CutResolved? {
        val item = _items.value[songId]?.takeIf { it.state == BurnState.READY } ?: return null
        val dir = itemDir(item) ?: return null
        resolveCutFileName(item, dir, heal = true)?.let { return CutResolved(File(dir, it), true) }
        val f = File(dir, item.audioFileName)
        return if (f.exists()) CutResolved(f, false) else null
    }

    /** Analog seek offset inside the shared album mp3 (null for digital / not burned). */
    fun startMs(songId: String): Long? =
        _items.value[songId]?.takeIf { it.state == BurnState.READY }?.startMs

    private fun resolveCutFileName(
        item: BurnItem,
        dir: File,
        listing: (() -> List<String>)? = null,
        heal: Boolean,
    ): String? {
        item.cutFileName?.let { if (File(dir, it).exists()) return it }
        if (item.source != "analog") return null
        val names = listing?.invoke() ?: dir.list()?.toList() ?: return null
        val found = BurnFileNames.cutFileNameAmongst(names, item.songId, item.audioFileName) ?: return null
        if (heal) {
            patchItem(item.songId) { it.copy(cutFileName = found) }
            save()
        }
        return found
    }

    /** The manifest beat grid (bpm preferred over the catalog BPM for beat matching). */
    data class ManifestBeatGrid(val bpm: Double?, val firstDownbeatMs: Long?, val steady: Boolean?)

    fun beatGrid(songId: String): ManifestBeatGrid? {
        val e = rips.entry(songId) ?: return null
        if (e.beatGridBpm == null && e.firstDownbeatMs == null) return null
        return ManifestBeatGrid(e.beatGridBpm, e.firstDownbeatMs, e.steady)
    }

    // ---- roots helpers ------------------------------------------------------------------------

    /** READ root: the user folder when reachable, else the app root. */
    private fun readRoot(): BurnRoot? = folder.roots().lastOrNull()

    private fun listNames(dir: File): List<String> = dir.list()?.toList() ?: emptyList()

    private fun ownsAux(name: String, inUserFolder: Boolean): Boolean {
        val id = BurnFileNames.auxFileSongId(name) ?: return false
        if (!inUserFolder) return true
        return _items.value[id] != null || rips.entry(id) != null
    }

    private fun snapshots(): List<RootSnapshot> = folder.roots().map { r ->
        RootSnapshot(r.isUserFolder, r.dir.listFiles()?.filter { it.isFile }?.associate { it.name to it.length() } ?: emptyMap())
    }

    // ---- freshness / names --------------------------------------------------------------------

    /** Fresh = file exists, size == recorded bytes, and not re-ripped since [BurnItem.downloadedAt]. */
    fun isFresh(item: BurnItem, dir: File, rippedAt: Double?): Boolean {
        val f = File(dir, item.audioFileName)
        if (!f.isFile || f.length() != item.bytes) return false
        if (rippedAt != null && rippedAt > item.downloadedAt) return false
        return true
    }

    private fun errorItem(song: BurnSong, message: String) = BurnItem(
        songId = song.id, title = song.title, artist = song.artist,
        audioFileName = "", sidecarFileName = "", source = "digital",
        bytes = 0, downloadedAt = now, state = BurnState.ERROR, error = message, wasAppStorage = null,
    )

    private fun catalogFor(songId: String): Pair<IndexSong?, IndexAlbum?> = lookup(SongVariant.baseId(songId))

    private fun writeAtomic(dest: File, bytes: ByteArray) {
        dest.parentFile?.mkdirs()
        val part = File(dest.parentFile, dest.name + ".part")
        try {
            part.writeBytes(bytes)
            Files.move(part.toPath(), dest.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } finally {
            if (part.exists()) part.delete()
        }
    }

    // ---- the serial burn loop -----------------------------------------------------------------

    /**
     * BURN [songs] ONE BY ONE (in-process serial path). Never blocks on a rip; per-item failures
     * are partial success; disk-full aborts the rest. Empty input is a no-op.
     */
    suspend fun burn(songs: List<BurnSong>): BurnResult = runLock.withLock { burnLocked(songs) }

    private val priorReady = ConcurrentHashMap<String, BurnItem>()

    /** Disk IO (probe, stats, sidecars, listings) runs on [io], never the caller's (Main) thread. */
    private suspend fun burnLocked(songs: List<BurnSong>): BurnResult = withContext(io) { burnLockedIo(songs) }

    /** Debug-only seam (Settings > Debug): rewrites the enqueue URL, e.g. to force an HTTP 400. */
    @Volatile var debugUrlTransform: ((String) -> String)? = null

    private suspend fun burnLockedIo(songs: List<BurnSong>): BurnResult {
        stopRequested = false
        val unique = LinkedHashMap<String, BurnSong>().also { m -> songs.forEach { if (it.id.isNotEmpty()) m.putIfAbsent(it.id, it) } }.values.toList()
        if (unique.isEmpty()) return BurnResult()
        var burned = 0
        var notRipped = 0
        var failed = 0
        var outOfSpace = false
        var stopped = false
        var folderUnavailable = false
        var stemmed = 0
        var gridded = 0
        var queued = 0

        val root = folder.activeWritable()
        if (root == null) return BurnResult(failed = unique.size, total = unique.size)
        val dir = root.dir
        if (!folder.probeWrite(root)) return BurnResult(total = unique.size, folderUnavailable = true)

        var done = 0
        // Once per run, never per song; a still-live earlier run keeps its counters.
        if (transfers != null && transfers.records.isEmpty()) transfers.beginRun()
        try {
            for (song in unique) {
                if (stopRequested || !currentCoroutineContext().isActive) { stopped = true; break }
                _progress.value = BurnProgress(done, unique.size, "${song.artist} — ${song.title}")
                try {
                    // (1) idempotency: already burned + fresh -> skip and count as burned.
                    val existing = _items.value[song.id]
                    if (existing != null && existing.state == BurnState.READY) {
                        val exDir = itemDir(existing)
                        if (exDir != null && isFresh(existing, exDir, rips.entry(song.id)?.rippedAt)) {
                            burned += 1
                            rips.entry(song.id)?.let { exportAnalogCut(song.id, it, dir) }
                            continue
                        }
                    }
                    // (2) not ripped: never await a rip.
                    val entry = rips.entry(song.id)
                    if (entry == null) {
                        val why = if (rips.hasServer()) "not ripped — Rip first" else "not ripped (no rip server)"
                        setItem(errorItem(song, why))
                        notRipped += 1
                        continue
                    }
                    // (3) catalog + names BEFORE any network (sidecar pre-rendered too).
                    val (s, a) = catalogFor(song.id)
                    val names = BurnFileNames.fileNames(song.id, entry, s, a)
                    val audioFile = File(dir, names.audio)
                    val isAnalog = entry.source == "analog"
                    // Analog: the whole-album mp3 is stored ONCE. Reuse it only while a ledger item
                    // that references it is at least as new as the current rip.
                    val reuseShared = isAnalog && audioFile.isFile && _items.value.values.any {
                        it.audioFileName == names.audio && it.state == BurnState.READY &&
                            (entry.rippedAt == null || entry.rippedAt <= it.downloadedAt)
                    }
                    var bytes = audioFile.length()
                    if (!reuseShared) {
                        val url = rips.durableUrl(song.id)
                        if (url == null) {
                            setItem(errorItem(song, "couldn't get a playback URL — check the rip server"))
                            notRipped += 1
                            continue
                        }
                        if (transfers != null) {
                            val sidecarText = BurnSidecar.build(song.id, song, s, a, entry)
                            setItem(
                                BurnItem(
                                    songId = song.id, title = song.title, artist = song.artist,
                                    audioFileName = names.audio, sidecarFileName = names.sidecar,
                                    source = entry.source ?: "digital", bpm = entry.bpm, musicalKey = entry.musicalKey,
                                    camelot = entry.camelot, durationMs = entry.durationMs,
                                    startMs = if (isAnalog) entry.startMs else null,
                                    bytes = existing?.bytes ?: 0, rippedAt = entry.rippedAt, downloadedAt = existing?.downloadedAt ?: now,
                                    state = BurnState.DOWNLOADING, wasAppStorage = !root.isUserFolder,
                                    cutFileName = existing?.cutFileName, cutDownloadedAt = existing?.cutDownloadedAt,
                                ),
                            )
                            // Persist the ledger row + the transfer record BEFORE the work exists.
                            save()
                            transfers.enqueue(
                                debugUrlTransform?.invoke(url) ?: url,
                                TransferRecord(
                                    songId = song.id, kind = TransferKind.BURN,
                                    audioFileName = names.audio, sidecarFileName = names.sidecar, sidecarText = sidecarText,
                                    wasAppStorage = !root.isUserFolder, manifestKey = entry.key,
                                    source = entry.source ?: "digital", bpm = entry.bpm, musicalKey = entry.musicalKey,
                                    camelot = entry.camelot, durationMs = entry.durationMs,
                                    startMs = if (isAnalog) entry.startMs else null, rippedAt = entry.rippedAt,
                                    title = song.title, artist = song.artist, createdAt = now,
                                ),
                            )
                            queued += 1
                            burned += 1
                            continue
                        }
                        existing?.let { priorReady[song.id] = it; patchItem(song.id) { it.copy(state = BurnState.DOWNLOADING) } }
                        bytes = rips.download(url, audioFile)
                    }
                    writeAtomic(File(dir, names.sidecar), BurnSidecar.build(song.id, song, s, a, entry).toByteArray())
                    val prev = _items.value[song.id]
                    setItem(
                        BurnItem(
                            songId = song.id, title = song.title, artist = song.artist,
                            audioFileName = names.audio, sidecarFileName = names.sidecar,
                            source = entry.source ?: "digital",
                            bpm = entry.bpm, musicalKey = entry.musicalKey, camelot = entry.camelot,
                            durationMs = entry.durationMs,
                            startMs = if (isAnalog) entry.startMs else null,
                            bytes = bytes, rippedAt = entry.rippedAt, downloadedAt = now,
                            state = BurnState.READY, error = null, wasAppStorage = !root.isUserFolder,
                            cutFileName = prev?.cutFileName, cutDownloadedAt = prev?.cutDownloadedAt,
                        ),
                    )
                    priorReady.remove(song.id)
                    burned += 1
                    save()
                    exportAnalogCut(song.id, entry, dir)
                } catch (e: CancellationException) {
                    // Restore the pre-run READY record (old audio + sidecar are still on disk); else drop.
                    if (_items.value[song.id]?.state == BurnState.DOWNLOADING) {
                        priorReady.remove(song.id)?.let { setItem(it) } ?: dropItems(listOf(song.id))
                    }
                    throw e
                } catch (e: Exception) {
                    if (isOutOfSpace(e)) {
                        setItem(errorItem(song, "out of space"))
                        outOfSpace = true
                        failed += 1
                        break
                    }
                    setItem(errorItem(song, e.message ?: e.javaClass.simpleName))
                    failed += 1
                } finally {
                    priorReady.remove(song.id)
                    done += 1
                }
            }

            if (!stopped && currentCoroutineContext().isActive && !outOfSpace) {
                stemmed = burnCollectionStems(unique, dir)
            }
            if (!stopped && currentCoroutineContext().isActive && !outOfSpace) {
                gridded = burnCollectionBeatgrids(unique, dir)
            }
        } finally {
            save()
            // With transfers the progress mirror belongs to the coordinator until it settles.
            if (transfers == null || !transfers.progress.value.active) _progress.value = null
        }
        return BurnResult(
            burned = burned, notRipped = notRipped, failed = failed, total = unique.size,
            outOfSpace = outOfSpace, folderUnavailable = folderUnavailable, stopped = stopped,
            stemmedSongs = stemmed, beatGridded = gridded, queued = queued,
        )
    }

    // ---- analog cut export --------------------------------------------------------------------

    /** Download ONE analog song's server-sliced cut next to the shared album file. Best effort. */
    private suspend fun exportAnalogCut(songId: String, entry: RipManifestEntry, dir: File) {
        val cutKey = entry.cutKey
        if (entry.source != "analog" || cutKey == null) return
        val (s, a) = catalogFor(songId)
        val cutName = BurnFileNames.cutFileName(s, a, entry, songId)
        val cutFile = File(dir, cutName)
        val url = rips.urlForKey(cutKey)
        val remoteMs = rips.lastModifiedMs(url)
        val exists = cutFile.exists()
        val storedMs = _items.value[songId]?.cutDownloadedAt
        if (exists && remoteMs != null && storedMs != null && storedMs >= remoteMs) {
            patchItem(songId) { it.copy(cutFileName = cutName) }
            return
        }
        if (remoteMs == null && exists) {
            patchItem(songId) { it.copy(cutFileName = cutName) }
            return
        }
        try {
            // download() replaces atomically, so a failure never loses the existing cut.
            rips.download(url, cutFile)
            val old = _items.value[songId]?.cutFileName
            if (old != null && old != cutName) File(dir, old).delete()
            patchItem(songId) { it.copy(cutFileName = cutName, cutDownloadedAt = remoteMs ?: now) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // a cut failure never fails the burn
        }
    }

    // ---- stems --------------------------------------------------------------------------------

    private fun stemFilesPresent(songId: String, dir: File) = BurnStems.allPresent(dir, songId)

    private suspend fun burnCollectionStems(songs: List<BurnSong>, dir: File): Int {
        val stemmed = songs.filter { rips.entry(it.id)?.stemVersion != null }
        if (stemmed.isEmpty()) return 0
        val pending = stemmed.filter { !stemFilesPresent(it.id, dir) }
        var done = 0
        for (s in pending) {
            if (stopRequested || !currentCoroutineContext().isActive) break
            _progress.value = BurnProgress(done, pending.size, "Stems · ${s.artist} — ${s.title}")
            downloadStems(s.id, dir)
            done += 1
        }
        return stemmed.count { stemFilesPresent(it.id, dir) }
    }

    private suspend fun downloadStems(songId: String, dir: File) {
        val remote = rips.stemUrls(songId) ?: return
        for (name in BurnFileNames.STEM_NAMES) {
            if (stopRequested || !currentCoroutineContext().isActive) return
            val url = remote[name] ?: return
            val dest = File(dir, BurnFileNames.stemFileName(songId, name))
            if (dest.exists()) continue
            try {
                rips.download(url, dest)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                return // a stem failure never fails the burn
            }
        }
    }

    private suspend fun burnCollectionBeatgrids(songs: List<BurnSong>, dir: File): Int {
        val analyzed = songs.filter { rips.entry(it.id)?.beatgridKey != null }
        if (analyzed.isEmpty()) return 0
        val pending = analyzed.filter { !File(dir, BurnFileNames.beatgridFileName(it.id)).exists() }
        var done = 0
        for (s in pending) {
            if (stopRequested || !currentCoroutineContext().isActive) break
            _progress.value = BurnProgress(done, pending.size, "Beat grid · ${s.artist} — ${s.title}")
            downloadBeatgrid(s.id, dir)
            done += 1
        }
        return analyzed.count { File(dir, BurnFileNames.beatgridFileName(it.id)).exists() }
    }

    /** Validates the JSON BEFORE caching so a truncated/garbage body is never written. */
    private suspend fun downloadBeatgrid(songId: String, dir: File) {
        val dest = File(dir, BurnFileNames.beatgridFileName(songId))
        if (dest.exists()) return
        val url = rips.beatgridUrl(songId) ?: return
        try {
            val data = rips.downloadBytes(url)
            if (!BurnStems.isValidBeatGrid(data)) return
            writeAtomic(dest, data)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
    }

    /** All 4 stem files iff every one exists in the active read root (all-or-nothing). */
    fun localStemFiles(songId: String): Map<String, File>? {
        val dir = readRoot()?.dir ?: return null
        val out = LinkedHashMap<String, File>()
        for (n in BurnFileNames.STEM_NAMES) {
            val f = File(dir, BurnFileNames.stemFileName(songId, n))
            if (!f.exists()) return null
            out[n] = f
        }
        return out
    }

    fun stemsBurned(songId: String) = localStemFiles(songId) != null

    /** Does the catalog have stems for this song at all (streamable/burnable on demand)? */
    fun stemsRemote(songId: String): Boolean = rips.stemUrls(songId) != null

    /** Any subset of the four parts already on disk (Stem Lock reads part by part). */
    fun localStemPartFiles(songId: String): Map<String, File>? {
        val dir = readRoot()?.dir ?: return null
        val out = LinkedHashMap<String, File>()
        for (n in BurnFileNames.STEM_NAMES) {
            val f = File(dir, BurnFileNames.stemFileName(songId, n))
            if (f.exists()) out[n] = f
        }
        return out.ifEmpty { null }
    }

    fun stemPartsBurned(songId: String): Set<String> = localStemPartFiles(songId)?.keys ?: emptySet()

    /** Every song id with all 4 stems on disk in the active root. */
    fun localStemSongIds(): List<String> {
        val dir = readRoot()?.dir ?: return emptyList()
        return BurnStems.fullyStemmedIds(listNames(dir)).filter { stemsBurned(it) }
    }

    /** BURN the 4 stems (idempotent; never triggers separation). Null if not stemmed / failed. */
    suspend fun burnStems(songId: String): Map<String, File>? {
        localStemFiles(songId)?.let { return it }
        val remote = rips.stemUrls(songId) ?: return null
        val dir = folder.activeWritable()?.dir ?: return null
        val local = LinkedHashMap<String, File>()
        for (n in BurnFileNames.STEM_NAMES) {
            val url = remote[n] ?: return null
            val dest = File(dir, BurnFileNames.stemFileName(songId, n))
            if (!dest.exists()) {
                try {
                    rips.download(url, dest)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    return null
                }
            }
            local[n] = dest
        }
        return local
    }

    /** BURN ONE stem part (same file name the whole-set burn / streamed adoption use). */
    suspend fun burnStemPart(songId: String, part: String): Boolean {
        if (part !in BurnFileNames.STEM_NAMES) return false
        val url = rips.stemUrls(songId)?.get(part) ?: return false
        val dir = folder.activeWritable()?.dir ?: return false
        val dest = File(dir, BurnFileNames.stemFileName(songId, part))
        if (dest.exists()) return true
        return try {
            rips.download(url, dest)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
    }

    /**
     * MIX STREAMING: MOVE a deck's 4 streamed stems into the burn root under their burned names.
     * ALL OR NOTHING: a move failing part-way rolls the moved parts back. A part already burned
     * keeps the existing file.
     */
    fun adoptStreamedStems(songId: String, files: Map<String, File>): Map<String, File>? {
        if (files.keys != BurnFileNames.STEM_NAMES.toSet()) return null
        val dir = folder.activeWritable()?.dir ?: return null
        val out = LinkedHashMap<String, File>()
        val moved = ArrayList<Pair<File, File>>()
        for ((name, src) in files) {
            val dest = File(dir, BurnFileNames.stemFileName(songId, name))
            if (dest.exists()) { out[name] = dest; continue }
            try {
                moveFile(src, dest)
            } catch (_: Exception) {
                for ((from, to) in moved) runCatching { moveFile(to, from) }
                return null
            }
            moved += src to dest
            out[name] = dest
        }
        return out
    }

    private fun moveFile(src: File, dest: File) {
        try {
            Files.move(src.toPath(), dest.toPath())
        } catch (_: IOException) {
            Files.copy(src.toPath(), dest.toPath())
            src.delete()
        }
    }

    // ---- beat grid ----------------------------------------------------------------------------

    fun localBeatgridFile(songId: String): File? {
        val dir = readRoot()?.dir ?: return null
        return File(dir, BurnFileNames.beatgridFileName(songId)).takeIf { it.exists() }
    }

    fun beatgridBurned(songId: String) = localBeatgridFile(songId) != null

    /** Parse the LOCAL per-beat sidecar; null if absent/unreadable/malformed. */
    fun localBeatGrid(songId: String): BeatGridSidecar? =
        localBeatgridFile(songId)?.let { f -> runCatching { BeatGridSidecar.parse(f.readText()) }.getOrNull() }

    /** BURN (download once, validate first) the per-beat sidecar, then parse it. */
    suspend fun burnBeatGrid(songId: String): BeatGridSidecar? {
        localBeatGrid(songId)?.let { return it }
        val url = rips.beatgridUrl(songId) ?: return null
        val dir = folder.activeWritable()?.dir ?: return null
        return try {
            val data = rips.downloadBytes(url)
            val parsed = BeatGridSidecar.parse(String(data, Charsets.UTF_8)) ?: return null
            writeAtomic(File(dir, BurnFileNames.beatgridFileName(songId)), data)
            parsed
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
    }

    // ---- adoption of a streamed whole file ----------------------------------------------------

    /**
     * MIX STREAMING: a deck streamed this song's mp3 to completion — land it as a normal `.ready`
     * burn instead of downloading again. Returns the adopted audio file or null (already burned,
     * not in the manifest, no writable folder, empty file).
     */
    fun adoptStreamedFile(songId: String, title: String, artist: String, from: File): File? {
        val entry = rips.entry(songId) ?: return null
        if (_items.value[songId]?.state == BurnState.READY && localUrl(songId) != null) return null
        // A burn run is writing files right now (possibly this very audio path): don't race it.
        // The streamed file stays in the cache and plays from there.
        // TODO(SVC-3): wire yieldBackgroundDownload so the background burn skips this song instead.
        if (runLock.isLocked) return null
        val root = folder.activeWritable() ?: return null
        val size = from.takeIf { it.isFile }?.length() ?: return null
        if (size <= 0) return null
        val (s, a) = catalogFor(songId)
        val names = BurnFileNames.fileNames(songId, entry, s, a)
        val audio = File(root.dir, names.audio)
        return try {
            val analogShared = entry.source == "analog" && audio.exists()
            if (!analogShared) {
                if (audio.exists()) audio.delete()
                moveFile(from, audio)
            }
            writeAtomic(File(root.dir, names.sidecar), BurnSidecar.build(songId, BurnSong(songId, title, artist), s, a, entry).toByteArray())
            val prev = _items.value[songId]
            setItem(
                BurnItem(
                    songId = songId, title = title, artist = artist,
                    audioFileName = names.audio, sidecarFileName = names.sidecar,
                    source = entry.source ?: "digital",
                    bpm = entry.bpm, musicalKey = entry.musicalKey, camelot = entry.camelot,
                    durationMs = entry.durationMs,
                    startMs = if (entry.source == "analog") entry.startMs else null,
                    bytes = size, rippedAt = entry.rippedAt, downloadedAt = now,
                    state = BurnState.READY, wasAppStorage = !root.isUserFolder,
                    cutFileName = prev?.cutFileName, cutDownloadedAt = prev?.cutDownloadedAt,
                ),
            )
            save()
            onAnyBurnFinalized?.invoke(songId, size)
            audio
        } catch (_: Exception) {
            null
        }
    }

    // ---- removal / usage / eviction -----------------------------------------------------------

    val totalBytes: Long get() = _items.value.values.filter { it.state == BurnState.READY }.sumOf { it.bytes }

    val readyBurnedIds: Set<String>
        get() = _items.value.values.filter { it.state == BurnState.READY }.map { it.songId }.toSet()

    fun readyBurnedIds(ids: List<String>): List<String> = ids.filter { _items.value[it]?.state == BurnState.READY }

    fun remove(songId: String) = removeBurns(listOf(songId))

    /**
     * Remove a batch: audio (the shared analog album mp3 survives while any SURVIVING or SKIPPED
     * item references it), sidecar, per-song cut, stems and beat grid; then drop the ledger
     * entries and save ONCE. Items whose dir is unreachable are skipped entirely.
     */
    fun removeBurns(songIds: List<String>) {
        val snapshot = _items.value
        val requested = songIds.toSet().filter { snapshot[it] != null }
        if (requested.isEmpty()) return
        val goners = LinkedHashMap<String, File>()
        for (id in requested) {
            val dir = itemDir(snapshot.getValue(id)) ?: continue
            goners[id] = dir
        }
        if (goners.isEmpty()) return
        val survivorAudio = snapshot.values.filter { it.songId !in goners }.map { it.audioFileName }.toSet()
        val listings = HashMap<String, List<String>>()
        for ((id, dir) in goners) {
            val item = snapshot.getValue(id)
            if (item.audioFileName.isNotEmpty() && item.audioFileName !in survivorAudio) File(dir, item.audioFileName).delete()
            if (item.sidecarFileName.isNotEmpty()) File(dir, item.sidecarFileName).delete()
            resolveCutFileName(item, dir, listing = { listings.getOrPut(dir.path) { listNames(dir) } }, heal = false)
                ?.let { File(dir, it).delete() }
            removeAuxFiles(id)
        }
        dropItems(goners.keys)
        save()
    }

    /** Remove EVERY burn, then sweep aux leftovers (stems for never-burned songs). */
    fun removeAllBurns() {
        requestStop()
        removeBurns(_items.value.keys.toList())
        sweepAuxFiles { true }
    }

    private fun sweepAuxFiles(shouldSweep: (String) -> Boolean) {
        for (r in folder.roots()) {
            for (n in BurnStems.auxToSweep(listNames(r.dir), shouldSweep)) {
                if (ownsAux(n, r.isUserFolder)) File(r.dir, n).delete()
            }
        }
    }

    /** Prune pre-pass: aux files for songs with NO ledger entry (auditioned-but-never-burned). */
    fun sweepOrphanAuxFiles() = sweepAuxFiles { _items.value[it] == null }

    private fun removeAuxFiles(songId: String) {
        for (r in folder.roots()) {
            BurnStems.removeAux(r.dir, songId)
        }
    }

    /** Total on-disk bytes of burned media (audio + sidecars + cuts + stems + grids), owned files only. */
    fun burnedUsageBytes(): Long =
        EvictionPlanner.usageBytes(_items.value.values, snapshots(), ::ownsAux)

    /** ONE scan per root; deletes nothing. */
    fun planEviction(order: List<String>, capBytes: Long, capSongs: Int): EvictionPlan =
        EvictionPlanner.plan(_items.value, snapshots(), order, capBytes, capSongs, ::ownsAux)

    private fun uniqueAudioBytes(group: Collection<BurnItem>): Long {
        val seen = HashSet<String>()
        var total = 0L
        for (it in group) if (it.audioFileName.isNotEmpty() && seen.add(it.audioFileName)) total += it.bytes
        return total
    }

    private fun artistKey(it: BurnItem) = it.artist.ifEmpty { "Unknown artist" }

    /** Ready burns grouped by artist, unique audio files counted once, sorted by artist. */
    fun usageByArtist(): List<ArtistUsage> =
        _items.value.values.filter { it.state == BurnState.READY }.groupBy(::artistKey).map { (artist, g) ->
            ArtistUsage(artist, g.map { it.songId }.sorted(), uniqueAudioBytes(g))
        }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.artist })

    fun approximateBytes(ids: List<String>): Long =
        uniqueAudioBytes(ids.mapNotNull { _items.value[it] }.filter { it.state == BurnState.READY })

    // ---- stem usage / cleanup -----------------------------------------------------------------

    private fun stemBytesMatching(include: (String) -> Boolean): Long {
        var total = 0L
        for (r in folder.roots()) for (f in r.dir.listFiles().orEmpty()) {
            if (!f.isFile || !BurnFileNames.isStemFile(f.name) || !ownsAux(f.name, r.isUserFolder)) continue
            val id = BurnFileNames.auxFileSongId(f.name) ?: continue
            if (include(id)) total += f.length()
        }
        return total
    }

    fun stemUsageBytes(): Long = stemBytesMatching { true }

    fun stemUsageByArtist(): List<ArtistUsage> =
        _items.value.values.filter { it.state == BurnState.READY }.groupBy(::artistKey).mapNotNull { (artist, g) ->
            val ids = g.map { it.songId }
            val want = ids.toSet()
            val bytes = stemBytesMatching { it in want }
            if (bytes > 0) ArtistUsage(artist, ids.sorted(), bytes) else null
        }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.artist })

    /** Delete every owned stem file (beat grids stay); [protecting] = songs loaded in a live player. */
    fun removeAllStems(protecting: Set<String> = emptySet()) {
        for (r in folder.roots()) for (f in r.dir.listFiles().orEmpty()) {
            if (!f.isFile || !BurnFileNames.isStemFile(f.name) || !ownsAux(f.name, r.isUserFolder)) continue
            if (BurnFileNames.auxFileSongId(f.name) in protecting) continue
            f.delete()
        }
    }

    fun removeStems(songIds: List<String>, protecting: Set<String> = emptySet()) {
        for (r in folder.roots()) for (id in songIds) {
            if (id in protecting) continue
            for (p in BurnFileNames.STEM_NAMES) File(r.dir, BurnFileNames.stemFileName(id, p)).delete()
        }
    }

    // ---- reconcile / orphan adoption ----------------------------------------------------------

    // ---- background transfers (SVC-3) ---------------------------------------------------------

    /** A worker finished the files: upsert the `.ready` item (iOS `onBurnFinalized`). */
    private fun finalizeTransfer(r: TransferRecord, bytes: Long) {
        val prev = _items.value[r.songId]
        setItem(
            BurnItem(
                songId = r.songId, title = r.title, artist = r.artist,
                audioFileName = r.audioFileName, sidecarFileName = r.sidecarFileName,
                source = r.source, bpm = r.bpm, musicalKey = r.musicalKey, camelot = r.camelot,
                durationMs = r.durationMs, startMs = if (r.source == "analog") r.startMs else null,
                bytes = bytes, rippedAt = r.rippedAt, downloadedAt = now,
                state = BurnState.READY, error = null, wasAppStorage = r.wasAppStorage,
                cutFileName = prev?.cutFileName, cutDownloadedAt = prev?.cutDownloadedAt,
            ),
        )
        save()
        onAnyBurnFinalized?.invoke(r.songId, bytes)
    }

    /** A worker failed terminally: the row shows the error, never a poisoned `.ready`. */
    private fun failTransfer(r: TransferRecord, message: String) {
        setItem(errorItem(BurnSong(r.songId, r.title, r.artist), message))
        save()
    }

    /**
     * Run AFTER `transfers.reconcileOnLaunch()`. A `.downloading` row with no live transfer record
     * either finished on disk while we were dead (promote to `.ready`) or was lost (error row).
     */
    fun healStrandedDownloads(): Int {
        val t = transfers ?: return 0
        val live = t.records.map { it.songId }.toSet()
        var healed = 0
        for (item in _items.value.values.toList()) {
            if (item.state != BurnState.DOWNLOADING || item.songId in live) continue
            val f = itemDir(item)?.let { File(it, item.audioFileName) }
            if (item.audioFileName.isNotEmpty() && f != null && f.isFile && f.length() > 0 && !BurnReconciler.isPoisoned(f)) {
                patchItem(item.songId) { it.copy(state = BurnState.READY, bytes = f.length(), error = null) }
            } else {
                setItem(errorItem(BurnSong(item.songId, item.title, item.artist), "download interrupted"))
            }
            healed += 1
        }
        if (healed > 0) save()
        return healed
    }

    /** Stop for background transfers: cancel work, drop records, drop their half-done rows. */
    fun cancelTransfers(songIds: Collection<String>) {
        val t = transfers ?: return
        t.cancel(songIds)
        for (id in songIds) {
            if (_items.value[id]?.state == BurnState.DOWNLOADING) dropItems(listOf(id))
        }
        save()
    }

    /** Drop items whose file vanished; delete+drop poisoned <4 KB XML/HTML "audio". Call at launch. */
    fun reconcileOnLaunch() {
        val out = BurnReconciler.reconcile(_items.value.values, ::itemDir)
        if (out.dropped.isNotEmpty()) {
            dropItems(out.dropped)
            save()
        }
    }

    /** Rebuild ledger entries for files in the app root with no ledger record (disaster recovery). */
    fun adoptOrphanedBurns(): Int {
        val dir = folder.roots().firstOrNull { !it.isUserFolder }?.dir ?: return 0
        val names = dir.list()?.toList() ?: return 0
        val audioBySuffix = LinkedHashMap<String, String>()
        for (n in names.sorted()) {
            if ((n.endsWith(".mp3") || n.endsWith(".wav")) && !n.startsWith("stem-")) {
                audioBySuffix.putIfAbsent(BurnFileNames.stableIdSuffix(n.substringBeforeLast('.')), n)
            }
        }
        val claimed = _items.value.values.map { it.sidecarFileName }.toSet()
        var adopted = 0
        for (name in names.sorted()) {
            if (!name.endsWith(".txt") || name in claimed) continue
            val songId = BurnFileNames.stableIdSuffix(name.removeSuffix(".txt"))
            if (songId.isEmpty() || _items.value[songId] != null) continue
            val text = runCatching { File(dir, name).readText() }.getOrNull() ?: continue
            val parsed = BurnSidecar.parseForAdoption(text)
            val entry = parsed.entry
            val source = entry?.source ?: "digital"
            var audioName: String? = null
            var cutName: String? = null
            if (source == "analog" && entry != null) {
                val albumToken = entry.key.substringAfterLast('/').substringBeforeLast('.')
                if (albumToken.isNotEmpty()) audioName = audioBySuffix[albumToken]
                if (audioBySuffix[songId] != audioName) cutName = audioBySuffix[songId]
            } else {
                audioName = audioBySuffix[songId]
            }
            if (audioName == null) continue
            val f = File(dir, audioName)
            val bytes = f.length()
            if (bytes <= 0) continue
            val downloadedMs = f.lastModified().takeIf { it > 0 }?.toDouble() ?: now
            setItem(
                BurnItem(
                    songId = songId, title = parsed.title ?: songId, artist = parsed.artist ?: "",
                    audioFileName = audioName, sidecarFileName = name, source = source,
                    bpm = entry?.bpm, musicalKey = entry?.musicalKey, camelot = entry?.camelot,
                    durationMs = entry?.durationMs,
                    startMs = if (source == "analog") entry?.startMs else null,
                    bytes = bytes, rippedAt = entry?.rippedAt, downloadedAt = downloadedMs,
                    state = BurnState.READY, wasAppStorage = true,
                    cutFileName = cutName, cutDownloadedAt = if (cutName == null) null else downloadedMs,
                ),
            )
            adopted += 1
        }
        if (adopted > 0) save()
        return adopted
    }

    // ---- pendingAfterRip ----------------------------------------------------------------------

    /** Remember the intent durably; the rip runs elsewhere and [drainPendingAfterRip] finishes it. */
    fun burnWhenRipped(songId: String, title: String, artist: String, nowMs: Double = now) {
        if (_pending.value.containsKey(songId)) return
        _pending.update { it + (songId to PendingBurn(songId, title, artist, nowMs)) }
        save()
    }

    fun cancelPendingBurn(songId: String) {
        if (!_pending.value.containsKey(songId)) return
        _pending.update { it - songId }
        save()
    }

    fun isAwaitingBurn(songId: String) = _pending.value.containsKey(songId)

    /**
     * Burn every pending song whose rip has landed. An intent is cleared ONLY when `burned > 0`
     * (a transient failure keeps it queued for the next drain). Returns songs burned.
     */
    suspend fun drainPendingAfterRip(): Int {
        val ready = _pending.value.values.filter { rips.entry(it.songId) != null }
        if (ready.isEmpty()) return 0
        var burned = 0
        for (p in ready) {
            val r = burn(listOf(BurnSong(p.songId, p.title, p.artist)))
            if (r.burned > 0) {
                _pending.update { it - p.songId }
                burned += 1
            }
        }
        save()
        return burned
    }
}

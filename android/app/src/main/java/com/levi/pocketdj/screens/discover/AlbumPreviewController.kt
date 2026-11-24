package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.applemusic.AppleMusicAlbumRef
import com.levi.pocketdj.data.discover.DiscoverAddState
import com.levi.pocketdj.data.recs.AlbumOwnership
import com.levi.pocketdj.data.rips.RipJob
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

// ============================================================================================
// Pure decisions (iOS AlbumPreviewView.swift: AlbumDownloadState / AlbumPreviewUnavailable)
// ============================================================================================

/**
 * How far the SEPARATE "Download to device" request has got. The add button captures nothing, so this is the only way
 * to get an added album's audio onto the device and it must REPORT, not fire and go quiet.
 */
sealed interface AlbumDownloadState {
    data object Idle : AlbumDownloadState
    data class Working(val done: Int, val total: Int) : AlbumDownloadState
    data class Done(val total: Int) : AlbumDownloadState

    /** Settled with at least one track that will never land; [message] is the first failure. */
    data class Failed(val done: Int, val total: Int, val message: String) : AlbumDownloadState

    val label: String
        get() = when (this) {
            Idle -> "Download to device"
            is Working -> "Downloading… $done/$total"
            is Done -> "On this device"
            is Failed -> if (done == 0) message else "$done/$total downloaded — $message"
        }

    /** Only a settled state may be tapped again (idle starts, a failure retries what never landed). */
    val isTappable: Boolean get() = this == Idle || this is Failed

    companion object {
        /** [onDevice] = tracks whose burned file is present; [errors] = per-track failure messages. */
        fun of(ids: List<String>, onDevice: Set<String>, errors: Map<String, String>): AlbumDownloadState {
            if (ids.isEmpty()) return Idle
            val done = ids.count { it in onDevice }
            if (done >= ids.size) return Done(ids.size)
            val failures = ids.filter { it !in onDevice }.mapNotNull { errors[it] }
            if (done + failures.size >= ids.size) return Failed(done, ids.size, failures[0])
            return Working(done, ids.size)
        }
    }
}

/** Why a preview has nothing to show - never just an empty screen. */
enum class AlbumPreviewUnavailable(val title: String, val message: String) {
    Offline("You’re offline", "Connect to load this album’s track list."),
    NoServer("No import server configured", "Add one in Settings ▸ Import server, or sign in to Apple Music."),
    NotFound("Not in the Apple Music catalog", "We couldn’t find this album’s track list.");

    companion object {
        fun reason(isOffline: Boolean, hasServer: Boolean, canUseMusicKit: Boolean): AlbumPreviewUnavailable = when {
            isOffline -> Offline
            !hasServer && !canUseMusicKit -> NoServer
            else -> NotFound
        }
    }
}

/** What the big capsule at the top of the page shows. Decided ONLY from [AlbumOwnership] + the recorded add. */
sealed interface AlbumAddMode {
    /** Not owned (or part-owned): the add button, titled by [AlbumOwnership.addTitle]. */
    data class Add(val title: String) : AlbumAddMode

    /** Fully owned (or the catalog holds the album and no tracklist expanded). */
    data object Owned : AlbumAddMode

    /** An add was recorded: live n/m or settled. */
    data class Recorded(val state: DiscoverAddState) : AlbumAddMode
}

object AlbumPreviewPresentation {
    fun addMode(
        ownership: AlbumOwnership,
        recorded: DiscoverAddState?,
        catalogHasAlbum: Boolean,
        tracksEmpty: Boolean,
    ): AlbumAddMode = when {
        recorded != null -> AlbumAddMode.Recorded(recorded)
        ownership.isFullyOwned || (catalogHasAlbum && tracksEmpty) -> AlbumAddMode.Owned
        else -> AlbumAddMode.Add(ownership.addTitle)
    }

    /** "Open album" appears whenever the catalog already has this album AND the screen can navigate. */
    fun showOpenAlbum(catalogAlbumId: String?): Boolean = catalogAlbumId != null

    /** m:ss, h:mm:ss past an hour; "" for nothing. */
    fun runtime(seconds: Double): String {
        if (!seconds.isFinite() || seconds <= 0) return ""
        val s = Math.round(seconds).toInt()
        val h = s / 3600
        val m = (s % 3600) / 60
        val r = s % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, r) else "%d:%02d".format(m, r)
    }
}

// ============================================================================================
// Data
// ============================================================================================

/** One tracklist row. */
data class AlbumTrackRow(
    val storeId: String,
    val title: String,
    val artist: String,
    val trackNumber: Int? = null,
    val discNumber: Int? = null,
    val durationMs: Int? = null,
)

/** The three tiers' answer: the album (enriched), its tracks, and the named reason when there are none. */
data class AlbumPreviewLoad(
    val album: AppleMusicAlbumRef,
    val tracks: List<AlbumTrackRow>,
    val unavailable: AlbumPreviewUnavailable? = null,
)

/** The three id sets [AlbumOwnership] decides from. */
data class OwnedSets(
    val catalogSongIds: Set<String> = emptySet(),
    val catalogAppleMusicIds: Set<String> = emptySet(),
    val rippedSongIds: Set<String> = emptySet(),
    /** store id -> the catalog song claiming it (burn ids reuse the indexed id). NOT part of the ownership decision. */
    val catalogSongIdByStoreId: Map<String, String> = emptyMap(),
) {
    fun ownershipOf(tracks: List<AlbumTrackRow>): AlbumOwnership =
        AlbumOwnership.of(tracks.map { it.storeId }, catalogSongIds, catalogAppleMusicIds, rippedSongIds)

    fun owns(storeId: String): Boolean =
        AlbumOwnership.owns(storeId, catalogSongIds, catalogAppleMusicIds, rippedSongIds)
}

/** One track of a Download request. */
data class DownloadTrack(val songId: String, val title: String, val artist: String, val storeId: String, val lengthMs: Int?)

/** The album data + library-write half. Production adapter lives in [AlbumPreviewHolder]. */
interface AlbumPreviewPort {
    suspend fun hasServer(): Boolean
    suspend fun canAddToLibrary(): Boolean
    suspend fun isOffline(): Boolean = false

    /** Tier 1: catalog REST tracklist (developer token only). Empty on any failure. */
    suspend fun catalogTracks(albumStoreId: String): List<DiscoverAlbumTrack>

    /** Tier 2: the subscription-free `/album-tracks` proxy. */
    suspend fun expansion(albumStoreId: String): DiscoverAlbumExpansion

    /** Library-only album add (the add captures NOTHING; audio comes down via Download). */
    suspend fun addAlbum(hit: DiscoverAlbumHit): DiscoverAddOutcome
}

/** The rip+burn half. One call per tick polls ALL outstanding jobs (see [AlbumPreviewController]). */
interface AlbumDownloadPort {
    suspend fun configured(): Boolean

    /** Registers the burn-when-ripped intent, then POST /rip. Null = the request could not be made. */
    suspend fun request(track: DownloadTrack): RipJob?
    suspend fun fetchJob(jobId: String): RipJob?

    /** After one or more rips landed: refresh the manifest once and run the pending burns. */
    suspend fun ripsLanded(songIds: List<String>)
    fun onDevice(songId: String): Boolean
    fun burnError(songId: String): String?
}

data class AlbumAddUi(val adding: Boolean = false, val error: String? = null)

// ============================================================================================
// Store-owned controller
// ============================================================================================

/**
 * App-scoped album-page work (iOS keeps it store-owned so dismissing the screen cancels nothing):
 *  - the library-only add,
 *  - Download = rip + burn, driven by ONE shared poll loop for every album at once. The ripper is concurrency-1, so
 *    polling per track (or per album) multiplies requests for no faster result: requests go out in order, then a
 *    single loop fetches each outstanding job per tick and settles tracks as they land.
 * [scope] must outlive the UI.
 */
class AlbumPreviewController(
    private val scope: CoroutineScope,
    private val port: AlbumPreviewPort,
    private val downloadPort: AlbumDownloadPort,
    private val pollMs: Long = 2_000,
    private val maxTicks: Int = 1_800,
) {
    private val _downloads = MutableStateFlow<Map<String, AlbumDownloadState>>(emptyMap())
    val downloads: StateFlow<Map<String, AlbumDownloadState>> = _downloads.asStateFlow()

    private val _adds = MutableStateFlow<Map<String, AlbumAddUi>>(emptyMap())
    val adds: StateFlow<Map<String, AlbumAddUi>> = _adds.asStateFlow()

    private class Active(val ids: List<String>) {
        /** songId -> jobId still being waited on. */
        val pending = HashMap<String, String>()
        val errors = HashMap<String, String>()
    }

    private val lock = Mutex()
    private val active = HashMap<String, Active>()
    private var loop: Job? = null

    /** Guarded by [lock]: true from the moment a loop is committed until it decides to exit (no stranded album). */
    @Volatile private var loopRunning = false

    /** How many poll loops were ever started (the invariant: one at a time). */
    @Volatile var loopStarts: Int = 0
        private set

    // ---- load ---------------------------------------------------------------------------------

    /** Tier 1 catalog REST -> tier 2 `/album-tracks` -> tier 3 a named reason. Never throws. */
    suspend fun load(ref: AppleMusicAlbumRef): AlbumPreviewLoad {
        var album = ref
        val needsMeta = album.title.isEmpty() || album.title == "Album" || album.artist.isEmpty()
        val t1 = safe { port.catalogTracks(ref.storeId) }.orEmpty()
        var expansion: DiscoverAlbumExpansion? = null
        if (needsMeta || t1.isEmpty()) {
            expansion = safe { port.expansion(ref.storeId) }
            expansion?.album?.let { s ->
                if (needsMeta) {
                    album = album.copy(
                        title = s.title.ifEmpty { album.title }, artist = s.artist.ifEmpty { album.artist },
                        year = album.year ?: s.year, artworkUrl = album.artworkUrl ?: s.artworkUrl, url = album.url ?: s.url,
                    )
                }
            }
        }
        val rows = t1.ifEmpty { expansion?.tracks.orEmpty() }
        if (rows.isNotEmpty()) return AlbumPreviewLoad(album, rows.map { it.toRow() })
        val server = safe { port.hasServer() } ?: false
        val reason = AlbumPreviewUnavailable.reason(
            isOffline = safe { port.isOffline() } ?: false, hasServer = server, canUseMusicKit = false,
        )
        return AlbumPreviewLoad(album, emptyList(), reason)
    }

    private fun DiscoverAlbumTrack.toRow() = AlbumTrackRow(id, title, artist, trackNumber, discNumber, durationMs)

    private suspend fun <T> safe(f: suspend () -> T): T? = try {
        f()
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    // ---- add ----------------------------------------------------------------------------------

    /** The giant plus: the library-only whole-album add. Single-flight per album; survives the screen closing. */
    fun addAlbum(hit: DiscoverAlbumHit): Job? {
        val key = hit.appleMusicId
        if (_adds.value[key]?.adding == true) return null
        _adds.update { it + (key to AlbumAddUi(adding = true)) }
        return scope.launch {
            val result = try {
                port.addAlbum(hit)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                DiscoverAddOutcome(false, LibraryWrite.failed(e.message ?: "error"), e.message ?: DiscoverAddWording.ADD_FAILED)
            }
            _adds.update { it + (key to AlbumAddUi(adding = false, error = if (result.accepted) null else result.error)) }
        }
    }

    // ---- download -----------------------------------------------------------------------------

    /**
     * Request every track in order, then let the ONE shared loop settle them. A second tap while the album is working
     * is a no-op; a failed album retries only the tracks that never landed.
     */
    fun download(albumKey: String, tracks: List<DownloadTrack>): Job? {
        if (tracks.isEmpty()) return null
        val ids = tracks.map { it.songId }
        val current = _downloads.value[albumKey]
        if (current is AlbumDownloadState.Working) return null
        _downloads.update { it + (albumKey to AlbumDownloadState.Working(ids.count { id -> downloadPort.onDevice(id) }, ids.size)) }
        return scope.launch {
            val a = Active(ids)
            lock.withLock { active[albumKey] = a }
            val landedNow = ArrayList<String>()
            for (t in tracks) {
                if (downloadPort.onDevice(t.songId)) continue
                val job = try {
                    downloadPort.request(t)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    null
                }
                lock.withLock {
                    when {
                        job == null -> a.errors[t.songId] = "Couldn’t request a copy"
                        job.phase == RipJob.PHASE_ERROR -> a.errors[t.songId] = job.error ?: job.message ?: "Couldn’t prepare a copy"
                        // Already ripped server-side: nothing to wait on, only the burn to run.
                        job.isReady -> landedNow += t.songId
                        else -> a.pending[t.songId] = job.jobId ?: ""
                    }
                }
            }
            if (landedNow.isNotEmpty()) runCatching { downloadPort.ripsLanded(landedNow) }
            publish(albumKey)
            ensureLoop()
        }
    }

    private suspend fun publish(albumKey: String) = lock.withLock { publishLocked(albumKey) }

    private fun publishLocked(albumKey: String) {
        val a = active[albumKey] ?: return
        val onDevice = a.ids.filter { downloadPort.onDevice(it) }.toSet()
        val errors = HashMap<String, String>(a.errors)
        for (id in a.ids) if (id !in onDevice) downloadPort.burnError(id)?.let { errors.putIfAbsent(id, it) }
        val state = AlbumDownloadState.of(a.ids, onDevice, errors)
        _downloads.update { it + (albumKey to state) }
        if (state is AlbumDownloadState.Done || state is AlbumDownloadState.Failed) active.remove(albumKey)
    }

    /** Starts the single loop unless one is already running. */
    private suspend fun ensureLoop() = lock.withLock {
        if (loopRunning) return@withLock
        loopRunning = true
        loopStarts++
        loop = scope.launch { runLoop() }
    }

    /** Exit decision under the lock, so a download registered at this instant either sees the loop or starts one. */
    private suspend fun exitIfIdle(): Boolean = lock.withLock {
        if (active.isEmpty()) { loopRunning = false; true } else false
    }

    private suspend fun runLoop() {
        try {
            loopBody()
        } finally {
            loopRunning = false
        }
    }

    private suspend fun loopBody() {
        var ticks = 0
        while (ticks++ < maxTicks) {
            delay(pollMs)
            val snapshot = lock.withLock { active.entries.map { it.key to it.value } }
            if (snapshot.isEmpty()) { if (exitIfIdle()) return else continue }
            val landed = ArrayList<String>()
            for ((_, a) in snapshot) {
                val pending = lock.withLock { a.pending.entries.map { it.key to it.value } }
                for ((songId, jobId) in pending) {
                    val view = try {
                        if (jobId.isEmpty()) null else downloadPort.fetchJob(jobId)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        null
                    } ?: continue // a missed poll is transient
                    when {
                        view.isReady -> { lock.withLock { a.pending.remove(songId) }; landed += songId }
                        view.phase == RipJob.PHASE_ERROR -> lock.withLock {
                            // Settled for THIS album: the user retries with Download. (Polling an auto-healing job
                            // forever would never let the capsule settle.)
                            a.pending.remove(songId)
                            a.errors[songId] = view.error ?: view.message ?: "Couldn’t prepare a copy"
                        }
                    }
                }
            }
            if (landed.isNotEmpty()) runCatching { downloadPort.ripsLanded(landed) }
            val keys = lock.withLock { active.keys.toList() }
            for (k in keys) publish(k)
            if (exitIfIdle()) return
        }
        // Cap reached: settle whatever is left as failed rather than spin forever.
        val keys = lock.withLock { active.keys.toList() }
        lock.withLock {
            for (k in keys) active[k]?.let { a -> for (id in a.pending.keys.toList()) a.errors[id] = "Timed out waiting for the copy" }
        }
        for (k in keys) publish(k)
    }
}

// ============================================================================================
// Navigation seam: recognizer / For You / Discover all open the same page
// ============================================================================================

/**
 * Process-wide "open this store album" request. The recognizer sheet, the New releases rows and Discover album taps
 * emit here; the shell collects it and pushes the in-app album page (no more open-the-Apple-Music-app fallback).
 */
object StoreAlbumRouter {
    private val _events = MutableSharedFlow<AppleMusicAlbumRef>(extraBufferCapacity = 8)
    val events: SharedFlow<AppleMusicAlbumRef> = _events.asSharedFlow()

    /** False when nothing could be queued (never happens with the buffer; kept honest for callers/tests). */
    fun open(ref: AppleMusicAlbumRef): Boolean = ref.storeId.isNotBlank() && _events.tryEmit(ref)

    /** A bare Discover album hit. */
    fun open(hit: DiscoverAlbumHit): Boolean = open(
        AppleMusicAlbumRef(hit.appleMusicId, hit.title, hit.artist, hit.year, hit.artworkUrl, hit.url),
    )
}

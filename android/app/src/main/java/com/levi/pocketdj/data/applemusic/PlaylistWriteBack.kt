package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/**
 * The WRITE half of two-way collection sync (iOS `PlaylistWriteBack`). Every add to a source
 * playlist lands (a) in the on-device duplicate immediately and (b) in the REAL Apple Music
 * library playlist as soon as the Web API will take it.
 *
 * DURABLE QUEUE, not fire-and-forget: the write can fail for reasons unrelated to the user's
 * intent (offline, signed out), and the add has ALREADY happened locally. The intent is persisted
 * first and drained later. Its OWN document (`pocketdj-playlist-writeback.json`, iOS-shape),
 * DEVICE-LOCAL and never cloud-synced - syncing it would replay a delivered write on a peer.
 *
 * THE SAFETY PROPERTY: nothing here writes the new song into the collection's `sourceSongIds`.
 * That snapshot only advances from a real catalog refresh, i.e. after Apple Music confirms.
 */
class PlaylistWriteBack(
    private val file: File,
    @Volatile var transport: PlaylistWriteBackTransport? = null,
    private val scope: CoroutineScope? = null,
    private val now: () -> Double = { System.currentTimeMillis().toDouble() },
    private val newJobId: () -> String = { "wbj_" + UUID.randomUUID().toString() },
    private val writer: VersionedJsonWriter = VersionedJsonWriter(file),
) {
    /** Terminal-state machine; QUEUED is the only non-terminal state. Wire tokens are the iOS raw values. */
    @Serializable
    enum class JobState {
        @SerialName("queued") QUEUED,
        @SerialName("delivered") DELIVERED,
        @SerialName("notApplicable") NOT_APPLICABLE,
        @SerialName("failed") FAILED,
        @SerialName("unresolvable") UNRESOLVABLE,
        ;

        val token: String
            get() = when (this) {
                QUEUED -> "queued"; DELIVERED -> "delivered"; NOT_APPLICABLE -> "notApplicable"
                FAILED -> "failed"; UNRESOLVABLE -> "unresolvable"
            }

        companion object {
            fun fromToken(t: String?): JobState = entries.firstOrNull { it.token == t } ?: QUEUED
        }
    }

    /** One owed write: "this song belongs in that Apple Music playlist". */
    @Serializable
    data class Job(
        val id: String,
        val indexPlaylistId: String,
        /** Only the BOOTSTRAP key: resolved ONCE to a stable library-playlist id. */
        val playlistName: String,
        val songId: String,
        val appleMusicId: String,
        val title: String = "",
        val artist: String = "",
        val album: String? = null,
        val durationMs: Int? = null,
        val queuedAtMs: Double,
        val attempts: Int = 0,
        val lastError: String? = null,
        val state: JobState = JobState.QUEUED,
        /** Backoff gate - not retried before this instant. null = eligible now. */
        val nextAttemptAtMs: Double? = null,
        val settledAtMs: Double? = null,
        val musicKitPlaylistId: String? = null,
        /** How the playlist was resolved when the answer wasn't obvious. */
        val resolutionNote: String? = null,
    )

    /** One song owed to one playlist - `enqueue`'s parameters as data, for the batch path. */
    data class EnqueueItem(
        val indexPlaylistId: String,
        val playlistName: String,
        val songId: String,
        val appleMusicId: String?,
        val title: String,
        val artist: String,
        val album: String? = null,
        val durationMs: Int? = null,
    )

    /** Observable snapshot for the Settings screen. */
    data class State(
        val jobs: List<Job> = emptyList(),
        val resolvedPlaylistIds: Map<String, String> = emptyMap(),
        val isRunning: Boolean = false,
        /** Most recent delivery failure; cleared on a clean drain. */
        val lastError: String? = null,
        /** A resolution the transport had to GUESS at; survives the clean-drain reset. */
        val resolutionWarning: String? = null,
    ) {
        val pending: List<Job> get() = jobs.filter { it.state == JobState.QUEUED }
        val failed: List<Job> get() = jobs.filter { it.state == JobState.FAILED }
    }

    @Serializable
    private data class Document(
        val schemaVersion: Int = 1,
        val jobs: List<Job> = emptyList(),
        val resolvedPlaylistIds: Map<String, String>? = null,
    )

    private val lock = Any()
    private val _state: MutableStateFlow<State>
    val state: StateFlow<State>
    private var version = 0L
    private val running = AtomicBoolean(false)
    @Volatile private var unsyncableMemo: Pair<List<Job>, Set<String>>? = null

    /** Catalog seam for the playlist JOIN tie-break: indexPlaylistId -> store ids the INDEX thinks it holds. */
    @Volatile var appleMusicIdsForIndexPlaylist: ((String) -> List<String>)? = null

    init {
        val doc = decode(file)
        _state = MutableStateFlow(State(jobs = doc.first, resolvedPlaylistIds = doc.second))
        state = _state.asStateFlow()
    }

    // ---- Derived -----------------------------------------------------------------

    val jobs: List<Job> get() = _state.value.jobs
    val pending: List<Job> get() = _state.value.pending
    val failed: List<Job> get() = _state.value.failed
    val pendingCount: Int get() = pending.size
    val lastError: String? get() = _state.value.lastError
    val resolutionWarning: String? get() = _state.value.resolutionWarning
    val resolvedPlaylistIds: Map<String, String> get() = _state.value.resolvedPlaylistIds
    val isRunning: Boolean get() = running.get()

    /** Can this build reach Apple Music's library-playlist writes AT ALL (seam wired + supported)? */
    val canWriteBack: Boolean get() = transport?.isSupported ?: false

    // ---- Enqueue -----------------------------------------------------------------

    /**
     * Record an owed write. Returns null (queues NOTHING) when there is no way to write the song
     * upstream - neither a catalog id nor title+artist to resolve one. Also null when an equivalent
     * job is already queued or delivered (so a double-tap can't add it twice), or when a prior
     * TERMINAL `unresolvable` verdict stands and we still carry no store id.
     */
    fun enqueue(
        indexPlaylistId: String,
        playlistName: String,
        songId: String,
        appleMusicId: String?,
        title: String = "",
        artist: String = "",
        album: String? = null,
        durationMs: Int? = null,
    ): Job? = synchronized(lock) {
        val amId = appleMusicId.orEmpty().trim()
        val t = title.trim()
        val ar = artist.trim()
        if (playlistName.isEmpty()) return null
        if (amId.isEmpty() && (t.isEmpty() || ar.isEmpty())) return null
        var list = _state.value.jobs
        val stale = list.indexOfFirst {
            it.indexPlaylistId == indexPlaylistId && it.songId == songId && it.state == JobState.UNRESOLVABLE
        }
        if (stale >= 0) {
            if (amId.isEmpty()) return null
            // We NOW carry a real catalog id: supersede the stale verdict so the song can deliver.
            list = list.filterIndexed { i, _ -> i != stale }
        }
        if (list.any {
                it.indexPlaylistId == indexPlaylistId && it.songId == songId &&
                    (it.state == JobState.QUEUED || it.state == JobState.DELIVERED)
            }
        ) {
            if (stale >= 0) commit(list) // the superseded verdict is gone either way
            return null
        }
        val job = Job(
            id = newJobId(), indexPlaylistId = indexPlaylistId, playlistName = playlistName,
            songId = songId, appleMusicId = amId, title = t, artist = ar, album = album,
            durationMs = durationMs, queuedAtMs = now(),
            musicKitPlaylistId = _state.value.resolvedPlaylistIds[indexPlaylistId],
        )
        commit(prune(list + job))
        job
    }

    /**
     * Batch twin of [enqueue]: identical per-item eligibility + dedup, lookups against Sets built
     * ONCE, prune + save ONCE. Returns the newly queued count.
     */
    fun enqueueMany(items: List<EnqueueItem>): Int = synchronized(lock) {
        if (items.isEmpty()) return 0
        val live = HashSet<String>()
        val unresolvable = HashMap<String, String>()
        for (j in _state.value.jobs) {
            val key = j.indexPlaylistId + "\u0001" + j.songId
            when (j.state) {
                JobState.QUEUED, JobState.DELIVERED -> live += key
                JobState.UNRESOLVABLE -> unresolvable[key] = j.id
                else -> Unit
            }
        }
        val newJobs = ArrayList<Job>()
        val dropIds = HashSet<String>()
        val resolved = _state.value.resolvedPlaylistIds
        for (item in items) {
            val amId = item.appleMusicId.orEmpty().trim()
            val t = item.title.trim()
            val ar = item.artist.trim()
            if (item.playlistName.isEmpty()) continue
            if (amId.isEmpty() && (t.isEmpty() || ar.isEmpty())) continue
            val key = item.indexPlaylistId + "\u0001" + item.songId
            if (key in live) continue // also dedups within the batch
            val stale = unresolvable[key]
            if (stale != null) {
                if (amId.isEmpty()) continue
                dropIds += stale
                unresolvable.remove(key)
            }
            live += key
            newJobs += Job(
                id = newJobId(), indexPlaylistId = item.indexPlaylistId, playlistName = item.playlistName,
                songId = item.songId, appleMusicId = amId, title = t, artist = ar, album = item.album,
                durationMs = item.durationMs, queuedAtMs = now(),
                musicKitPlaylistId = resolved[item.indexPlaylistId],
            )
        }
        if (newJobs.isEmpty() && dropIds.isEmpty()) return 0
        commit(prune(_state.value.jobs.filterNot { it.id in dropIds } + newJobs))
        newJobs.size
    }

    /**
     * A song the queue has DETERMINED can't be backed up (searched, no confident match). Superseded
     * by any later DELIVERED/QUEUED job for the same song. Drives the row's "not backed up" badge.
     */
    fun isUnsyncable(songId: String): Boolean = unsyncableSet().contains(songId)

    private fun unsyncableSet(): Set<String> {
        val jobs = _state.value.jobs
        unsyncableMemo?.let { if (it.first === jobs) return it.second }
        val unresolvable = HashSet<String>()
        val superseded = HashSet<String>()
        for (j in jobs) when (j.state) {
            JobState.UNRESOLVABLE -> unresolvable += j.songId
            JobState.DELIVERED, JobState.QUEUED -> superseded += j.songId
            else -> Unit
        }
        val set = unresolvable - superseded
        unsyncableMemo = jobs to set
        return set
    }

    // ---- Drain -------------------------------------------------------------------

    /** Fire-and-forget drain. Re-entrant-safe: [run] no-ops while a drain is in flight. */
    fun runSoon() {
        val sc = scope ?: return
        if (running.get() || pending.isEmpty()) return
        sc.launch(Dispatchers.IO) { run() }
    }

    /**
     * Deliver every eligible queued job, oldest first. Sequential on purpose - these are library
     * MUTATIONS against one account. The ledger is persisted after EVERY job: the append is not
     * idempotent and not retractable from this app, so a process kill mid-drain must not lose a
     * DELIVERED mark (the next launch would re-deliver and duplicate the track).
     */
    suspend fun run() {
        if (!running.compareAndSet(false, true)) return
        publish { it.copy(isRunning = true) }
        try {
            val t = transport
            if (t == null || !t.isSupported) {
                settleUnsupported()
                return
            }
            // Authorization is something the USER can fix: must not burn an attempt.
            if (!t.canWrite()) {
                publish { it.copy(lastError = "Sign in to Apple Music to finish adding these songs to your Apple Music playlists.") }
                return
            }
            val nowMs = now()
            val due = _state.value.jobs
                .filter { it.state == JobState.QUEUED && (it.nextAttemptAtMs ?: 0.0) <= nowMs }
                .sortedBy { it.queuedAtMs }
                .map { it.id }
            if (due.isEmpty()) return
            var anyFailed = false
            for (id in due) {
                if (!attempt(id, t)) anyFailed = true
            }
            if (!anyFailed) publish { it.copy(lastError = null) }
            synchronized(lock) { commit(prune(_state.value.jobs)) }
        } finally {
            running.set(false)
            publish { it.copy(isRunning = false) }
        }
    }

    /**
     * One delivery attempt; true on success. Never throws (except cancellation) - a stuck job is a
     * recorded state. THE JOIN: use the id already resolved for this playlist, else resolve by name
     * ONCE and remember it. `playlistGone` forgets the id and re-resolves exactly once.
     */
    private suspend fun attempt(jobId: String, t: PlaylistWriteBackTransport): Boolean {
        val job = _state.value.jobs.firstOrNull { it.id == jobId } ?: return true
        try {
            val catalogId: String
            if (job.appleMusicId.isNotEmpty()) {
                catalogId = job.appleMusicId
            } else {
                val identity = WriteBackSong("", job.title, job.artist, job.album, job.durationMs)
                val resolved = t.resolveCatalogId(identity)
                if (!resolved.isNullOrEmpty()) {
                    catalogId = resolved
                    // PERSIST the resolved id BEFORE the non-retractable add, so a crash after the
                    // add re-attempts with THIS id and the pre-check sees it already present.
                    update(jobId) { it.copy(appleMusicId = resolved) }
                } else {
                    update(jobId) {
                        it.copy(
                            attempts = it.attempts + 1, state = JobState.UNRESOLVABLE,
                            nextAttemptAtMs = null, settledAtMs = now(),
                            lastError = "This song isn’t on Apple Music, so it can’t be added to the playlist — it stays in your local copy.",
                        )
                    }
                    return true
                }
            }
            val target = playlistId(job, t)
            try {
                t.addSong(catalogId, target)
            } catch (_: WriteBackException.PlaylistGone) {
                forgetResolution(job.indexPlaylistId)
                val fresh = playlistId(job, t, forceResolve = true)
                t.addSong(catalogId, fresh)
            }
            update(jobId) {
                it.copy(attempts = it.attempts + 1, lastError = null, state = JobState.DELIVERED,
                    nextAttemptAtMs = null, settledAtMs = now())
            }
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val attempts = job.attempts + 1
            val message = e.message ?: e.toString()
            val terminal = attempts >= MAX_ATTEMPTS
            update(jobId) {
                if (terminal) {
                    it.copy(attempts = attempts, lastError = message, state = JobState.FAILED,
                        nextAttemptAtMs = null, settledAtMs = now())
                } else {
                    it.copy(attempts = attempts, lastError = message, nextAttemptAtMs = now() + backoffMs(attempts))
                }
            }
            publish { it.copy(lastError = message) }
            return false
        }
    }

    private suspend fun playlistId(job: Job, t: PlaylistWriteBackTransport, forceResolve: Boolean = false): String {
        if (!forceResolve) {
            _state.value.resolvedPlaylistIds[job.indexPlaylistId]?.let { return it }
            job.musicKitPlaylistId?.takeIf { it.isNotEmpty() }?.let { stored ->
                // The map is device-local and can be lost; the job carries its own copy.
                synchronized(lock) {
                    commit(_state.value.jobs, _state.value.resolvedPlaylistIds + (job.indexPlaylistId to stored))
                }
                return stored
            }
        }
        val sample = appleMusicIdsForIndexPlaylist?.invoke(job.indexPlaylistId).orEmpty().take(DISAMBIGUATION_SAMPLE_LIMIT)
        val resolved = t.resolvePlaylistId(job.playlistName, sample)
            ?: throw WriteBackException.PlaylistNotFound(job.playlistName)
        // A resolution the transport had to GUESS at is recorded on the job AND on resolutionWarning.
        // Deliberately NOT lastError: that clears on a clean drain, which is exactly when a guess survives.
        val note = t.lastResolutionNote
        synchronized(lock) {
            val jobs = _state.value.jobs.map { if (it.id == job.id) it.copy(musicKitPlaylistId = resolved, resolutionNote = note) else it }
            val warning = note ?: if (jobs.any { it.resolutionNote != null }) _state.value.resolutionWarning else null
            commit(jobs, _state.value.resolvedPlaylistIds + (job.indexPlaylistId to resolved), warning = warning)
        }
        return resolved
    }

    /** Drop a stale mapping (map + every job that cached it) so the next attempt starts from the name. */
    private fun forgetResolution(indexPlaylistId: String) = synchronized(lock) {
        commit(
            _state.value.jobs.map { if (it.indexPlaylistId == indexPlaylistId) it.copy(musicKitPlaylistId = null) else it },
            _state.value.resolvedPlaylistIds - indexPlaylistId,
        )
    }

    /** Settle every queued job as "this device can't do that" - terminal. */
    private fun settleUnsupported() = synchronized(lock) {
        val ids = pending.map { it.id }.toSet()
        if (ids.isEmpty()) return
        val t = now()
        commit(prune(_state.value.jobs.map {
            if (it.id in ids) it.copy(
                state = JobState.NOT_APPLICABLE, nextAttemptAtMs = null, settledAtMs = t,
                lastError = "Apple Music playlists can’t be edited from this device — the song was added to your local copy only.",
            ) else it
        }))
    }

    // ---- User actions -------------------------------------------------------------

    /** Re-arm a FAILED job (explicit user retry). */
    fun retry(jobId: String) {
        update(jobId) {
            if (it.state != JobState.FAILED) it
            else it.copy(state = JobState.QUEUED, attempts = 0, lastError = null, nextAttemptAtMs = null, settledAtMs = null)
        }
    }

    fun retryFailed() { failed.forEach { retry(it.id) } }

    /** Forget a job outright (the user gave up on it). */
    fun discard(jobId: String) = synchronized(lock) { commit(_state.value.jobs.filterNot { it.id == jobId }) }

    /**
     * Drop still-UNDELIVERED write-backs (QUEUED / FAILED) for [songIds] owed to [indexPlaylistId].
     * Used when a pocket is RE-LINKED to a different source. DELIVERED jobs are left alone.
     */
    fun cancelPending(indexPlaylistId: String, songIds: Set<String>) = synchronized(lock) {
        val before = _state.value.jobs
        val after = before.filterNot {
            it.indexPlaylistId == indexPlaylistId && it.songId in songIds &&
                (it.state == JobState.QUEUED || it.state == JobState.FAILED)
        }
        if (after.size != before.size) commit(after)
    }

    /** Empty the whole outbound queue and delete its backing document - a full wipe. */
    fun clear() = synchronized(lock) {
        val v = ++version
        _state.update { it.copy(jobs = emptyList(), resolvedPlaylistIds = emptyMap(), lastError = null, resolutionWarning = null) }
        writer.delete(v)
    }

    /** Re-decode after an external write (tests; the document is not cloud-synced). */
    fun reloadFromDisk() = synchronized(lock) {
        val doc = decode(file)
        _state.update { it.copy(jobs = doc.first, resolvedPlaylistIds = doc.second) }
    }

    // ---- Internals -----------------------------------------------------------------

    private fun publish(f: (State) -> State) { _state.update(f) }

    private fun update(jobId: String, body: (Job) -> Job) {
        synchronized(lock) {
            val jobs = _state.value.jobs
            if (jobs.none { it.id == jobId }) return
            commit(jobs.map { if (it.id == jobId) body(it) else it })
        }
    }

    /** Publish + persist (inline, atomic temp-file+rename). */
    private fun commit(
        jobs: List<Job>,
        resolved: Map<String, String> = _state.value.resolvedPlaylistIds,
        warning: String? = _state.value.resolutionWarning,
    ) {
        _state.update { it.copy(jobs = jobs, resolvedPlaylistIds = resolved, resolutionWarning = warning) }
        val v = ++version
        val doc = Document(jobs = jobs, resolvedPlaylistIds = resolved)
        writer.write(v) { PdjJson.lenient.encodeToString(Document.serializer(), doc) }
    }

    /** Settled DELIVERED / NOT_APPLICABLE / UNRESOLVABLE rows age out oldest-first past [HISTORY_LIMIT]. */
    private fun prune(jobs: List<Job>): List<Job> {
        if (jobs.size <= HISTORY_LIMIT) return jobs
        val settled = jobs
            .filter { it.state == JobState.DELIVERED || it.state == JobState.NOT_APPLICABLE || it.state == JobState.UNRESOLVABLE }
            .sortedBy { it.settledAtMs ?: it.queuedAtMs }
        var overflow = jobs.size - HISTORY_LIMIT
        val drop = HashSet<String>()
        for (j in settled) { if (overflow <= 0) break; drop += j.id; overflow-- }
        return if (drop.isEmpty()) jobs else jobs.filterNot { it.id in drop }
    }

    companion object {
        /** Retries before a job settles FAILED. */
        const val MAX_ATTEMPTS = 4
        const val HISTORY_LIMIT = 200
        const val DISAMBIGUATION_SAMPLE_LIMIT = 50
        const val FILE_NAME = "pocketdj-playlist-writeback.json"

        /** Only Apple Music source playlists have a real upstream (both the private + public index). */
        fun isAppleMusicSource(sourceName: String?): Boolean =
            sourceName == "Apple Music (Local)" || sourceName == "Apple Music"

        /** 30 s -> 1 min -> 2 min. */
        fun backoffMs(attempts: Int): Double = 30_000.0 * Math.pow(2.0, maxOf(0, attempts - 1).toDouble())

        /**
         * LENIENT by construction (iOS `Job.init(from:)`): every field falls back to a default so a
         * document from a newer/older build still decodes, per job. A queue that fails to decode is
         * a queue that silently forgets what the user asked for.
         */
        internal fun decode(file: File): Pair<List<Job>, Map<String, String>> {
            val text = runCatching { file.readText() }.getOrNull() ?: return emptyList<Job>() to emptyMap()
            val root = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
                ?: run {
                    runCatching { file.renameTo(File(file.parentFile, file.name + ".bak")) }
                    return emptyList<Job>() to emptyMap()
                }
            val jobs = (root["jobs"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let(::decodeJob) }
            val resolved = (root["resolvedPlaylistIds"] as? JsonObject)?.mapNotNull { (k, v) ->
                (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { k to it }
            }?.toMap().orEmpty()
            return jobs to resolved
        }

        private fun decodeJob(o: JsonObject): Job {
            fun str(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            fun dbl(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
            fun int(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
            return Job(
                id = str("id") ?: ("wbj_" + UUID.randomUUID()),
                indexPlaylistId = str("indexPlaylistId").orEmpty(),
                playlistName = str("playlistName").orEmpty(),
                songId = str("songId").orEmpty(),
                appleMusicId = str("appleMusicId").orEmpty(),
                title = str("title").orEmpty(),
                artist = str("artist").orEmpty(),
                album = str("album"),
                durationMs = int("durationMs"),
                queuedAtMs = dbl("queuedAtMs") ?: 0.0,
                attempts = int("attempts") ?: 0,
                lastError = str("lastError"),
                state = JobState.fromToken(str("state")),
                nextAttemptAtMs = dbl("nextAttemptAtMs"),
                settledAtMs = dbl("settledAtMs"),
                musicKitPlaylistId = str("musicKitPlaylistId"),
                resolutionNote = str("resolutionNote"),
            )
        }
    }
}

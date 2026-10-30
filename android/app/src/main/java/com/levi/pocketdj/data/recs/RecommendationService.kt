package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.config.RemoteEndpoints
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** The key + scoped profile id the sibling first-party service (listening pockets) rides. */
data class RecCredentials(val key: String, val profileId: String, val enrollSecret: String = RemoteEndpoints.recEngineEnroll())

/**
 * The cloud RECOMMENDATION ENGINE orchestrator (iOS `RecommendationService`). While — and ONLY
 * while — [isEnabled] (Settings toggle, default OFF) it batch-uploads deltas derived from the
 * existing stores to the rec engine and serves For You / In Da Zone cloud ranking and the
 * Suggested-collections rows.
 *
 * PRIVACY GATE: every network-touching method guards [isEnabled] first; there is no other path to
 * [RecEngineClient], so toggle-off means literally zero requests (the one carved exception is
 * [retryPendingCloudDelete], which only ever DELETES data the user asked to erase).
 *
 * Documents (names kept from iOS): `pocketdj-rec-key.json` (profile-synced bearer key, minted
 * lazily on the first flush) and `pocketdj-rec-sync.json` (device-local cursors/acks, NOT synced:
 * the server dedupes by event id, shared cursors would let one device's advance starve the other).
 *
 * Cursors are a trailing WINDOW, not a high-water mark: peer events merged in by profile sync
 * carry their ORIGINAL older timestamps, so each stream uploads `atMs >= cursor - 30 d` minus the
 * ids this device already had acknowledged (`uploaded*`). The rec server sees a DERIVED profile id,
 * `HMAC-SHA256(profileId, key = bearer)`, so a third-party host that logged the broadcast id can't
 * address this profile's rec state.
 */
class RecommendationService(
    private val client: RecEngineClient,
    private val scope: CoroutineScope,
    /** The persisted Settings toggle, read live (the privacy gate). */
    private val enabled: () -> Boolean,
    /** "Include lifetime play counts" opt-out. */
    private val shareLifetimePlayCounts: () -> Boolean = { true },
    /** The broadcast profile id (HMAC input; also the legacy-migration id). */
    private val profileId: () -> String,
    private val deviceId: () -> String,
    val keyFile: File,
    private val stateFile: File,
    private val pendingDeleteFile: File = File(keyFile.parentFile, "pocketdj-rec-pending-delete.json"),
    // Store-derived upload sources (all rows; the service applies the window/ack filter).
    private val playsProvider: () -> List<RecPlayEventWire> = { emptyList() },
    private val favoritesProvider: () -> List<RecFavoriteWire> = { emptyList() },
    private val activityProvider: () -> List<RecActivityWire> = { emptyList() },
    /** Effective, UNCAPPED membership; the service applies the snapshot caps. */
    private val collectionsProvider: () -> List<RecFlatCollection> = { emptyList() },
    /** Per-collection recs opt-out, applied at READ time (the server still sees the membership). */
    private val recommendationsEnabledFor: (String) -> Boolean = { true },
    private val clock: () -> Long = System::currentTimeMillis,
    private val autoFlushDelayMs: Long = 20_000L,
    private val autoFlushPeriodMs: Long = 600_000L,
    private val flushSoonDelayMs: Long = 5_000L,
) {
    // ---- view models ----------------------------------------------------------------------

    data class SongSuggestion(val songId: String, val name: String, val artist: String, val reasons: List<String>)
    data class CollectionSuggestion(val id: String, val kind: String, val name: String, val reasons: List<String>)

    // ---- observable state -----------------------------------------------------------------

    private val _forYou = MutableStateFlow<List<SongSuggestion>>(emptyList())
    val forYou: StateFlow<List<SongSuggestion>> = _forYou.asStateFlow()
    @Volatile var forYouFetchedAtMs: Long? = null
        private set
    private val _isLoadingForYou = MutableStateFlow(false)
    val isLoadingForYou: StateFlow<Boolean> = _isLoadingForYou.asStateFlow()
    private val _lastSyncedAtMs = MutableStateFlow<Long?>(null)
    val lastSyncedAtMs: StateFlow<Long?> = _lastSyncedAtMs.asStateFlow()
    private val _syncError = MutableStateFlow<String?>(null)
    val syncError: StateFlow<String?> = _syncError.asStateFlow()
    private val _suggestionsRevision = MutableStateFlow(0)
    /** Bumped whenever a [cachedCollectionSuggestions] miss finishes fetching. */
    val collectionSuggestionsRevision: StateFlow<Int> = _suggestionsRevision.asStateFlow()

    // ---- persisted documents --------------------------------------------------------------

    @Serializable
    private data class KeyDoc(val schemaVersion: Int? = null, val key: String? = null)

    /** Device-local upload cursors. Every field defaults so an older/partial doc decodes degraded, never resets. */
    @Serializable
    data class SyncState(
        val schemaVersion: Int = 1,
        val lastPlayAtMs: Double = 0.0,
        val lastFavoriteAtMs: Double = 0.0,
        val lastActivityAtMs: Double = 0.0,
        val lastPuzzleAtMs: Double = 0.0,
        val lastFeedbackAtMs: Double = 0.0,
        val lastCollectionsHash: String? = null,
        val lastPlayCountsHash: String? = null,
        val lastSyncedAtMs: Double? = null,
        /** Acked uploads inside the trailing overlap window, one `"<atMs>|<id>"` each. */
        val uploadedPlays: List<String> = emptyList(),
        val uploadedFavorites: List<String> = emptyList(),
        val uploadedActivity: List<String> = emptyList(),
        val uploadedPuzzle: List<String> = emptyList(),
        val uploadedFeedback: List<String> = emptyList(),
        val didMigrateScopedProfile: Boolean = false,
        /** Audio shortlist not yet uploaded (persisted so a force-quit doesn't lose the night's list). */
        val audioPendingUpload: List<String> = emptyList(),
        /** Shortlist ids the SERVER acknowledged (so a second refresh proposes NEW songs). */
        val audioQueued: List<String> = emptyList(),
    )

    @Serializable
    private data class PendingDeleteDoc(
        val schemaVersion: Int? = null,
        val key: String? = null,
        val profileId: String? = null,
        val requestedAtMs: Double? = null,
        val attempts: Int? = null,
        /** The RAW id, carried only while the scoped-id migration was unfinished at deletion time. */
        val legacyProfileId: String? = null,
    )

    // ---- seams ----------------------------------------------------------------------------

    /** Collector's Puzzle events since a cursor (Games wires it; null => nothing uploaded). */
    @Volatile var puzzleEventsProvider: ((sinceMs: Double) -> List<RecPuzzleEventWire>)? = null

    /** 👍/👎 events since a cursor (`RecFeedbackStore`); null => nothing uploaded. */
    @Volatile var feedbackProvider: ((sinceMs: Double) -> List<RecFeedbackWire>)? = null

    /** Lifetime play counts (`PlayStatsStore.playCountsSnapshot`); null => nothing uploaded. */
    @Volatile var playCountsProvider: (() -> Map<String, Int>)? = null

    /** songId -> last-played epoch ms; rides the SAME [shareLifetimePlayCounts] opt-out. */
    @Volatile var lastPlayedProvider: (() -> Map<String, Double>)? = null

    /** "Delete cloud data" cascade (listening pockets erase under the SAME identity). */
    @Volatile var onDeleteCloudData: (suspend (key: String, profileId: String) -> Unit)? = null

    // ---- internals ------------------------------------------------------------------------

    private val lock = Any()
    @Volatile private var sync = SyncState()
    @Volatile private var key: String? = null
    private val isFlushing = AtomicBoolean(false)
    @Volatile private var flushJob: Job? = null

    /** Invalidation epoch: moved => an in-flight flush ABANDONS (no cursor advance, no acks, no error). */
    private val flushEpoch = AtomicInteger(0)
    val epoch: Int get() = flushEpoch.get()
    @Volatile private var autoFlushJob: Job? = null
    private val autoFlushGeneration = AtomicInteger(0)
    @Volatile private var debounceJob: Job? = null

    private class CacheEntry<T>(val atMs: Long, val value: T)
    private val suggestionCache = HashMap<String, CacheEntry<List<RecCollectionSuggestionWire>>>()
    private val suggestionCacheOrder = ArrayList<String>()
    private val suggestionsAttemptedAtMs = HashMap<String, Long>()
    private val similarCache = HashMap<String, CacheEntry<List<String>>>()
    private val similarCacheOrder = ArrayList<String>()

    init {
        runCatching { stateFile.takeIf { it.isFile }?.readText() }.getOrNull()?.let { text ->
            runCatching { PdjJson.lenient.decodeFromString(SyncState.serializer(), text) }.getOrNull()?.let {
                sync = it
                _lastSyncedAtMs.value = it.lastSyncedAtMs?.toLong()
            }
        }
        key = decodeKey(keyFile)
    }

    /** THE privacy gate — every network-touching method guards this first. */
    val isEnabled: Boolean get() = enabled()

    /** The current sync cursors (test + diagnostics visibility). */
    val syncState: SyncState get() = sync

    // ---- key management -------------------------------------------------------------------

    private fun decodeKey(f: File): String? {
        val text = runCatching { f.takeIf { it.isFile }?.readText() }.getOrNull() ?: return null
        val doc = runCatching { PdjJson.lenient.decodeFromString(KeyDoc.serializer(), text) }.getOrNull() ?: return null
        return doc.key?.takeIf { it.isNotEmpty() }
    }

    /**
     * Re-decode after profile sync pulled a peer's key doc (the two-devices-enabled-at-once race:
     * the pulled key wins). A genuine rebind resets the cursors (everything re-uploads under the
     * winner's id; the server dedupes) and best-effort DELETEs the orphaned object while the losing
     * key can still authorize it.
     */
    fun reloadKeyFromDisk() {
        val pulled = decodeKey(keyFile) ?: return
        val losing: String?
        val orphanProfile: String?
        synchronized(lock) {
            if (pulled == key) return
            losing = key
            key = pulled
            if (losing == null) return
            flushEpoch.incrementAndGet()
            orphanProfile = scopedProfileId(losing)
            sync = SyncState(didMigrateScopedProfile = sync.didMigrateScopedProfile)
            persistSyncState()
        }
        scope.launch { runCatching { client.deleteState(losing!!, orphanProfile!!) } }
    }

    /** The key, minted + persisted on first use (32 random bytes, hex). */
    private fun ensureKey(): String = synchronized(lock) {
        key?.let { return it }
        val minted = mintKeyValue()
        key = minted
        runCatching { atomicWrite(keyFile, PdjJson.lenient.encodeToString(KeyDoc.serializer(), KeyDoc(1, minted))) }
        minted
    }

    /**
     * The bearer key + scoped id for the OTHER first-party service that rides this consent
     * (listening pockets). null while disabled, so a caller that forgot its own gate still can't reach the network.
     */
    fun sharedCredentials(): RecCredentials? {
        if (!isEnabled) return null
        val k = ensureKey()
        return RecCredentials(k, scopedProfileId(k))
    }

    /** `HMAC-SHA256(profileId, key = bearer)` hex — see the class doc. */
    private fun scopedProfileId(key: String): String = scopedProfileId(profileId(), key)

    // ---- auto flush -----------------------------------------------------------------------

    /** Test-visible: is a loop armed? */
    val isAutoFlushArmed: Boolean get() = autoFlushJob != null

    /**
     * Idempotent: ONE loop. Initial delay (launch settle), then flush every period while enabled; exits
     * when disabled (re-armed by [enabledDidChange]). The generation guard is load-bearing: a cancelled
     * loop's tail must not detach the handle of the loop that REPLACED it.
     */
    fun startAutoFlush() {
        synchronized(lock) {
            if (autoFlushJob != null) return
            val generation = autoFlushGeneration.incrementAndGet()
            autoFlushJob = scope.launch {
                try {
                    delay(autoFlushDelayMs)
                    // Finishing an owed deletion is the ONE thing that runs regardless of the toggle.
                    retryPendingCloudDelete()
                    while (isActive && isEnabled) {
                        flushNow()
                        delay(autoFlushPeriodMs)
                    }
                } finally {
                    synchronized(lock) {
                        if (autoFlushGeneration.get() == generation) autoFlushJob = null
                    }
                }
            }
        }
    }

    /** Debounced flush (the background hook). */
    fun flushSoon() {
        if (!isEnabled) return
        synchronized(lock) {
            debounceJob?.cancel()
            debounceJob = scope.launch {
                delay(flushSoonDelayMs)
                flushNow()
            }
        }
    }

    // ---- flush ----------------------------------------------------------------------------

    /**
     * Upload everything inside each stream's trailing window the server hasn't acknowledged, in
     * <=500-per-stream batches until drained. Cursors advance ONLY to the max atMs actually SENT; acks
     * are remembered ONLY on 2xx. The drain runs in a stored job so [deleteCloudData] can await it.
     */
    suspend fun flushNow() {
        if (!isEnabled) return
        if (!isFlushing.compareAndSet(false, true)) return
        val ep = flushEpoch.get()
        val job = scope.launch { performFlush(ep) }
        job.invokeOnCompletion { isFlushing.set(false) }
        flushJob = job
        try {
            job.join()
        } finally {
            if (flushJob === job) flushJob = null
        }
    }

    private suspend fun performFlush(ep: Int) {
        val key = ensureKey()
        val profile = scopedProfileId(key)

        if (!migrateOffBroadcastProfileId(key, ep)) return

        val st = sync
        val playFloor = windowFloor(st.lastPlayAtMs)
        val favFloor = windowFloor(st.lastFavoriteAtMs)
        val actFloor = windowFloor(st.lastActivityAtMs)
        val puzzleFloor = windowFloor(st.lastPuzzleAtMs)
        val feedbackFloor = windowFloor(st.lastFeedbackAtMs)
        val sentPlays = st.uploadedPlays.toHashSet()
        val sentFavs = st.uploadedFavorites.toHashSet()
        val sentActs = st.uploadedActivity.toHashSet()
        val sentPuzzle = st.uploadedPuzzle.toHashSet()
        val sentFeedback = st.uploadedFeedback.toHashSet()

        var plays = playsProvider().filter { it.atMs >= playFloor && ack(it.atMs, it.id) !in sentPlays }.sortedBy { it.atMs }
        var favs = favoritesProvider().filter { it.atMs >= favFloor && ack(it.atMs, it.songId) !in sentFavs }.sortedBy { it.atMs }
        var acts = activityProvider().filter { it.atMs >= actFloor && ack(it.atMs, it.id) !in sentActs }.sortedBy { it.atMs }
        var puzzle = (puzzleEventsProvider?.invoke(puzzleFloor) ?: emptyList())
            .filter { ack(it.atMs, it.id) !in sentPuzzle }.sortedBy { it.atMs }
        var feedback = (feedbackProvider?.invoke(feedbackFloor) ?: emptyList())
            .filter { ack(it.atMs, it.id) !in sentFeedback }.sortedBy { it.atMs }

        val snapshot = collectionsSnapshotWire()
        val snapshotHash = snapshotHash(snapshot)
        var pendingSnapshot: RecCollectionsSnapshotWire? = if (snapshotHash != st.lastCollectionsHash) snapshot else null
        // Encoded-size guard: never let the snapshot make an EVENT batch undeliverable. The hash
        // deliberately stays un-advanced, so a later, smaller membership re-attempts.
        pendingSnapshot?.let { snap ->
            if (PdjJson.lenient.encodeToString(snap).toByteArray().size > SNAPSHOT_BYTE_CAP) pendingSnapshot = null
        }

        val playCountsSnapshot = playCountsWire()
        val playCountsHash = playCountsSnapshot?.let(::playCountsHash)
        var pendingPlayCounts: RecPlayCountsWire? =
            if (playCountsHash != null && playCountsHash != st.lastPlayCountsHash) playCountsSnapshot else null

        // Audio shortlist rides the FIRST batch only (a set on the server).
        var pendingAudio: RecAudioQueueWire? =
            if (st.audioPendingUpload.isEmpty()) null else RecAudioQueueWire(clock().toDouble(), st.audioPendingUpload)

        fun more() = plays.isNotEmpty() || favs.isNotEmpty() || acts.isNotEmpty() || puzzle.isNotEmpty() ||
            feedback.isNotEmpty() || pendingSnapshot != null || pendingPlayCounts != null || pendingAudio != null
        if (!more()) return

        while (more()) {
            val batchPlays = plays.take(BATCH_CAP)
            val batchFavs = favs.take(BATCH_CAP)
            val batchActs = acts.take(BATCH_CAP)
            val batchPuzzle = puzzle.take(BATCH_CAP)
            val batchFeedback = feedback.take(BATCH_CAP)
            val audio = pendingAudio
            fun makeBatch(snap: RecCollectionsSnapshotWire?, counts: RecPlayCountsWire?) = RecUploadBatch(
                deviceId = deviceId(),
                sentAtMs = clock().toDouble(),
                plays = batchPlays.ifEmpty { null },
                favorites = batchFavs.ifEmpty { null },
                activity = batchActs.ifEmpty { null },
                puzzle = batchPuzzle.ifEmpty { null },
                feedback = batchFeedback.ifEmpty { null },
                collectionsSnapshot = snap,
                playCounts = counts,
                audioQueue = audio,
            )
            var snapshotDelivered = pendingSnapshot != null
            var playCountsDelivered = pendingPlayCounts != null
            val audioDelivered = audio != null
            try {
                try {
                    client.postEvents(makeBatch(pendingSnapshot, pendingPlayCounts), key, profile)
                } catch (e: RecEngineClient.ClientError.Http) {
                    if (e.code != 413 || (pendingSnapshot == null && pendingPlayCounts == null)) throw e
                    // A SNAPSHOT blew the body ceiling: drop the bulk payloads, not the events.
                    if (ep != flushEpoch.get()) return
                    snapshotDelivered = false
                    playCountsDelivered = false
                    if (batchPlays.isEmpty() && batchFavs.isEmpty() && batchActs.isEmpty() &&
                        batchPuzzle.isEmpty() && batchFeedback.isEmpty()
                    ) {
                        pendingSnapshot = null
                        pendingPlayCounts = null
                        continue // snapshot-only batch: nothing left to deliver this round
                    }
                    client.postEvents(makeBatch(null, null), key, profile)
                }
            } catch (e: CancellationException) {
                return // torn down mid-flight — never a user-facing error (cursors keep)
            } catch (e: RecEngineClient.ClientError.KeyMismatch) {
                if (ep == flushEpoch.get()) _syncError.value = KEY_MISMATCH_MESSAGE
                return
            } catch (e: RecEngineClient.ClientError.EnrollmentRequired) {
                if (ep == flushEpoch.get()) _syncError.value = ENROLLMENT_REQUIRED_MESSAGE
                return
            } catch (e: Exception) {
                if (ep == flushEpoch.get()) _syncError.value = COULDNT_REACH
                return // cursors NOT advanced; retry next cycle
            }
            if (ep != flushEpoch.get()) return // deleted/cleared while in flight

            // 2xx: advance each cursor to the max atMs actually sent and REMEMBER the ids.
            synchronized(lock) {
                if (ep != flushEpoch.get()) return
                val cur = sync
                var audioPending = cur.audioPendingUpload
                var audioQueued = cur.audioQueued
                if (audioDelivered && audio != null) {
                    // Only what was ACTUALLY SENT moves; ids appended mid-flight stay pending.
                    val sentIds = audio.songIds.toHashSet()
                    audioPending = audioPending.filter { it !in sentIds }
                    audioQueued = (audioQueued + audio.songIds).takeLast(AUDIO_QUEUED_MEMORY_CAP)
                }
                val now = clock()
                sync = cur.copy(
                    lastPlayAtMs = batchPlays.lastOrNull()?.let { maxOf(cur.lastPlayAtMs, it.atMs) } ?: cur.lastPlayAtMs,
                    lastFavoriteAtMs = batchFavs.lastOrNull()?.let { maxOf(cur.lastFavoriteAtMs, it.atMs) } ?: cur.lastFavoriteAtMs,
                    lastActivityAtMs = batchActs.lastOrNull()?.let { maxOf(cur.lastActivityAtMs, it.atMs) } ?: cur.lastActivityAtMs,
                    lastPuzzleAtMs = batchPuzzle.lastOrNull()?.let { maxOf(cur.lastPuzzleAtMs, it.atMs) } ?: cur.lastPuzzleAtMs,
                    lastFeedbackAtMs = batchFeedback.lastOrNull()?.let { maxOf(cur.lastFeedbackAtMs, it.atMs) } ?: cur.lastFeedbackAtMs,
                    uploadedPlays = remember(cur.uploadedPlays, batchPlays.map { ack(it.atMs, it.id) }, playFloor),
                    uploadedFavorites = remember(cur.uploadedFavorites, batchFavs.map { ack(it.atMs, it.songId) }, favFloor),
                    uploadedActivity = remember(cur.uploadedActivity, batchActs.map { ack(it.atMs, it.id) }, actFloor),
                    uploadedPuzzle = remember(cur.uploadedPuzzle, batchPuzzle.map { ack(it.atMs, it.id) }, puzzleFloor),
                    uploadedFeedback = remember(cur.uploadedFeedback, batchFeedback.map { ack(it.atMs, it.id) }, feedbackFloor),
                    lastCollectionsHash = if (snapshotDelivered) snapshotHash else cur.lastCollectionsHash,
                    lastPlayCountsHash = if (playCountsDelivered) playCountsHash else cur.lastPlayCountsHash,
                    audioPendingUpload = audioPending,
                    audioQueued = audioQueued,
                    lastSyncedAtMs = now.toDouble(),
                )
                _lastSyncedAtMs.value = now
                _syncError.value = null
                persistSyncState()
            }
            pendingSnapshot = null
            pendingPlayCounts = null
            pendingAudio = null
            plays = plays.drop(batchPlays.size)
            favs = favs.drop(batchFavs.size)
            acts = acts.drop(batchActs.size)
            puzzle = puzzle.drop(batchPuzzle.size)
            feedback = feedback.drop(batchFeedback.size)
        }
    }

    /**
     * The one-time move off the broadcast profile id. Returns false when the caller must ABANDON this
     * flush (transient failure => retry next cycle, or a moved epoch). On success the cursors RESET:
     * the scoped id addresses a brand-new empty object, so a full re-upload IS the migration.
     */
    private suspend fun migrateOffBroadcastProfileId(key: String, ep: Int): Boolean {
        if (sync.didMigrateScopedProfile) return true
        if (sync.lastSyncedAtMs == null) {
            // Never uploaded under ANY id — nothing server-side to migrate.
            synchronized(lock) { sync = sync.copy(didMigrateScopedProfile = true); persistSyncState() }
            return true
        }
        try {
            client.deleteState(key, profileId())
        } catch (e: CancellationException) {
            return false
        } catch (e: RecEngineClient.ClientError) {
            if (ep != flushEpoch.get()) return false
            when (e) {
                is RecEngineClient.ClientError.KeyMismatch, is RecEngineClient.ClientError.EnrollmentRequired -> Unit
                is RecEngineClient.ClientError.Http -> if (e.code !in 400..499) return false
                is RecEngineClient.ClientError.BadResponse -> return false
            }
        } catch (e: Exception) {
            return false // offline — retry the migration next flush
        }
        if (ep != flushEpoch.get()) return false
        synchronized(lock) {
            sync = SyncState(didMigrateScopedProfile = true)
            persistSyncState()
        }
        return true
    }

    // ---- snapshots + hashing --------------------------------------------------------------

    private fun collectionsSnapshotWire(): RecCollectionsSnapshotWire {
        val flat = RecCollectionFlattener.capped(
            collectionsProvider(), SNAPSHOT_COLLECTION_CAP, SNAPSHOT_SONG_ID_CAP, SNAPSHOT_TOTAL_SONG_ID_CAP,
        )
        return RecCollectionsSnapshotWire(
            clock().toDouble(),
            flat.map { RecCollectionsSnapshotWire.Entry(it.id, it.kind, it.name, it.songIds) },
        )
    }

    private fun playCountsWire(): RecPlayCountsWire? {
        if (!shareLifetimePlayCounts()) return null
        val counts = playCountsProvider?.invoke() ?: return null
        val positive = counts.filterValues { it > 0 }
        if (positive.isEmpty()) return null
        val trimmed: Map<String, Int> =
            if (positive.size <= PLAY_COUNTS_CAP) positive
            else positive.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
                .take(PLAY_COUNTS_CAP).associate { it.key to it.value }
        var days: Map<String, Int>? = null
        val dates = lastPlayedProvider?.invoke()
        if (!dates.isNullOrEmpty()) {
            val d = HashMap<String, Int>(trimmed.size)
            for (id in trimmed.keys) {
                val ms = dates[id] ?: continue
                if (ms > 0) d[id] = Math.floor(ms / 86_400_000.0).toInt()
            }
            if (d.isNotEmpty()) days = d
        }
        return RecPlayCountsWire(clock().toDouble(), trimmed, days)
    }

    private fun persistSyncState() {
        runCatching { atomicWrite(stateFile, PdjJson.lenient.encodeToString(SyncState.serializer(), sync)) }
    }

    // ---- For You --------------------------------------------------------------------------

    /**
     * THE CLOUD RANKING FOR In Da Zone — ids best-first, each with the Lambda's one-line why. A LIST OR
     * NOTHING: `[]` means "use your own ranking" and covers engine off (zero requests), unreachable
     * server, wedged key, empty state. [force] is what a manual Refresh passes (skips the 15-min TTL).
     */
    suspend fun cloudZoneRanking(force: Boolean = true): List<ForYouCloudZoneRow> {
        if (!isEnabled) return emptyList()
        refreshForYou(force)
        return forYou.value.map { ForYouCloudZoneRow(it.songId, it.reasons.firstOrNull { r -> r.isNotEmpty() }) }
    }

    suspend fun refreshForYou(force: Boolean = false) {
        if (!isEnabled) return
        val now = clock()
        val fetched = forYouFetchedAtMs
        if (!force && fetched != null && now - fetched < CACHE_TTL_MS && _forYou.value.isNotEmpty()) return
        _isLoadingForYou.value = true
        try {
            flushNow() // recs should see the latest plays
            try {
                val k = ensureKey()
                val resp = client.forYou(FOR_YOU_FETCH_LIMIT, k, scopedProfileId(k))
                _forYou.value = resp.songs.map {
                    SongSuggestion(it.songId, it.name ?: it.songId, it.artist.orEmpty(), it.reasons.orEmpty())
                }
                forYouFetchedAtMs = clock()
                _syncError.value = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: RecEngineClient.ClientError.KeyMismatch) {
                _syncError.value = KEY_MISMATCH_MESSAGE
            } catch (e: Exception) {
                if (_forYou.value.isEmpty()) _syncError.value = COULDNT_REACH
            }
        } finally {
            _isLoadingForYou.value = false
        }
    }

    // ---- targeted audio analysis ----------------------------------------------------------

    /** Ids the server is already holding — what the shortlist selector subtracts. */
    val audioPendingIds: Set<String> get() = sync.audioQueued.toHashSet() + sync.audioPendingUpload

    /** Schedule a shortlist (ids only) onto the SAME /events flush. Gated like everything else. */
    fun enqueueAudioAnalysis(ids: List<String>) {
        if (!isEnabled || ids.isEmpty()) return
        synchronized(lock) {
            val known = audioPendingIds
            val fresh = ids.filter { it !in known }
            if (fresh.isEmpty()) return
            sync = sync.copy(audioPendingUpload = (sync.audioPendingUpload + fresh).takeLast(AUDIO_PENDING_CAP))
            persistSyncState()
        }
        flushSoon()
    }

    /**
     * The shortlist PRODUCER (iOS `ForYouView.scheduleAudioAnalysis`): after a ranking commits, select the night's
     * ids on device ([select], default [ForYouFeedBuilder.audioShortlist]) minus what the server already holds, and
     * hand ONLY the ids to [enqueueAudioAnalysis]. No-op (selector never runs) with the engine off or no ranking yet.
     * Returns the ids selected (empty when gated).
     */
    fun scheduleAudioAnalysis(
        snapshot: ForYouFeedSnapshot,
        inputs: ForYouFeedInputs,
        select: (ForYouFeedSnapshot, ForYouFeedInputs, Set<String>) -> List<String> = { s, i, pending ->
            ForYouFeedBuilder.audioShortlist(s, i, pending = pending)
        },
    ): List<String> {
        if (!isEnabled || !snapshot.hasResult) return emptyList()
        val ids = select(snapshot, inputs, audioPendingIds)
        enqueueAudioAnalysis(ids)
        return ids
    }

    // ---- collection suggestions (SongDetail + Add sheet) ----------------------------------

    suspend fun collectionSuggestions(songId: String): List<CollectionSuggestion> =
        rawCollectionSuggestions(songId).map {
            CollectionSuggestion(it.id, it.kind ?: "playlist", it.name ?: it.id, it.reasons.orEmpty())
        }

    /** The cached wire rows (the Add sheet feeds these to [RecSuggestionFilter]). */
    suspend fun rawCollectionSuggestions(songId: String): List<RecCollectionSuggestionWire> {
        if (!isEnabled) return emptyList()
        val now = clock()
        synchronized(lock) { suggestionCache[songId]?.takeIf { now - it.atMs < CACHE_TTL_MS } }
            ?.let { return dropRecsOff(it.value) }
        return try {
            val k = ensureKey()
            val resp = client.collectionSuggestions(songId, k, scopedProfileId(k))
            cacheSuggestions(songId, resp.suggestions, now)
            dropRecsOff(resp.suggestions)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyList() // suggestion surfaces just stay hidden — never block UI
        }
    }

    /**
     * Synchronous read of the same suggestions for a menu body that can't await. A miss returns [] and
     * starts ONE fetch per song per TTL (in flight OR finished — a failed fetch isn't cached, so
     * without this the revision bump would re-render, miss and refetch in a loop).
     */
    fun cachedCollectionSuggestions(songId: String): List<RecCollectionSuggestionWire> {
        if (!isEnabled) return emptyList()
        val now = clock()
        synchronized(lock) {
            suggestionCache[songId]?.takeIf { now - it.atMs < CACHE_TTL_MS }?.let { return dropRecsOff(it.value) }
            val attempted = suggestionsAttemptedAtMs[songId]
            if (attempted != null && now - attempted < CACHE_TTL_MS) return emptyList()
            suggestionsAttemptedAtMs[songId] = now
            if (suggestionsAttemptedAtMs.size > 200) {
                suggestionsAttemptedAtMs.clear()
                suggestionsAttemptedAtMs[songId] = now
            }
        }
        scope.launch {
            rawCollectionSuggestions(songId)
            _suggestionsRevision.value = _suggestionsRevision.value + 1
        }
        return emptyList()
    }

    /**
     * THE PER-COLLECTION OPT-OUT, applied on the device (the membership snapshot still carries a
     * switched-off collection so the engine knows what the owner already owns). Applied on the cache
     * READ as well as the fetch, so a crate switched off stops being offered immediately.
     */
    private fun dropRecsOff(wire: List<RecCollectionSuggestionWire>) = wire.filter { recommendationsEnabledFor(it.id) }

    private fun cacheSuggestions(songId: String, wire: List<RecCollectionSuggestionWire>, atMs: Long) = synchronized(lock) {
        suggestionCache[songId] = CacheEntry(atMs, wire)
        suggestionCacheOrder.remove(songId)
        suggestionCacheOrder.add(songId)
        while (suggestionCacheOrder.size > SUGGESTION_CACHE_CAP) suggestionCache.remove(suggestionCacheOrder.removeAt(0))
    }

    // ---- collection similarity (Gem Collector's cloud booster) ----------------------------

    /** Songs similar to a SET of collections, best first, cached 15 min by sorted id list. [] on any failure. */
    suspend fun similarSongs(toCollections: List<String>, limit: Int = 200): List<String> {
        if (!isEnabled || toCollections.isEmpty()) return emptyList()
        val cacheKey = toCollections.sorted().joinToString(",")
        val now = clock()
        synchronized(lock) { similarCache[cacheKey]?.takeIf { now - it.atMs < CACHE_TTL_MS } }?.let { return it.value }
        return try {
            val k = ensureKey()
            val resp = client.similarToCollections(toCollections.take(3), limit, k, scopedProfileId(k))
            val ids = resp.songs.map { it.songId }
            synchronized(lock) {
                similarCache[cacheKey] = CacheEntry(now, ids)
                similarCacheOrder.remove(cacheKey)
                similarCacheOrder.add(cacheKey)
                while (similarCacheOrder.size > SIMILAR_CACHE_CAP) similarCache.remove(similarCacheOrder.removeAt(0))
            }
            ids
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyList()
        }
    }

    // ---- lifecycle ------------------------------------------------------------------------

    /**
     * Settings toggled. OFF: stop the loops and clear in-memory suggestion state (cursors + key are
     * RETAINED — re-enable resumes; server state persists until "Delete cloud data"). ON: arm auto-flush.
     */
    fun enabledDidChange() {
        flushEpoch.incrementAndGet() // any in-flight drain must not outlive the toggle that saw it start
        if (isEnabled) {
            startAutoFlush()
        } else {
            synchronized(lock) {
                autoFlushJob?.cancel(); autoFlushJob = null
                debounceJob?.cancel(); debounceJob = null
                _forYou.value = emptyList()
                forYouFetchedAtMs = null
                suggestionCache.clear(); suggestionCacheOrder.clear(); suggestionsAttemptedAtMs.clear()
                similarCache.clear(); similarCacheOrder.clear()
                _syncError.value = null
            }
        }
    }

    /**
     * "Delete cloud data": remove the server-side state object. Works even when this device's key is the
     * WRONG one (the enrollment secret is accepted in place of the bound key). NEVER MINTS: a device with
     * no key, no tombstone and no upload history owes the server nothing — zero network.
     */
    fun deleteCloudDataAsync(): kotlinx.coroutines.Job = scope.launch { deleteCloudData() }

    /** [flushNow] on the service's own scope so leaving the screen can't cancel it midway. */
    fun flushNowAsync(): kotlinx.coroutines.Job = scope.launch { flushNow() }

    suspend fun deleteCloudData(): Boolean {
        flushEpoch.incrementAndGet()
        flushJob?.join() // no batch may land after the DELETE
        if (hasPendingCloudDelete) retryPendingCloudDelete()
        val hasSyncEvidence = sync.lastSyncedAtMs != null || stateFile.exists()
        if (key == null && !hasPendingCloudDelete && !hasSyncEvidence) return true
        val bearer = key ?: mintKeyValue() // throwaway when keyless — NOT persisted
        try {
            client.deleteState(bearer, scopedProfileId(bearer))
        } catch (e: CancellationException) {
            throw e
        } catch (e: RecEngineClient.ClientError.KeyMismatch) {
            _syncError.value = DELETE_REFUSED_MESSAGE; return false
        } catch (e: RecEngineClient.ClientError.EnrollmentRequired) {
            _syncError.value = DELETE_REFUSED_MESSAGE; return false
        } catch (e: Exception) {
            _syncError.value = "Couldn't delete the cloud data — try again."; return false
        }
        // Pre-scoped-id builds enrolled under the BROADCAST id; best-effort sweep of that object too.
        if (!sync.didMigrateScopedProfile) runCatching { client.deleteState(bearer, profileId()) }
        onDeleteCloudData?.let { runCatching { it(bearer, scopedProfileId(bearer)) } }
        synchronized(lock) {
            sync = SyncState(didMigrateScopedProfile = true) // both ids are gone
            persistSyncState()
            _forYou.value = emptyList()
            forYouFetchedAtMs = null
            suggestionCache.clear(); suggestionCacheOrder.clear()
            _syncError.value = null
        }
        return true
    }

    /**
     * Account-deletion contract: remove both persisted files + in-memory reset. When [cloudDeleted] is
     * false the credential moves INTO the tombstone (key + the exact profile id the delete targets) so
     * [retryPendingCloudDelete] can finish the job; the key FILE is removed in BOTH branches so a
     * re-enable mints a FRESH identity.
     */
    fun clearLocal(cloudDeleted: Boolean = true) {
        flushEpoch.incrementAndGet()
        synchronized(lock) {
            autoFlushJob?.cancel(); autoFlushJob = null
            debounceJob?.cancel(); debounceJob = null
            if (cloudDeleted) pendingDeleteFile.delete() else writePendingDelete()
            keyFile.delete()
            key = null
            stateFile.delete()
            sync = SyncState()
            _forYou.value = emptyList()
            forYouFetchedAtMs = null
            _lastSyncedAtMs.value = null
            suggestionCache.clear(); suggestionCacheOrder.clear(); suggestionsAttemptedAtMs.clear()
            similarCache.clear(); similarCacheOrder.clear()
            _syncError.value = null
        }
    }

    /** Is a server-side deletion still owed? */
    val hasPendingCloudDelete: Boolean get() = pendingDeleteFile.exists()

    private fun writePendingDelete() {
        val k = key ?: return
        val doc = PendingDeleteDoc(
            schemaVersion = 1, key = k, profileId = scopedProfileId(k),
            requestedAtMs = clock().toDouble(), attempts = 0,
            legacyProfileId = if (sync.didMigrateScopedProfile) null else profileId(),
        )
        runCatching { atomicWrite(pendingDeleteFile, PdjJson.lenient.encodeToString(PendingDeleteDoc.serializer(), doc)) }
    }

    /**
     * Finish a deletion the network refused earlier, REGARDLESS of the toggle (it only ever DELETES).
     * No tombstone => no request. BOUNDED: a 403 is terminal on the spot; transient failures count up to
     * 20 attempts or 30 days, then the tombstone gives up and cleans up.
     */
    suspend fun retryPendingCloudDelete() {
        val text = runCatching { pendingDeleteFile.takeIf { it.isFile }?.readText() }.getOrNull() ?: return
        val doc = runCatching { PdjJson.lenient.decodeFromString(PendingDeleteDoc.serializer(), text) }.getOrNull() ?: return
        val pendingKey = doc.key?.takeIf { it.isNotEmpty() } ?: return
        val pendingProfile = doc.profileId?.takeIf { it.isNotEmpty() } ?: return
        val attempts = doc.attempts ?: 0
        val ageMs = clock() - (doc.requestedAtMs ?: 0.0)
        if (attempts >= PENDING_DELETE_MAX_ATTEMPTS || ageMs > PENDING_DELETE_MAX_AGE_MS) {
            pendingDeleteFile.delete()
            _syncError.value = PENDING_DELETE_GAVE_UP
            return
        }
        try {
            client.deleteState(pendingKey, pendingProfile)
        } catch (e: CancellationException) {
            throw e
        } catch (e: RecEngineClient.ClientError) {
            if (e is RecEngineClient.ClientError.KeyMismatch || e is RecEngineClient.ClientError.EnrollmentRequired) {
                // Terminal: the server already refused this exact credential.
                pendingDeleteFile.delete()
                _syncError.value = PENDING_DELETE_GAVE_UP
                return
            }
            bumpAttempts(doc, attempts)
            return
        } catch (e: Exception) {
            bumpAttempts(doc, attempts)
            return // still owed — the next launch/foreground tries again
        }
        doc.legacyProfileId?.takeIf { it.isNotEmpty() }?.let { runCatching { client.deleteState(pendingKey, it) } }
        pendingDeleteFile.delete()
    }

    private fun bumpAttempts(doc: PendingDeleteDoc, attempts: Int) {
        runCatching {
            atomicWrite(pendingDeleteFile, PdjJson.lenient.encodeToString(PendingDeleteDoc.serializer(), doc.copy(attempts = attempts + 1)))
        }
    }

    companion object {
        const val CACHE_TTL_MS = 15 * 60 * 1000L
        const val BATCH_CAP = 500

        /** How far BELOW each cursor a flush still looks (peer events merged in with older timestamps). */
        const val OVERLAP_WINDOW_MS = 30.0 * 24 * 60 * 60 * 1000

        /** Backstop on each remembered-ack list; eviction keeps the NEWEST acks (see [remember]). */
        const val ACK_CAP = 25_000
        const val SNAPSHOT_COLLECTION_CAP = 500
        const val SNAPSHOT_SONG_ID_CAP = 5_000
        const val SNAPSHOT_TOTAL_SONG_ID_CAP = 100_000
        const val SNAPSHOT_BYTE_CAP = 3_500_000
        const val PLAY_COUNTS_CAP = 20_000
        const val PENDING_DELETE_MAX_ATTEMPTS = 20
        const val PENDING_DELETE_MAX_AGE_MS = 30.0 * 24 * 60 * 60 * 1000
        const val FOR_YOU_FETCH_LIMIT = 200
        const val AUDIO_PENDING_CAP = 400
        const val AUDIO_QUEUED_MEMORY_CAP = 4000
        const val SUGGESTION_CACHE_CAP = 20
        const val SIMILAR_CACHE_CAP = 8

        const val KEY_MISMATCH_MESSAGE =
            "This device's recommendation key doesn't match the cloud data. Tap Delete cloud data " +
                "below to reset it — your recommendations rebuild from this device's history."
        const val ENROLLMENT_REQUIRED_MESSAGE =
            "This PocketDJ build predates a recommendation-service reset. " +
                "Update the app to reconnect — your listening history is safe on this device."
        const val COULDNT_REACH = "Couldn't reach the recommendation service."
        const val DELETE_REFUSED_MESSAGE =
            "The server refused to delete this profile's data. Update to the latest PocketDJ build and try again."
        const val PENDING_DELETE_GAVE_UP =
            "PocketDJ couldn't finish deleting this profile's old recommendation data from the " +
                "server and has stopped retrying."

        /** 32 random bytes, hex — the raw VALUE only. */
        fun mintKeyValue(): String {
            val b = ByteArray(32).also { SecureRandom().nextBytes(it) }
            return b.joinToString("") { "%02x".format(it) }
        }

        /** `HMAC-SHA256(profileId, key = bearer)` hex. */
        fun scopedProfileId(profileId: String, key: String): String {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(key.toByteArray(Charsets.UTF_8), "HmacSHA256"))
            return mac.doFinal(profileId.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        }

        /** The floor a stream's flush filter uses: `cursor - overlapWindow`, never below 0. */
        fun windowFloor(cursor: Double): Double = maxOf(0.0, cursor - OVERLAP_WINDOW_MS)

        /** One remembered ack, `"<atMs>|<id>"` (the timestamp rides so the list prunes EXACTLY by floor). */
        fun ack(atMs: Double, id: String): String = "${Math.round(atMs)}|$id"

        fun ackAtMs(entry: String): Double {
            val sep = entry.indexOf('|')
            if (sep < 0) return 0.0
            return entry.substring(0, sep).toDoubleOrNull() ?: 0.0
        }

        /**
         * Append a delivered batch's acks and drop everything below [floor], with a hard [cap] backstop
         * that evicts by TIMESTAMP (oldest first, ties by string) — NOT append order: a batch of freshly
         * merged PEER events carries OLD timestamps at the list's tail, and a suffix(cap) there evicted the
         * newest local acks, causing a permanent re-send churn.
         */
        fun remember(existing: List<String>, added: List<String>, floor: Double, cap: Int = ACK_CAP): List<String> {
            if (added.isEmpty() && existing.isEmpty()) return existing
            var kept = (existing + added).filter { ackAtMs(it) >= floor }
            if (kept.size > cap) {
                kept = kept.sortedWith(compareBy<String> { ackAtMs(it) }.thenBy { it }).takeLast(cap)
            }
            return kept
        }

        private fun sha256Hex(text: String): String =
            MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

        /** Stable membership hash: one `id|kind|name|joined-songIds` line per entry, sorted, SHA-256. */
        fun snapshotHash(s: RecCollectionsSnapshotWire): String =
            sha256Hex(s.collections.map { "${it.id}|${it.kind}|${it.name}|${it.songIds.joinToString(",")}" }.sorted().joinToString("\n"))

        /** Content-only hash of a play-count snapshot (NEVER `atMs`, which would defeat the gate). */
        fun playCountsHash(w: RecPlayCountsWire): String {
            val lines = w.counts.map { "n|${it.key}|${it.value}" } + (w.lastPlayedDays ?: emptyMap()).map { "d|${it.key}|${it.value}" }
            return sha256Hex(lines.sorted().joinToString("\n"))
        }

        internal fun atomicWrite(file: File, text: String) {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) {
                file.delete()
                if (!tmp.renameTo(file)) throw IOException("rename failed: $file")
            }
        }
    }
}

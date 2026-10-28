package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlayHistoryStore
import com.levi.pocketdj.data.location.ListeningContextLookup
import com.levi.pocketdj.data.location.ListeningContextProviding
import com.levi.pocketdj.data.location.NoopListeningContextProvider
import java.io.File
import java.io.IOException
import java.util.TimeZone
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/**
 * LISTENING POCKETS - the app side of the cloud job that finds the stretches where you were in a groove.
 * Port of apple State/ListeningPocketsService.swift: settles location context onto plays, uploads per-play
 * outcomes in idempotent batches to `POST /pockets/events`, fetches `GET /pockets/results` and caches them,
 * and erases the server state on "Delete cloud data".
 *
 * PRIVACY GATE: [isEnabled] = rec engine ON **and** "Find my listening pockets" ON. Every network method guards
 * it first; toggle off => zero calls. The ONE exception is [deleteCloudData], which only ever deletes. Raw
 * location never reaches this file - only opaque ids via [ListeningContextProviding].
 *
 * UPLOAD SELECTION IS A FINGERPRINT, NOT A CURSOR: a play uploads at track START and its outcome lands LATER
 * (skip verdict, played fraction, settled place/trip). Each event's upload-relevant state reduces to a
 * fingerprint (`outcome|fraction%|ctx|tz`), remembered per event id only on 2xx; a flush sends every in-window
 * event whose fingerprint moved. The server upserts by event id with monotone merge rules, so a re-send is harmless.
 *
 * The sync doc and results cache are DEVICE-LOCAL (never cloud-synced).
 */
class ListeningPocketsService(
    private val history: PlayHistoryStore,
    private val client: ListeningPocketsClient,
    /** The rec engine's bearer key + scoped profile id; null until the rec engine is enrolled. */
    private val credentials: () -> PocketsCredentials?,
    private val recEngineEnabled: () -> Boolean,
    private val pocketsEnabled: () -> Boolean,
    private val scope: CoroutineScope,
    private val syncFile: File,
    private val cacheFile: File,
    private val provider: ListeningContextProviding = NoopListeningContextProvider,
    private val now: () -> Long = System::currentTimeMillis,
    private val deviceId: () -> String? = { null },
) {
    // ---- published state --------------------------------------------------------------------

    private val _results = MutableStateFlow<ListeningPocketsResults?>(null)
    val results: StateFlow<ListeningPocketsResults?> = _results.asStateFlow()

    private val _enabled = MutableStateFlow(false)

    /** The privacy gate as a flow; recomputed by [enabledDidChange]. */
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    @Volatile var resultsFetchedAtMs: Long? = null
        private set
    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()
    @Volatile var lastSentAtMs: Long? = null
        private set
    @Volatile var syncError: String? = null
        private set

    /** False once the server answered 404 (routes not deployed): silent, reset on the next success. */
    @Volatile var serviceAvailable: Boolean = true
        private set

    @Volatile var roundsServiceAvailable: Boolean = true
        private set

    // ---- seams ------------------------------------------------------------------------------

    /** "Is places & trips ON?" - gates sending `ctx`. null => [ListeningContextProviding.isActive]. */
    @Volatile var locationOptedIn: (() -> Boolean)? = null

    /** Fired when the gate CLOSES: the app turns places & trips off too (location exists only to feed pockets). */
    @Volatile var onDisabled: (() -> Unit)? = null

    /** Uploads finished In the Pocket rounds AFTER the plays (installId given). null => events-only flush. true = sent. */
    @Volatile var roundsFlusher: (suspend (PocketsCredentials, String) -> Boolean)? = null

    /** Told the "Delete cloud data" floor so the rounds client stops re-sending erased rounds. */
    @Volatile var onUploadFloor: ((Double) -> Unit)? = null

    /** The collections (pockets/playlists/source playlists + add log) for the membership snapshot. null => none. */
    @Volatile var collectionsProvider: (() -> ListeningPocketsCollections.Input)? = null

    // ---- tuning -----------------------------------------------------------------------------

    @Volatile var autoFlushDelayMs: Long = 25_000
    @Volatile var autoFlushPeriodMs: Long = 600_000
    @Volatile var debounceMs: Long = 5_000

    private var isFlushing = false
    private val flushLock = Any()

    /** True while "Delete cloud data" awaits its DELETE - no flush may start meanwhile. */
    @Volatile private var isDeleting = false
    @Volatile private var flushDone: CompletableDeferred<Boolean>? = null

    /** Invalidation epoch: bumped by a toggle, a delete or a local clear; an in-flight flush re-checks after every await. */
    private val flushEpoch = java.util.concurrent.atomic.AtomicInteger(0)
    /** Last gate value seen by [enabledDidChange]; [onDisabled] fires only on a real true->false change. */
    @Volatile private var lastGate = false
    private var autoFlushJob: Job? = null
    private var autoFlushGeneration = 0
    private var debounceJob: Job? = null
    private val syncLock = Any()

    /** Device-local upload bookkeeping. Every field defaulted (additive-optional). */
    @Serializable
    data class SyncDoc(
        val schemaVersion: Int = 1,
        /** The scoped profile id the fingerprints belong to - a key rebind resets [sent]. */
        val profileId: String? = null,
        /** Event id -> the fingerprint the server acknowledged. */
        val sent: Map<String, String> = emptyMap(),
        val lastResultsGeneratedAtMs: Double? = null,
        /** Set by "Delete cloud data": plays before it never upload again. */
        val uploadFloorMs: Double? = null,
        val collectionsHash: String? = null,
        val collectionsSentAtMs: Double? = null,
    )

    @Volatile private var sync: SyncDoc = SyncDoc()

    init {
        sync = runCatching {
            if (syncFile.exists()) PdjJson.lenient.decodeFromString(SyncDoc.serializer(), syncFile.readText()) else null
        }.getOrNull() ?: SyncDoc()
        runCatching { if (cacheFile.exists()) _results.value = ListeningPocketsResults.parse(cacheFile.readText()) }
        _enabled.value = isEnabled
        lastGate = isEnabled
    }

    // ---- gate -------------------------------------------------------------------------------

    /** THE privacy gate - every network-touching method guards this first. */
    val isEnabled: Boolean get() = recEngineEnabled() && pocketsEnabled()

    // ---- auto flush -------------------------------------------------------------------------

    val isAutoFlushArmed: Boolean get() = autoFlushJob != null

    /** Idempotent: ONE loop - launch settle delay, then a flush every period while enabled. */
    @Synchronized
    fun startAutoFlush() {
        if (autoFlushJob != null || !isEnabled) return
        autoFlushGeneration++
        val generation = autoFlushGeneration
        autoFlushJob = scope.launch {
            delay(autoFlushDelayMs)
            while (isActive && isEnabled) {
                flushNow()
                delay(autoFlushPeriodMs)
            }
            synchronized(this@ListeningPocketsService) {
                if (autoFlushGeneration == generation) autoFlushJob = null
            }
        }
    }

    /** Debounce then flush (the app-backgrounded hook / a round finished). */
    @Synchronized
    fun flushSoon() {
        if (!isEnabled) return
        debounceJob?.cancel()
        debounceJob = scope.launch {
            delay(debounceMs)
            flushNow()
        }
    }

    /** Settings toggled (rec engine OR pockets). OFF stops the loops (server data kept); ON arms the loop. */
    fun enabledDidChange() {
        flushEpoch.incrementAndGet()
        val now = isEnabled
        val was = lastGate
        lastGate = now
        _enabled.value = now
        if (now) {
            startAutoFlush()
        } else {
            synchronized(this) {
                autoFlushJob?.cancel(); autoFlushJob = null
                debounceJob?.cancel(); debounceJob = null
            }
            syncError = null
            if (was) onDisabled?.invoke()
        }
    }

    // ---- flush ------------------------------------------------------------------------------

    /**
     * Settle contexts, then upload every in-window event whose fingerprint moved, in <=1000 batches until
     * drained. Fingerprints are remembered ONLY on 2xx. Fetches fresh results when anything was sent.
     */
    suspend fun flushNow(): Boolean {
        val done = CompletableDeferred<Boolean>()
        val epoch: Int
        // Gate check, epoch read and flush registration are ONE critical section (deleteCloudData takes the same lock).
        synchronized(flushLock) {
            if (!isEnabled || isDeleting || isFlushing) return false
            isFlushing = true
            flushDone = done
            epoch = flushEpoch.get()
        }
        val sent = try {
            performFlush(epoch).also { done.complete(it) }
        } catch (t: Throwable) {
            done.complete(false)
            throw t
        } finally {
            synchronized(flushLock) { isFlushing = false; if (flushDone === done) flushDone = null }
        }
        if (sent && epoch == flushEpoch.get()) refreshResults(force = true)
        return sent
    }

    private suspend fun performFlush(epoch: Int): Boolean {
        val creds = credentials() ?: return false
        settleContexts()

        if (sync.profileId != creds.profileId) {
            // A different identity (first run, key rebind, migration): start the fingerprints over, keep the floor.
            updateSync { SyncDoc(profileId = creds.profileId, uploadFloorMs = it.uploadFloorMs) }
        }
        val floorMs = maxOf(nowMs - WINDOW_DAYS * 86_400_000.0, sync.uploadFloorMs ?: 0.0)
        val window = history.events.filter { it.playedAt >= floorMs }.sortedBy { it.playedAt }
        val windowIds = window.mapTo(HashSet()) { it.id }
        val s0 = sync
        val pruned = s0.sent.filterKeys { it in windowIds }
        if (pruned.size != s0.sent.size) updateSync { it.copy(sent = pruned) }

        val locationOn = locationOptedIn?.invoke() ?: provider.isActive
        val ords = ordinals(history.events, history.installId)
        val pending = ArrayList<Pair<ListeningPocketsUploadEvent, String>>()
        for (e in window) {
            val wire = wireEvent(e, locationOn).copy(ord = ords[e.id] ?: 0)
            val fp = fingerprint(wire)
            if (sync.sent[wire.id] != fp) pending.add(wire to fp)
        }
        if (pending.isEmpty()) return uploadTail(creds, epoch, false)

        var places: List<ListeningPocketsPlaceWire>? = null
        var trips: List<ListeningPocketsTripWire>? = null
        if (provider.isActive) {
            places = provider.placeLabels().take(MAX_PLACES).map {
                ListeningPocketsPlaceWire(it.id, it.rank, it.label, (it.shareOfTime * 1000).roundToLong() / 1000.0)
            }
            trips = provider.tripLabels().take(MAX_TRIPS).map {
                ListeningPocketsTripWire(it.id, it.origin, it.destination, it.label, it.occurrences)
            }
        }

        var sentAny = false
        while (pending.isNotEmpty()) {
            val slice = pending.take(BATCH_CAP)
            val batch = ListeningPocketsUploadBatch(
                deviceId = deviceId(), installId = history.installId, sentAtMs = nowMs.toLong(),
                events = slice.map { it.first }, places = places, trips = trips,
            )
            try {
                client.postEvents(batch, creds)
            } catch (e: CancellationException) {
                throw e
            } catch (_: ListeningPocketsClient.ClientError.NotFound) {
                if (epoch == flushEpoch.get()) serviceAvailable = false   // routes not deployed yet - silent
                return sentAny
            } catch (e: ListeningPocketsClient.ClientError) {
                if (epoch == flushEpoch.get()) syncError = message(e)
                return sentAny
            } catch (_: Exception) {
                if (epoch == flushEpoch.get()) syncError = "Couldn't reach the listening-pockets service."
                return sentAny
            }
            if (epoch != flushEpoch.get()) return sentAny   // deleted / toggled mid-flight
            val acked = slice.associate { it.first.id to it.second }
            updateSync { it.copy(sent = it.sent + acked) }
            repeat(slice.size) { pending.removeAt(0) }
            sentAny = true
            serviceAvailable = true
            syncError = null
            lastSentAtMs = nowMs.toLong()
        }
        return uploadTail(creds, epoch, sentAny)
    }

    /** Collections snapshot, then rounds - both AFTER the plays. */
    private suspend fun uploadTail(creds: PocketsCredentials, epoch: Int, sentPlays: Boolean): Boolean {
        val collectionsSent = uploadCollections(creds, epoch)
        if (epoch != flushEpoch.get()) return sentPlays || collectionsSent
        val roundsSent = uploadRounds(creds, epoch)
        return sentPlays || collectionsSent || roundsSent
    }

    /**
     * Membership snapshot + add history in ONE batch of their own (`events: []`), sent when the content hash moved
     * or >= 24 h since the last ACKNOWLEDGED send; acknowledged only on 2xx. Failures are silent.
     */
    private suspend fun uploadCollections(creds: PocketsCredentials, epoch: Int): Boolean {
        val payload = collectionsPayloadIfDue() ?: return false
        val batch = ListeningPocketsUploadBatch(
            deviceId = deviceId(), installId = history.installId, sentAtMs = nowMs.toLong(),
            events = emptyList(), collections = payload.collections,
            addEvents = payload.addEvents.takeIf { it.isNotEmpty() },
        )
        try {
            client.postEvents(batch, creds)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return false
        }
        if (epoch != flushEpoch.get()) return false
        updateSync { it.copy(collectionsHash = payload.hash, collectionsSentAtMs = nowMs) }
        return true
    }

    /** The current payload when due (changed, or >= 24 h since the last ack), else null. */
    fun collectionsPayloadIfDue(): ListeningPocketsCollections.Payload? {
        val input = collectionsProvider?.invoke() ?: return null
        val payload = ListeningPocketsCollections.build(input, nowMs, sync.uploadFloorMs ?: 0.0)
        if (payload.isEmpty) return null
        val s = sync
        if (!ListeningPocketsCollections.isDue(payload.hash, s.collectionsHash, s.collectionsSentAtMs, nowMs)) return null
        return payload
    }

    private suspend fun uploadRounds(creds: PocketsCredentials, epoch: Int): Boolean {
        val flusher = roundsFlusher ?: return false
        return try {
            flusher(creds, history.installId)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false   // silent: rounds stay queued, the events path owns the visible error
        }
    }

    /**
     * Stamp every LOCAL in-window play still missing a context with what the provider calls SETTLED for its
     * timestamp. Pending / unavailable stay null - asked again next flush.
     */
    fun settleContexts() {
        if (!provider.isActive) return
        val floorMs = nowMs - WINDOW_DAYS * 86_400_000.0
        val tags = HashMap<String, ListeningContextTag>()
        for (e in history.events) {
            if (e.listeningContext != null || e.playedAt < floorMs || history.isFromAnotherDevice(e)) continue
            val r = provider.context(e.playedAt)
            if (r is ListeningContextLookup.Settled) tags[e.id] = r.tag
        }
        history.stampContexts(tags)
    }

    // ---- wire mapping -----------------------------------------------------------------------

    private val nowMs: Double get() = now().toDouble()

    /** One history event -> its upload row (`ord` filled in from [ordinals]). */
    fun wireEvent(e: PlayEvent, locationOn: Boolean): ListeningPocketsUploadEvent {
        val tz = e.tzOffsetMin ?: (TimeZone.getDefault().getOffset(e.playedAt.toLong()) / 60_000)
        // Context rides only on THIS device's plays, and only while places & trips is on.
        val ctx = if (locationOn && !history.isFromAnotherDevice(e)) e.listeningContext else null
        // Ids only; the reserved Now Playing queue id is replaced by the run's captured origin when it has one.
        val collection = ListeningPocketsCollections.context(e.originCollectionId ?: e.contextId, e.source)
        return ListeningPocketsUploadEvent(
            id = e.id, songId = e.songId, atMs = flooredMinute(e.playedAt), ord = 0,
            tzOffsetMin = tz, source = e.source.token, outcome = e.outcome.wireToken,
            fraction = e.listenedFraction?.let { (it * 1000).roundToLong() / 1000.0 },
            originInstallId = e.originInstallId, artist = e.artist, carPlay = e.carPlay, ctx = ctx,
            contextId = collection?.first, contextKind = collection?.second,
        )
    }

    // ---- results ----------------------------------------------------------------------------

    /** Fetch results unless the cache is fresh (`force` ignores the TTL). 404 is silent. */
    suspend fun refreshResults(force: Boolean = false) {
        if (!isEnabled) return
        val at = resultsFetchedAtMs
        if (!force && at != null && now() - at < RESULTS_TTL_MS) return
        val creds = credentials() ?: return
        val epoch = flushEpoch.get()
        _isRefreshing.value = true
        try {
            val (decoded, raw) = client.results(creds)
            if (epoch != flushEpoch.get()) return
            _results.value = decoded
            resultsFetchedAtMs = now()
            serviceAvailable = true
            runCatching { cacheFile.parentFile?.mkdirs(); cacheFile.writeText(raw) }
            updateSync { it.copy(lastResultsGeneratedAtMs = decoded.generatedAtMs) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: ListeningPocketsClient.ClientError.NotFound) {
            if (epoch == flushEpoch.get()) serviceAvailable = false
        } catch (e: ListeningPocketsClient.ClientError) {
            if (epoch == flushEpoch.get() && e != ListeningPocketsClient.ClientError.BadResponse) syncError = message(e)
        } catch (_: Exception) {
            // Offline etc. - keep serving the cache; the next appear/refresh retries.
        } finally {
            _isRefreshing.value = false
        }
    }

    /** Tab appear: refresh only when the cache is older than the TTL. */
    suspend fun refreshIfStale() = refreshResults(force = false)

    /** Pull-to-refresh: upload first (fresh plays should count), then fetch. */
    suspend fun refreshNow() {
        if (!isEnabled) return
        val sent = flushNow()
        if (!sent) refreshResults(force = true)
    }

    // ---- deletion ---------------------------------------------------------------------------

    /**
     * The "Delete cloud data" cascade: erase the server's pockets events + results with the credential that just
     * erased the rec state, then the local cache + sync doc. Runs regardless of the toggles. 404 is success.
     */
    suspend fun deleteCloudData(creds: PocketsCredentials): Boolean {
        val inFlight = synchronized(flushLock) {
            isDeleting = true   // no flush may START while the DELETE is in flight
            flushEpoch.incrementAndGet()
            flushDone
        }
        try {
            inFlight?.let { runCatching { it.await() } }   // no batch may land after the DELETE
            val erasedAtMs = nowMs
            try {
                client.deleteState(creds)
            } catch (e: CancellationException) {
                throw e
            } catch (_: ListeningPocketsClient.ClientError.NotFound) {
                // Not deployed - nothing to erase server-side.
            } catch (_: Exception) {
                syncError = "Couldn't delete the listening-pockets data - try again."
                return false
            }
            resetLocalState()
            // "Fresh data from now on": plays before the erase stay off the server for good.
            updateSync { it.copy(uploadFloorMs = maxOf(it.uploadFloorMs ?: 0.0, erasedAtMs)) }
            onUploadFloor?.invoke(sync.uploadFloorMs ?: erasedAtMs)
            return true
        } finally {
            isDeleting = false
        }
    }

    /** Account-deletion contract: drop every local file + in-memory state, stop the loops. */
    fun clearLocal() {
        flushEpoch.incrementAndGet()
        synchronized(this) {
            autoFlushJob?.cancel(); autoFlushJob = null
            debounceJob?.cancel(); debounceJob = null
        }
        resetLocalState()
    }

    private fun resetLocalState() {
        runCatching { syncFile.delete() }
        runCatching { cacheFile.delete() }
        synchronized(syncLock) { sync = SyncDoc() }
        _results.value = null
        resultsFetchedAtMs = null
        lastSentAtMs = null
        syncError = null
    }

    // ---- test seams -------------------------------------------------------------------------

    val acknowledgedFingerprints: Map<String, String> get() = sync.sent
    val uploadFloorMs: Double? get() = sync.uploadFloorMs
    val syncDoc: SyncDoc get() = sync

    private fun updateSync(f: (SyncDoc) -> SyncDoc) {
        synchronized(syncLock) {
            sync = f(sync)
            runCatching {
                syncFile.parentFile?.mkdirs()
                syncFile.writeText(PdjJson.lenient.encodeToString(SyncDoc.serializer(), sync))
            }
        }
    }

    companion object {
        /** Plays older than this never upload (the server forgets them at 180 days anyway). */
        const val WINDOW_DAYS = 90.0

        /** Events per POST - half the server's 2000 cap. */
        const val BATCH_CAP = 1000

        /** Results younger than this are served from cache. */
        const val RESULTS_TTL_MS = 10L * 60 * 1000
        const val MAX_PLACES = 200
        const val MAX_TRIPS = 400
        const val SYNC_FILE_NAME = "pocketdj-listening-pockets-sync.json"
        const val CACHE_FILE_NAME = "pocketdj-listening-pockets.json"

        /** Coarse time on the wire: play start floored to the minute. */
        fun flooredMinute(ms: Double): Long = Math.floorDiv(ms.toLong(), 60_000L) * 60_000L

        /**
         * `ord` = an event's position among the plays sharing its minute-floored `atMs` and stream
         * (originInstallId ?: this install), in play order. Computed over the WHOLE log, not per batch: the server
         * keeps `ord` immutable from the first insert.
         */
        fun ordinals(events: List<PlayEvent>, installId: String): Map<String, Int> {
            val seen = HashMap<String, Int>()
            val out = HashMap<String, Int>(events.size)
            val ordered = events.sortedWith(compareBy<PlayEvent> { it.playedAt }.thenBy { it.id })
            for (e in ordered) {
                val key = "${e.originInstallId ?: installId}|${flooredMinute(e.playedAt)}"
                val n = seen[key] ?: 0
                out[e.id] = n
                seen[key] = n + 1
            }
            return out
        }

        /** Everything about an event that can CHANGE after its first upload: `outcome|fraction%|ctx|tz`. */
        fun fingerprint(e: ListeningPocketsUploadEvent): String {
            val pct = e.fraction?.let { Math.round(it * 100).toString() } ?: "-"
            val ctx = e.ctx?.let { "${it.kind}/${it.placeId ?: ""}/${it.tripId ?: ""}/${it.destination ?: ""}" } ?: "-"
            val base = "${e.outcome}|$pct|$ctx|${e.tzOffsetMin ?: 0}"
            // Appended only when present, so pre-collections fingerprints stay identical (no mass re-send).
            val cid = e.contextId ?: return base
            return "$base|${e.contextKind ?: ""}/$cid"
        }

        fun message(e: ListeningPocketsClient.ClientError): String = when (e) {
            ListeningPocketsClient.ClientError.KeyMismatch ->
                "The listening-pockets service didn't recognise this device's key. Use \"Delete cloud data\" to reset it."
            ListeningPocketsClient.ClientError.EnrollmentRequired ->
                "This PocketDJ build can't sign up for listening pockets. Update the app."
            ListeningPocketsClient.ClientError.ProfileCapReached ->
                "The listening-pockets service isn't accepting new profiles right now."
            else -> "Couldn't reach the listening-pockets service."
        }
    }
}

/** The persisted wire token of a derived outcome (iOS `PlayOutcome.rawValue`). */
val com.levi.pocketdj.data.history.PlayOutcome.wireToken: String
    get() = name.lowercase()

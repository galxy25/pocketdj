package com.levi.pocketdj.mix.download

import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.diag.DiagLog
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.coroutineContext

/** A burn item's observable status (the miss telemetry + second-sweep predicate). */
data class MixBurnStatus(val state: BurnState, val error: String?, val bytes: Long)

/** The BurnStore slice the downloader drives (production: [com.levi.pocketdj.data.burns.BurnStore]). */
interface MixDownloadBurns {
    /** The burned file exists on disk (non-holding check). */
    fun isOnDisk(songId: String): Boolean
    /** A USER-initiated collection burn owns the store's serial loop; wait rather than interleave. */
    val userBurnActive: Boolean
    /** The download+persist funnel. Returns when the in-process burn finished or was handed to a background transfer. */
    suspend fun burn(songId: String, title: String, artist: String)
    fun status(songId: String): MixBurnStatus?
    /** Explicit Mix download action: promote any temporary buffer hold (iOS `pin(_, reason: "mix-download")`). */
    fun pin(songIds: Collection<String>, reason: String) {}
    /** Stop the loop AND its in-flight background transfers. */
    fun requestStop()
    fun cancelTransfers(songIds: Collection<String>)
    /** A `.ready` item landed via the background/adopt path. Null clears. */
    fun watchFinalized(cb: ((songId: String) -> Unit)?)
    /** Throttled background-transfer chunk deltas. Null clears. */
    fun watchBytes(cb: ((songId: String, delta: Long) -> Unit)?)
}

/** The rips plane slice (production: [com.levi.pocketdj.data.rips.RipsRepository] + coordinator). */
interface MixDownloadRips {
    val hasServer: Boolean
    /** Refresh [hasServer] (a suspend settings read) before the rip lane reads it. */
    suspend fun prepare() {}
    /** The manifest has a public rip for the song (iOS `rips.cachedURL != nil`). */
    fun isRipped(songId: String): Boolean
    fun durationMs(songId: String): Long?
    val manifestCount: Int
    /** POST /rip-collection (or per-song /rip fallback). */
    suspend fun ripCollection(songIds: List<String>)
    /**
     * [ripCollection] that reports whether the server REFUSED the batch (iOS `BatchRipResult.refusedStatus`). The default
     * treats every call as accepted; the production adapter overrides it once the rips plane exposes the status (P2-LIB-1).
     */
    suspend fun requestRips(songIds: List<String>): RipBatchOutcome { ripCollection(songIds); return RipBatchOutcome() }
    /** The import-server token was rejected (401/403) and has not changed since. Read live every lane tick. */
    val isAuthRejected: Boolean get() = false
    /** Automatic callers hold off (a 401 is guaranteed); lapses after the re-probe window, clears on a token change. */
    val authHoldoff: Boolean get() = false
    /** Refresh [isAuthRejected] / [authHoldoff] (suspend settings reads) before the lanes read them. */
    suspend fun refreshAuth() {}
    suspend fun cancelCollection(songIds: List<String>)
    suspend fun refreshManifest()
}

/** The published surface the Mix bottom bar reads. */
data class MixDownloadState(
    val isActive: Boolean = false,
    val sources: List<MixSource> = emptyList(),
    /** M - downloadable tracks in the collection. */
    val totalCount: Int = 0,
    /** N - tracks whose burned file is on disk. */
    val downloadedCount: Int = 0,
    /** Tracks not yet in the rip manifest (server real-time capture; excluded from the ETA). */
    val rippingCount: Int = 0,
    /** Null until the throughput window has a sample. */
    val etaSeconds: Double? = null,
    val downloadedIds: Set<String> = emptySet(),
    /** Non-null exactly when the crates DECLARED more members than resolved (partial catalog). */
    val catalogShortfall: CatalogShortfall? = null,
    /** The shortfall was observed while the catalog was still LOADING (picks the honest caption). */
    val catalogStillLoading: Boolean = false,
    /** Why the lanes can't make progress, or null (read live: a rejected token outranks what the rip lane last saw). */
    val laneIssue: LaneIssue? = null,
) {
    val source: MixSource? get() = sources.firstOrNull()
}

data class CatalogShortfall(val declared: Int, val total: Int)

/**
 * Port of iOS `CollectionMixDownloader`: when a COLLECTION is picked to mix, pull its tracks onto
 * the device so the decks see more of it over time. ORCHESTRATION ONLY over [MixDownloadBurns],
 * [MixDownloadRips] and an [AutoMixHost]; no downloader is invented here.
 *
 * Threading: all state is confined to [scope]'s dispatcher (Main.immediate in production). Hook
 * callbacks that arrive from other threads are re-posted onto [scope].
 */
class CollectionMixDownloader(
    private val scope: CoroutineScope,
    private val burns: MixDownloadBurns,
    private val rips: MixDownloadRips,
    private val host: AutoMixHost,
) {
    // ---- seams wired at app init (tests script them) ------------------------------------------
    /** The collection's downloadable song ids (rip funnel order). */
    var resolveRipIds: ((MixSource) -> List<String>)? = null
    /** The collection's currently LOADABLE tracks ([MixResolver.loadables]). */
    var resolveLoadables: ((MixSource) -> List<MixLoadable>)? = null
    /** A source's crate name (provenance for appended rows). */
    var resolveSourceName: ((MixSource) -> String?)? = null
    var declaredMemberCount: ((MixSource) -> Int)? = null
    /** The device catalog is still loading (picks the shortfall copy: "still loading" only while it actually is). */
    var catalogIsLoading: (() -> Boolean)? = null
    /** Another audio owner (Now Playing's sequencer) is running: a BACKGROUND event must never start a mix over it. */
    var otherAudioActive: (() -> Boolean)? = null
    var catalogSongCount: (() -> Int)? = null
    /** A song's catalog length in seconds (ETA input; manifest duration is the fallback). */
    var songLengthSeconds: ((String) -> Double?)? = null
    var songTitleArtist: ((String) -> Pair<String, String>)? = null
    /** Wall clock in seconds (tests script the rolling window). */
    var now: () -> Double = { System.currentTimeMillis() / 1000.0 }

    // ---- published state ----------------------------------------------------------------------
    private val _state = MutableStateFlow(MixDownloadState())
    val state: StateFlow<MixDownloadState> = _state.asStateFlow()
    val isActive: Boolean get() = _state.value.isActive
    val sources: List<MixSource> get() = _state.value.sources
    val totalCount: Int get() = _state.value.totalCount
    val downloadedCount: Int get() = _state.value.downloadedCount
    val rippingCount: Int get() = _state.value.rippingCount
    val etaSeconds: Double? get() = _state.value.etaSeconds
    val downloadedIds: Set<String> get() = _state.value.downloadedIds
    val catalogShortfall: CatalogShortfall? get() = _state.value.catalogShortfall
    val catalogStillLoading: Boolean get() = _state.value.catalogStillLoading
    /** The live lane issue (a rejected token outranks whatever the rip lane last observed). */
    val laneIssue: LaneIssue? get() = _state.value.laneIssue

    private fun update(f: (MixDownloadState) -> MixDownloadState) { _state.value = f(_state.value) }

    // ---- run internals ------------------------------------------------------------------------
    private var orderedIds: List<String> = emptyList()
    private var trackedIds: Set<String> = emptySet()
    private var window = ThroughputWindow()
    private val burnQueue = ArrayList<String>()
    private var driveJob: Job? = null
    private var ripPollJob: Job? = null
    /** Bumped on every begin/cancel so a cancelled run's tail can never touch the next run. */
    private var runId = 0
    /** Bumped per rip-lane start: an exiting lane only clears its OWN handle. */
    private var ripGeneration = 0
    /** Ids the rip lane is still waiting on (instance state so a catalog re-resolution can feed a RUNNING lane). */
    private val ripPending = LinkedHashSet<String>()
    /** A (re)POST of [ripPending] is due on the lane's next tick (new ids merged in). */
    private var ripRequestDue = false
    /** The lane issue the rip lane last OBSERVED (auth rejection is read live - see [publishLaneIssue]). */
    private var observedLaneIssue: LaneIssue? = null

    private var autoArmed = false
    private var autoStartPending = false
    private var armGestureGeneration = 0
    private var burnMisses = 0
    private var retriedMisses = false
    private var initialAutoIds: Set<String> = emptySet()
    private val appendedIds = LinkedHashSet<String>()
    private var autoLead = 15.0
    private var autoFade = 3.0
    private var autoLabel: String? = null
    private var autoShuffled = false

    // ---- begin / resume -----------------------------------------------------------------------

    fun begin(source: MixSource) = begin(listOf(source))

    /**
     * Start (or resume) downloading. Idempotent per source SET while active; a different set
     * cancels the old run first. A song in several crates is tracked once. Nothing to do
     * (everything on disk, or empty) leaves `isActive=false`.
     */
    fun begin(newSources: List<MixSource>) {
        if (isActive && sources == newSources) return
        if (isActive) cancel()

        val resolved = resolveDownloadable(newSources)
        val ids = resolved.ids
        burnMisses = 0
        retriedMisses = false
        orderedIds = ids
        trackedIds = ids.toSet()
        window = ThroughputWindow()

        // ONE seed pass: on disk = downloaded; the rest partitions into the burn lane
        // (manifest-ready) and the rip lane (needs the server's real-time capture).
        val onDisk = ids.filterTo(LinkedHashSet()) { burns.isOnDisk(it) }
        // Already-present files are an explicit Mix download too: pin them so the TTL sweep never takes them.
        burns.pin(onDisk, "mix-download")
        val remainder = ids.filter { it !in onDisk }
        burnQueue.clear()
        burnQueue.addAll(remainder.filter { rips.isRipped(it) })
        val needsRip = remainder.filter { !rips.isRipped(it) }

        val declared = effectiveDeclared(newSources, resolved)
        observedLaneIssue = null
        ripPending.clear()
        ripRequestDue = false
        val shortfall = declared?.takeIf { it > ids.size }?.let { CatalogShortfall(it, ids.size) }
        update {
            MixDownloadState(
                isActive = false, sources = newSources, totalCount = ids.size,
                downloadedCount = onDisk.size, rippingCount = needsRip.size, etaSeconds = null,
                downloadedIds = onDisk, catalogShortfall = shortfall,
                catalogStillLoading = shortfall != null && catalogIsLoading?.invoke() == true,
            )
        }
        DiagLog.shared?.telemetry(
            "mixdl",
            "begin sources=${newSources.size} total=${ids.size} onDisk=${onDisk.size}" +
                " burnQ=${burnQueue.size} needsRip=${needsRip.size} manifest=${rips.manifestCount}" +
                (declared?.let { " declared=$it" } ?: "") +
                (catalogSongCount?.let { " catalog=${it()}" } ?: ""),
        )
        if (declared != null && declared > 0 && ids.size < declared) {
            DiagLog.shared?.log(
                "warn",
                "mixdl ${declared - ids.size}/$declared crate members unresolved (cross-crate dupes excluded) - partial catalog" +
                    " (catalogLoading=${catalogIsLoading?.invoke()}; re-resolves on the next catalog assign)",
            )
        }
        if (ids.isEmpty() || remainder.isEmpty()) return  // nothing to do - all on disk
        val run = ++runId
        update { it.copy(isActive = true) }
        installHooks()
        if (needsRip.isNotEmpty()) startRipLane(run, needsRip)
        startDrive(run)
    }

    private fun startDrive(run: Int) { driveJob = scope.launch { drive(run) } }

    /** Per-source resolved lists and their cross-crate UNION in first-appearance order. */
    private class Resolved(val ids: List<String>, val perSourceCount: Int)

    private fun resolveDownloadable(srcs: List<MixSource>): Resolved {
        val seen = HashSet<String>()
        val ids = ArrayList<String>()
        var perSource = 0
        for (src in srcs) {
            val own = HashSet<String>()
            for (id in resolveRipIds?.invoke(src).orEmpty()) {
                if (id.isBlank() || !own.add(id)) continue
                perSource++
                if (seen.add(id)) ids.add(id)
            }
        }
        return Resolved(ids, perSource)
    }

    /**
     * The crates' declared member count, CORRECTED for cross-crate overlap. The raw per-crate sum double-counts a song in
     * both crates while the total is the deduped union, so two overlapping fully-resolved crates read as a "partial
     * catalog" (the 2026-10-30 iPad report: 279 + 139 sharing 14 songs -> "Only 404 of 418"). The overlap is exactly
     * sum(per-source resolved) - |union|; subtracting it leaves only members that genuinely failed to resolve.
     */
    private fun effectiveDeclared(srcs: List<MixSource>, resolved: Resolved): Int? {
        val f = declaredMemberCount ?: return null
        val raw = srcs.sumOf { f(it) }
        val overlap = maxOf(0, resolved.perSourceCount - resolved.ids.size)
        return maxOf(0, raw - overlap)
    }

    private fun updateShortfall(declared: Int?, total: Int) {
        val sf = declared?.takeIf { it > total }?.let { CatalogShortfall(it, total) }
        update { it.copy(catalogShortfall = sf, catalogStillLoading = sf != null && catalogIsLoading?.invoke() == true) }
    }

    /**
     * The device catalog was (re)assigned. A run that started while the catalog was partial re-resolves its crates and folds
     * every newly-resolved member in: on disk -> downloaded, ripped -> burn lane (and straight into a running auto mix), un-ripped
     * -> the rip lane. A finished/exhausted mix is never revived by a catalog event (it could start Auto-DJ hours later over
     * Now Playing); only a still-RUNNING mix of ours is fed.
     */
    fun catalogDidChange() {
        val srcs = sources
        if (srcs.isEmpty()) return
        val resolved = resolveDownloadable(srcs)
        val fresh = resolved.ids.filter { it !in trackedIds }
        val declared = effectiveDeclared(srcs, resolved)
        if (fresh.isEmpty()) {
            val had = catalogShortfall
            if (had != null) {
                updateShortfall(declared, totalCount)
                if (catalogShortfall == null) DiagLog.shared?.log("mixdl", "catalog caught up - shortfall ${had.declared - had.total} cleared")
            }
            return
        }
        DiagLog.shared?.log("mixdl", "catalog re-resolve: +${fresh.size} member(s) now in the catalog (total $totalCount -> ${totalCount + fresh.size})")
        if (!isActive) {
            if (!autoArmed || !host.autoMixing || host.autoSourceLabel != autoLabel) {
                updateShortfall(declared, totalCount)
                return
            }
            // OUR mix still runs: re-seed (begin never touches the auto-arm) and feed it the late members.
            begin(srcs)
            continueAutoMixIfArmed(allowRestart = false)
            return
        }
        orderedIds = orderedIds + fresh
        trackedIds = trackedIds + fresh
        val newRips = ArrayList<String>()
        val landed = LinkedHashSet(downloadedIds)
        for (id in fresh) when {
            burns.isOnDisk(id) -> { landed.add(id); burns.pin(listOf(id), "mix-download") }
            rips.isRipped(id) -> burnQueue.add(id)
            else -> newRips.add(id)
        }
        update { it.copy(totalCount = orderedIds.size, downloadedIds = landed, downloadedCount = landed.size) }
        updateShortfall(declared, orderedIds.size)
        val run = runId
        if (newRips.isNotEmpty()) startRipLane(run, newRips)
        if (driveJob?.isActive != true) startDrive(run)
        recomputeEta()
        continueAutoMixIfArmed(allowRestart = false)
    }

    /**
     * Called when an auto mix over this collection starts: seeds the append-dedupe set (the queue
     * already holds [initialIds]) and captures the parameters a later exhaustion re-arm reuses.
     */
    fun noteAutoStarted(
        initialIds: Set<String>, lead: Double, fade: Double, label: String?, shuffled: Boolean = false,
    ) {
        autoArmed = true
        autoShuffled = shuffled
        initialAutoIds = initialIds
        appendedIds.clear()
        autoLead = lead
        autoFade = fade
        autoLabel = label
        // Play on a collection with nothing downloaded: the engine's empty-queue guard meant no mix
        // started - the FIRST landing starts it (the zero-start twin of the exhausted pickup).
        autoStartPending = initialIds.isEmpty() && !host.autoMixing
        armGestureGeneration = host.deckGestureGeneration
    }

    /**
     * The Auto-DJ's deferred start just started the mix: append what landed while it was pending
     * ([AutoDj.onDeferredStartFinished]).
     */
    fun noteAutoStartFinished() = continueAutoMixIfArmed()

    // ---- cancel / leave -----------------------------------------------------------------------

    /** Tear the run down. NEVER touches the engine - a running mix keeps what it has. */
    fun cancel() {
        runId++
        driveJob?.cancel(); driveJob = null
        ripPollJob?.cancel(); ripPollJob = null
        val pending = orderedIds.filter { it !in downloadedIds }
        if (pending.isNotEmpty()) {
            burns.requestStop()
            burns.cancelTransfers(pending)
            host.cancelStreams(pending)
            val stillRipping = pending.filter { !rips.isRipped(it) }
            if (stillRipping.isNotEmpty()) scope.launch { runCatching { rips.cancelCollection(stillRipping) } }
        }
        removeHooks()
        // A cancelled run must never surprise-start (or keep feeding) a mix later.
        autoStartPending = false
        autoArmed = false
        initialAutoIds = emptySet()
        appendedIds.clear()
        autoLabel = null
        autoShuffled = false
        orderedIds = emptyList()
        trackedIds = emptySet()
        burnQueue.clear()
        ripPending.clear()
        ripRequestDue = false
        observedLaneIssue = null
        window = ThroughputWindow()
        _state.value = MixDownloadState()
    }

    /** Mix-tab leave: cancel ONLY when no mix is live. */
    fun handleMixLeave(engineActive: Boolean) {
        if (engineActive) return
        cancel()
    }

    // ---- hooks --------------------------------------------------------------------------------

    private fun installHooks() {
        val run = runId
        burns.watchFinalized { id -> scope.launch { if (run == runId && isActive && id in trackedIds) noteDownloaded(id) } }
        burns.watchBytes { id, delta -> scope.launch { sampleBytes(run, id, delta) } }
        host.setStreamHooks(
            onBytes = { id, delta -> scope.launch { sampleBytes(run, id, delta) } },
            onFailed = { id ->
                scope.launch {
                    if (run != runId || !isActive || id !in trackedIds || id in downloadedIds ||
                        id in burnQueue || !rips.isRipped(id)
                    ) return@launch
                    burnQueue.add(id)
                    if (driveJob?.isActive != true) startDrive(run)
                }
            },
        )
    }

    private fun removeHooks() {
        burns.watchFinalized(null)
        burns.watchBytes(null)
        host.setStreamHooks(null, null)
    }

    private fun sampleBytes(run: Int, id: String, delta: Long) {
        if (run != runId || !isActive || id !in trackedIds || delta <= 0) return
        window.add(delta, now())
        recomputeEta()
    }

    // ---- drive (serial burn lane) -------------------------------------------------------------

    private suspend fun drive(run: Int) {
        var parkedMs = 0L
        while (coroutineContext.isActive && run == runId) {
            runCatching { rips.refreshAuth() }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
            publishLaneIssue()
            if (burnQueue.isNotEmpty() && rips.authHoldoff) {
                // Rejected token: every presign is a guaranteed 401 - park the lane (songs stay queued) instead of burning
                // hundreds of rejections in a row. The hold lapses after the re-probe window (one burn then probes) and
                // clears at once on a token change. Bounded: never parks forever. USER burns bypass this lane entirely.
                if (parkedMs >= authParkMaxMs) {
                    DiagLog.shared?.log("warn", "mixdl burn lane: token still rejected after ${parkedMs / 60_000} min - lane ended (${burnQueue.size} queued)")
                    break
                }
                delay(idleWaitMs * 4)
                parkedMs += idleWaitMs * 4
                continue
            }
            parkedMs = 0
            val id = nextBurnId()
            when {
                id != null -> { burnQueue.remove(id); burnOne(run, id) }
                // Everything left is streaming onto a deck: the stream IS the download.
                burnQueue.isNotEmpty() -> delay(idleWaitMs)
                // The rip lane is still flipping songs ready.
                ripPollJob?.isActive == true -> delay(idleWaitMs)
                !retriedMisses -> {
                    // SECOND SWEEP over presign-timeout victims (state=error after one serial shot).
                    retriedMisses = true
                    val missed = orderedIds.filter { it !in downloadedIds && burns.status(it)?.state == BurnState.ERROR }
                    if (missed.isEmpty()) break
                    DiagLog.shared?.telemetry("mixdl", "re-queue ${missed.size} missed for a second sweep")
                    burnQueue.addAll(missed)
                }
                else -> break // drained, no rips coming, sweep done
            }
        }
        if (run == runId) { driveJob = null; publishLaneIssue() }
    }

    /** First song the running mix will PLAY (live slot onward), else collection order; never one a deck is streaming. */
    private fun nextBurnId(): String? {
        val queued = burnQueue.toSet()
        for (id in host.autoUpcomingSongIds) if (id in queued && !host.isStreaming(id)) return id
        return burnQueue.firstOrNull { !host.isStreaming(it) }
    }

    private suspend fun burnOne(run: Int, id: String) {
        if (id in downloadedIds) return
        // A USER collection burn owns the BurnStore serial loop - wait rather than interleave.
        while (burns.userBurnActive) {
            delay(idleWaitMs)
            if (!coroutineContext.isActive || run != runId) return
        }
        val (title, artist) = songTitleArtist?.invoke(id) ?: (id to "")
        burns.pin(listOf(id), "mix-download")
        try {
            burns.burn(id, title, artist)
        } finally {
            burns.pin(listOf(id), "mix-download")
        }
        if (!coroutineContext.isActive || run != runId) return
        if (burns.isOnDisk(id)) {
            // In-process completion: the await WAS the download - sample the landed bytes.
            val bytes = burns.status(id)?.bytes ?: 0L
            if (bytes > 0) window.add(bytes, now())
            noteDownloaded(id)
        } else {
            val st = burns.status(id)
            // A background transfer still in flight is not a miss; its finalize hook lands it.
            if (st?.state == BurnState.QUEUED || st?.state == BurnState.DOWNLOADING) {
                recomputeEta()
                return
            }
            if (rips.isAuthRejected && id !in burnQueue) {
                // Not this song's fault - the credential is. Keep it queued (front) so it lands the moment the token heals.
                burnQueue.add(0, id)
            }
            burnMisses++
            if (burnMisses <= 5 || burnMisses % 25 == 0) {
                DiagLog.shared?.log(
                    "error",
                    "mixdl burn MISS #$burnMisses $id: ${st?.error ?: "no item recorded"} state=${st?.state?.name?.lowercase() ?: "nil"}",
                )
            }
            recomputeEta()
        }
    }

    // ---- rip lane ------------------------------------------------------------------------------

    /** Start the rip lane for [ids], or feed them into the running one. */
    private fun startRipLane(run: Int, ids: List<String>) {
        ripPending.addAll(ids)
        ripRequestDue = true
        if (ripPollJob?.isActive != true) {
            val gen = ++ripGeneration
            ripPollJob = scope.launch { ripAndPoll(run, gen) }
        }
    }

    /**
     * Enqueue + manifest poll with a WATCHDOG. The old lane POSTed once, ignored the answer and polled for 2 h: a refused batch
     * (every call 401'd on the 2026-10-30 iPad) read as "4 ripping" forever. Now every (re)request's outcome is classified:
     *  - refused (401/403 -> [LaneIssue.TokenRejected], other -> [LaneIssue.RipServerRefused]): retry on an exponential backoff,
     *    and never while the auth holdoff says a 401 is guaranteed;
     *  - accepted: clear the issue, then the stall watchdog - no manifest flip for [ripStallTicks] => [LaneIssue.RipsStalled]
     *    plus a re-POST (the server dedupes, so a re-request of a healthy job is a no-op);
     *  - no server: [LaneIssue.NoServer], still poll the public manifest (another device may rip them).
     * A flip moves the song to the burn lane and joins the running mix (it can stream now).
     */
    private suspend fun ripAndPoll(run: Int, gen: Int) {
        runCatching { rips.prepare() }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
        if (!rips.hasServer) {
            DiagLog.shared?.log("error", "mixdl rip lane: ${ripPending.size} tracks need rip but NO SERVER configured")
        } else {
            DiagLog.shared?.telemetry("mixdl", "rip lane start ids=${ripPending.size}")
        }
        var ticks = 0
        var nextRequestTick = 0
        var attempts = 0
        var lastProgressTick = 0
        var accepted = false
        while (ripPending.isNotEmpty() && ticks < ripPollMaxTicks && coroutineContext.isActive && run == runId) {
            runCatching { rips.refreshAuth() }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
            if (!rips.hasServer) {
                observedLaneIssue = LaneIssue.NoServer
            } else {
                if (observedLaneIssue == LaneIssue.NoServer) observedLaneIssue = null
                if ((ripRequestDue || ticks >= nextRequestTick) && !rips.authHoldoff) {
                    ripRequestDue = false
                    val ids = orderedIds.filter { it in ripPending }
                    val outcome = try {
                        rips.requestRips(ids)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        RipBatchOutcome(LaneIssue.TRANSPORT_FAILURE)
                    }
                    if (!coroutineContext.isActive || run != runId) return
                    val status = outcome.refusedStatus
                    if (status != null) {
                        attempts++
                        accepted = false
                        observedLaneIssue = LaneIssue.ofRefusal(status)
                        val delayTicks = LaneIssue.ripRetryDelayTicks(attempts, ripRetryBaseTicks, ripRetryMaxTicks)
                        nextRequestTick = ticks + delayTicks
                        DiagLog.shared?.log(
                            "error",
                            "mixdl rip lane: batch of ${ids.size} REFUSED status=$status attempt=$attempts - retry in $delayTicks ticks",
                        )
                    } else {
                        if (attempts > 0) DiagLog.shared?.log("mixdl", "rip lane: batch of ${ids.size} accepted after $attempts refusal(s)")
                        attempts = 0
                        // A stall re-request stays "stalled" until a song actually lands.
                        if (observedLaneIssue != LaneIssue.RipsStalled) observedLaneIssue = null
                        accepted = true
                        lastProgressTick = ticks
                        nextRequestTick = ticks + ripStallTicks
                    }
                }
            }
            publishLaneIssue()
            ticks++
            delay(ripPollIntervalMs)
            if (!coroutineContext.isActive || run != runId) return
            runCatching { rips.refreshManifest() }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
            if (!coroutineContext.isActive || run != runId) return
            var flipped = false
            for (id in orderedIds) {
                if (id in ripPending && rips.isRipped(id)) {
                    ripPending.remove(id)
                    burnQueue.add(id)
                    flipped = true
                }
            }
            if (flipped) {
                lastProgressTick = ticks
                if (observedLaneIssue == LaneIssue.RipsStalled) observedLaneIssue = null
                if (accepted) nextRequestTick = ticks + ripStallTicks
                if (driveJob?.isActive != true) startDrive(run)
            } else if (accepted && ripPending.isNotEmpty() && ticks - lastProgressTick >= ripStallTicks &&
                observedLaneIssue != LaneIssue.RipsStalled
            ) {
                observedLaneIssue = LaneIssue.RipsStalled
                DiagLog.shared?.log(
                    "warn",
                    "mixdl rip lane STALLED: ${ripPending.size} pending, no rip landed in ${ticks - lastProgressTick} ticks - re-requesting",
                )
            }
            recomputeEta()
            // A freshly-ripped song is STREAMABLE now: it can join the mix without its download.
            if (flipped) continueAutoMixIfArmed()
        }
        if (ripPending.isNotEmpty() && ticks >= ripPollMaxTicks) {
            DiagLog.shared?.log("warn", "mixdl rip lane gave up after $ticks ticks - ${ripPending.size} never ripped")
        }
        if (gen == ripGeneration && run == runId) { ripPollJob = null; publishLaneIssue() }
    }

    /** Publish the live lane issue: a rejected token (read live, so a heal or re-typed token clears it instantly) outranks the rip lane's last observation. */
    private fun publishLaneIssue() {
        val live = if (!isActive) null else if (rips.isAuthRejected) LaneIssue.TokenRejected else observedLaneIssue
        if (_state.value.laneIssue != live) update { it.copy(laneIssue = live) }
    }

    // ---- landing -> progress + progressive eligibility -----------------------------------------

    private fun noteDownloaded(id: String) {
        val s = _state.value
        if (!s.isActive || id !in trackedIds || id in s.downloadedIds) return
        val ids = s.downloadedIds + id
        update { it.copy(downloadedIds = ids, downloadedCount = ids.size) }
        if (ids.size == 1 || ids.size % 25 == 0) {
            DiagLog.shared?.telemetry("mixdl", "landed ${ids.size}/${s.totalCount} rip=${s.rippingCount}")
        }
        recomputeEta()
        continueAutoMixIfArmed()
        if (ids.size >= s.totalCount) finishRun()
    }

    /**
     * A landing makes the track mixable NOW. If OUR auto mix runs (label ownership), append every
     * newly-loadable track (random when shuffled); if it ended exhausted - or a zero-start is
     * pending - (re)start it with the late arrivals. A DJ hand-mixing owns the decks.
     */
    private fun continueAutoMixIfArmed(allowRestart: Boolean = true) {
        val resolve = resolveLoadables
        if (!autoArmed || sources.isEmpty() || resolve == null) return
        val seen = HashSet<String>()
        val fresh = ArrayList<Triple<MixLoadable, String?, String>>()
        for (source in sources) {
            val label = resolveSourceName?.invoke(source)
            for (l in resolve(source)) {
                if (seen.add(l.songId) && l.songId !in initialAutoIds && l.songId !in appendedIds) fresh.add(Triple(l, label, source.collectionId))
            }
        }
        if (fresh.isEmpty()) return
        // A start between its setup and its first deck load: never re-start it, never mark anything appended -
        // [noteAutoStartFinished] appends these once it runs.
        if (host.autoStartPending) return
        if (host.autoMixing) {
            autoStartPending = false
            if (host.autoSourceLabel != autoLabel) return // someone else's mix
            for ((l, label, origin) in fresh) {
                host.autoQueueInsert(
                    AutoMixItem(l, l.lengthMs ?: FALLBACK_DURATION_MS, label, origin),
                    if (autoShuffled) AutoPlacement.RANDOM else AutoPlacement.END,
                )
                appendedIds.add(l.songId)
            }
        } else if (allowRestart && (host.autoEndedExhausted || autoStartPending)) {
            // Now Playing owns the audio (the "Play in Now Playing" hand-off, or the user moved on): a background
            // landing must never start Auto-DJ over it.
            if (otherAudioActive?.invoke() == true) {
                autoStartPending = false
                return
            }
            if (host.isRunning || (autoStartPending && host.deckGestureGeneration != armGestureGeneration)) {
                autoStartPending = false
                return
            }
            autoStartPending = false
            for ((l, _, _) in fresh) appendedIds.add(l.songId)
            host.startAutoMix(
                fresh.map { (l, label, origin) -> AutoMixItem(l, l.lengthMs ?: FALLBACK_DURATION_MS, label, origin) },
                shuffled = false, lead = autoLead, fade = autoFade, label = autoLabel,
            )
        }
    }

    private fun finishRun() {
        driveJob?.cancel(); driveJob = null
        ripPollJob?.cancel(); ripPollJob = null
        burnQueue.clear()
        ripPending.clear()
        observedLaneIssue = null
        removeHooks()
        update { it.copy(rippingCount = 0, etaSeconds = null, isActive = false, laneIssue = null) }
    }

    // ---- ETA -----------------------------------------------------------------------------------

    /** ETA over the remaining MANIFEST-READY tracks; rip-pending ids surface as `rippingCount`. */
    private fun recomputeEta() {
        var remaining = 0.0
        var ripping = 0
        val done = downloadedIds
        for (id in orderedIds) {
            if (id in done) continue
            if (!rips.isRipped(id)) { ripping++; continue }
            remaining += songLengthSeconds?.invoke(id) ?: rips.durationMs(id)?.let { it / 1000.0 } ?: FALLBACK_TRACK_SECONDS
        }
        val eta = if (remaining > 0) etaSeconds(remaining, window.bytesPerSecond(now())) else null
        update { it.copy(rippingCount = ripping, etaSeconds = eta) }
    }

    // ---- test seams ----------------------------------------------------------------------------
    internal fun simulateLandingForTesting(id: String, bytes: Long = 0) {
        if (bytes > 0) window.add(bytes, now())
        noteDownloaded(id)
    }
    internal fun addThroughputSampleForTesting(bytes: Long) { window.add(bytes, now()); recomputeEta() }
    internal val burnQueueForTesting: List<String> get() = burnQueue.toList()
    internal val appendedIdsForTesting: Set<String> get() = appendedIds.toSet()
    internal val autoArmedForTesting: Boolean get() = autoArmed
    internal val autoStartPendingForTesting: Boolean get() = autoStartPending
    internal val ripPendingForTesting: Set<String> get() = ripPending.toSet()
    internal val nextBurnIdForTesting: String? get() = nextBurnId()

    // ---- tunables + pure helpers ---------------------------------------------------------------

    /** 30-second rolling window of observed download throughput. */
    class ThroughputWindow {
        private val samples = ArrayList<Pair<Double, Long>>()
        fun add(bytes: Long, at: Double) { samples.add(at to bytes); prune(at) }
        private fun prune(at: Double) { samples.removeAll { it.first < at - SPAN } }
        /** Sum / actual span (capped at the window, floored at 1 s). Null until a sample lands. */
        fun bytesPerSecond(at: Double): Double? {
            prune(at)
            val oldest = samples.firstOrNull()?.first ?: return null
            val span = maxOf(minOf(at - oldest, SPAN), 1.0)
            return samples.sumOf { it.second }.toDouble() / span
        }
        companion object { const val SPAN = 30.0 }
    }

    var ripPollIntervalMs = 4500L
    var ripPollMaxTicks = 1600
    var idleWaitMs = 500L
    /**
     * Rip-lane watchdog: an ACCEPTED batch with no manifest flip for this many poll ticks is stalled (~10 min at 4.5 s; one
     * real-time capture is ~4 min) -> re-POST the still-pending ids and say so.
     */
    var ripStallTicks = 133
    /** Refused-batch retry backoff, in poll ticks: base * 2^(attempt-1), capped (~5 min). */
    var ripRetryBaseTicks = 2
    var ripRetryMaxTicks = 67
    /** Max continuous time the burn lane parks on a rejected token before ending (cheap - no network - but never unbounded). */
    var authParkMaxMs = 2L * 60 * 60 * 1000

    companion object {
        /** 256 kbps MP3 = 32 KB of file per playback second. */
        const val BYTES_PER_PLAYBACK_SECOND = 32_768.0
        const val FALLBACK_TRACK_SECONDS = 180.0
        private const val FALLBACK_DURATION_MS = 180_000

        fun etaSeconds(remainingPlaybackSeconds: Double, bytesPerSecond: Double?): Double? {
            val bps = bytesPerSecond ?: return null
            return remainingPlaybackSeconds * BYTES_PER_PLAYBACK_SECOND / maxOf(bps, 1.0)
        }

        /** Honest bar copy (see [LaneIssue.rippingLabel]). */
        fun rippingLabel(count: Int, issue: LaneIssue?): String? = LaneIssue.rippingLabel(count, issue)

        /** "3m 20s" / "45s" / "-" (em dash) while no sample. */
        fun etaLabel(seconds: Double?): String {
            if (seconds == null || !seconds.isFinite() || seconds < 0) return "—"
            val t = Math.round(seconds).toInt()
            return if (t >= 60) "${t / 60}m ${t % 60}s" else "${t}s"
        }
    }
}

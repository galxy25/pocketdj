package com.levi.pocketdj.screens.foryou

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.levi.pocketdj.data.applemusic.DefaultAppleMusicTokens
import com.levi.pocketdj.data.discover.DiscoverAddsStore
import com.levi.pocketdj.data.recs.AppleMusicReleaseTransport
import com.levi.pocketdj.data.recs.LikeAddAttempt
import com.levi.pocketdj.data.recs.LikeAddState
import com.levi.pocketdj.data.recs.LikedReleaseHydration
import com.levi.pocketdj.data.recs.LikedRelease
import com.levi.pocketdj.data.recs.LikedReleaseSelection
import com.levi.pocketdj.data.recs.LikedReleasesStore
import com.levi.pocketdj.data.recs.ReleaseFeedTransport
import com.levi.pocketdj.di.AppGraph
import com.levi.pocketdj.screens.discover.AlbumAddIntent
import com.levi.pocketdj.screens.discover.DiscoverAlbumHit
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

// ============================================================================
// The add port (the seam tests fake)
// ============================================================================

/**
 * What one album add did, with the failure text carried IN the value (iOS `ReleaseAddReport`). Per-call, so
 * several adds in flight (Add all, a double-tapped pair, the sweep racing a tap) each show their OWN reason.
 */
data class ReleaseAddReport(
    /** The Apple Music library-write token (`LibraryWrite`): "confirmed (web)" / "Apple Music write failed: ...". */
    val writeToken: String?,
    /** The provisional album + tracks were recorded - i.e. the release now counts as OWNED. */
    val recorded: Boolean,
    /** The user-facing reason when something needs his attention; null when clean. */
    val error: String?,
) {
    val writeProven: Boolean get() = DiscoverAddsStore.provenByToken(writeToken)
}

/**
 * What the like-adder needs from the outside world: ONE album add, ONE write-only retry, and whether a
 * nothing-recorded failure looks like "no connection". An interface so the unit tests drive the whole state
 * machine with a counting fake and never touch the network or `DiscoverAddController`.
 */
interface ReleaseAddPort {
    suspend fun add(release: LikedRelease): ReleaseAddReport
    /** Re-run ONLY the Apple Music write for an album that is already recorded. */
    suspend fun retryWrite(release: LikedRelease): ReleaseAddReport
    val isOffline: Boolean
}

/** Pure wording, mirroring iOS `RipsStore.libraryWriteNotice` so a failure reads as it does elsewhere. */
object LikeAddWording {
    const val NOT_CONFIRMED = "Added to PocketDJ — the Apple Music add isn’t confirmed"

    /** The notice a write token owes the listener; null for a proven write. */
    fun libraryNotice(token: String?): String? = when {
        DiscoverAddsStore.provenByToken(token) -> null
        token == null -> NOT_CONFIRMED
        token.startsWith("Apple Music write failed: ") ->
            "Added to PocketDJ, but the Apple Music library add failed: ${token.removePrefix("Apple Music write failed: ")}"
        token.startsWith("Apple Music write skipped: ") ->
            "Added to PocketDJ only — ${token.removePrefix("Apple Music write skipped: ")}."
        else -> NOT_CONFIRMED
    }
}

/**
 * Production port: the Discover add's own controller, `LIBRARY_ONLY` - a like NEVER captures audio (Levi
 * reported on 2026-08-07 that an album add on New started ripping). Reached through the existing
 * `BrowseGraph.discoverController`; nothing in `BrowseGraph` changes.
 */
class DiscoverReleaseAddPort(
    private val controller: com.levi.pocketdj.screens.discover.DiscoverAddController,
    private val adds: DiscoverAddsStore,
    private val online: () -> Boolean,
) : ReleaseAddPort {
    override suspend fun add(release: LikedRelease): ReleaseAddReport {
        // Already recorded (an earlier add, another path) with an unproven write: the heal is the write
        // alone. Re-running the whole add would re-expand the tracks to change nothing.
        val existing = adds.albumByAppleMusicId(release.storeId)
        if (existing != null && !DiscoverAddsStore.provenByToken(existing.libraryWrite)) return retryWrite(release)
        val hit = DiscoverAlbumHit(
            appleMusicId = release.storeId, albumId = "amrec_album_${release.storeId}",
            title = release.title.orEmpty(), artist = release.artistName,
            artworkUrl = NewReleasesPresentation.artworkUrl(release.artworkUrl, 600),
            trackCount = release.trackCount, url = NewReleasesPresentation.albumUrl(release.storeId),
        )
        val o = controller.addAlbum(hit, AlbumAddIntent.LIBRARY_ONLY)
        return ReleaseAddReport(
            writeToken = o.libraryWrite, recorded = o.accepted,
            error = if (o.accepted) LikeAddWording.libraryNotice(o.libraryWrite) else o.error,
        )
    }

    override suspend fun retryWrite(release: LikedRelease): ReleaseAddReport {
        val token = controller.retryAlbumLibraryWrite("amrec_album_${release.storeId}", release.storeId)
        return ReleaseAddReport(token, recorded = true, error = LikeAddWording.libraryNotice(token))
    }

    override val isOffline: Boolean get() = !online()
}

// ============================================================================
// The adder
// ============================================================================

/**
 * A thumbs-up on a For You > New row ADDS THE RECORD, and anything he liked but never added can be added from
 * "Liked - not added" (iOS `NewReleaseLikeAdder`; design: docs/design/foryou-new-like-adds.md).
 * Screen-independent: a process singleton on the app scope, so leaving the screen mid-add cancels nothing.
 *
 * THE RULES
 *  - The verdict is recorded FIRST by `RecFeedbackButtons` and is never rolled back by a failed add: the taste
 *    signal and the collection are two different things he asked for.
 *  - An add runs ONCE per thumbs-up: the button only calls [liked] when the verdict landed ACCEPTED (an undo
 *    never adds), and the in-flight guard swallows a double tap.
 *  - Un-thumbs-up never removes anything from the library; it only cancels an add still QUEUED.
 *  - Offline adds retry by themselves ([sweep]); real failures wait for his Retry tap.
 *  - Old likes are only SURFACED with an Add button - never bulk-added silently.
 */
class NewReleaseLikeAdder(
    val store: LikedReleasesStore,
    private val port: ReleaseAddPort,
    private val transport: ReleaseFeedTransport? = null,
    private val scope: CoroutineScope,
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    /** What is busy right now. `queued` = waiting behind Add all (or the one hop after a thumbs-up). */
    data class Busy(
        val inFlight: Set<String> = emptySet(),
        val queued: Set<String> = emptySet(),
        val addingAll: Boolean = false,
    ) {
        val ids: Set<String> get() = inFlight + queued
    }

    private val lock = Any()
    private val _busy = MutableStateFlow(Busy())
    val busy: StateFlow<Busy> = _busy.asStateFlow()

    /** Is this release owned by ANY path? The SAME probes the feed uses (set at composition). */
    @Volatile var isOwned: ((LikedRelease) -> Boolean)? = null

    /** The accepted `new`-scope verdicts, for pruning and the "still liked?" checks. */
    @Volatile var acceptedProvider: (() -> Map<String, Double>)? = null

    private inline fun mutateBusy(f: (Busy) -> Busy) = synchronized(lock) { _busy.value = f(_busy.value) }

    // ---- thumbs-up ----

    /**
     * A thumbs-up landed ACCEPTED on a New row: remember the release and add it. Null for a row with no release
     * id (a `relartist:` like stays pure feedback). The id goes into `queued` SYNCHRONOUSLY, so the row is
     * already busy on the very next render instead of flashing in Liked with an idle Add button.
     */
    fun liked(entry: com.levi.pocketdj.data.recs.ArtistReleaseEntry): Job? {
        // A fresh thumbs-up starts a fresh attempt history (the old one belongs to an earlier like).
        val rel = LikedRelease.from(entry, clock())?.copy(attempt = null) ?: return null
        store.upsert(rel)
        // Owned by another path already: nothing to add (Retry-Apple-Music is the Liked section's job).
        if (isOwned?.invoke(rel) == true) return null
        val id = rel.storeId
        mutateBusy { it.copy(queued = it.queued + id) }
        return scope.launch {
            // An un-thumbs-up between the tap and this hop (or a queue cleared since) cancels the add.
            val still = synchronized(lock) { id in _busy.value.queued } && stillAccepted(id)
            if (!still) { mutateBusy { it.copy(queued = it.queued - id) }; return@launch }
            run(id, writeOnly = false)
        }
    }

    /** Un-thumbs-up: cancel an add still queued. Never touches the library; an in-flight add completes. */
    fun unliked(storeId: String) = mutateBusy { it.copy(queued = it.queued - storeId) }

    private fun stillAccepted(storeId: String): Boolean =
        acceptedProvider?.invoke()?.let { "rel:$storeId" in it } ?: true

    // ---- row buttons ----

    /** Add / Retry on a Liked row. [writeOnly] = the album is recorded and only the Apple Music write is owed. */
    suspend fun add(storeId: String, writeOnly: Boolean = false) = run(storeId, writeOnly)

    suspend fun retry(storeId: String, writeOnly: Boolean = false) = run(storeId, writeOnly)

    /**
     * "Add all (n)": one at a time - kinder to the Apple edge limiter (the feed measured 429 bursts) and it keeps
     * error-to-row attribution exact. Skips in-flight and owned items; an un-thumbs-up while a row waits drops it.
     */
    suspend fun addAll(storeIds: List<String>, writeOnly: Set<String> = emptySet()) {
        val started = synchronized(lock) {
            if (_busy.value.addingAll) false else {
                _busy.value = _busy.value.copy(
                    addingAll = true, queued = _busy.value.queued + storeIds.filter { it !in _busy.value.inFlight },
                )
                true
            }
        }
        if (!started) return
        try {
            for (id in storeIds) {
                val go = synchronized(lock) {
                    val b = _busy.value
                    if (id !in b.queued) false else { _busy.value = b.copy(queued = b.queued - id); true }
                }
                if (!go) continue
                if (id in _busy.value.inFlight || !stillAccepted(id)) continue
                val rel = store.releases[id]
                if (rel != null && isOwned?.invoke(rel) == true && id !in writeOnly) continue
                run(id, id in writeOnly)
            }
        } finally {
            mutateBusy { it.copy(addingAll = false, queued = it.queued - storeIds.toSet()) }
        }
    }

    // ---- the one add ----

    private suspend fun run(storeId: String, writeOnly: Boolean) {
        val rel = store.releases[storeId] ?: return
        val claimed = synchronized(lock) {
            val b = _busy.value
            if (storeId in b.inFlight) false else {
                _busy.value = b.copy(inFlight = b.inFlight + storeId, queued = b.queued - storeId)
                true
            }
        }
        if (!claimed) return
        try {
            store.setAttempt(
                storeId,
                LikeAddAttempt(clock(), LikeAddState.ADDING, null, rel.attempt?.writeToken, rel.attempt?.recorded),
            )
            val report = try {
                if (writeOnly) port.retryWrite(rel) else port.add(rel)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ReleaseAddReport(null, recorded = false, error = e.message ?: GENERIC_FAILURE)
            }
            val now = clock()
            val outcome = state(report, rel.releaseAtMs, now, offline = port.isOffline)
            store.setAttempt(
                storeId,
                LikeAddAttempt(now, outcome.state, outcome.message, report.writeToken, report.recorded),
            )
        } finally {
            mutateBusy { it.copy(inFlight = it.inFlight - storeId) }
        }
    }

    // ---- sweep + hydration ----

    /**
     * Retry what can't have failed for a reason of his: OFFLINE items, and pre-orders whose release day has
     * arrived. At most once per item per 6 h, sequentially, never FAILED items (those wait for his Retry tap),
     * never an item he has since un-thumbed or now owns. Returns how many ran.
     */
    suspend fun sweep(nowMs: Double = clock()): Int {
        val accepted = acceptedProvider?.invoke()
        if (accepted != null) {
            // Prune rows whose verdict is gone. Never one that's mid-add.
            val keep = accepted.keys.mapNotNull(LikedReleaseSelection::storeId).toSet() + _busy.value.inFlight
            store.prune(keep)
        }
        var ran = 0
        for (rel in store.releases.values.sortedBy { it.storeId }) {
            val a = rel.attempt ?: continue
            if (rel.storeId in _busy.value.inFlight || rel.tombstoned == true) continue
            val due = when (a.state) {
                LikeAddState.OFFLINE -> true
                LikeAddState.AWAITING_RELEASE -> (rel.releaseAtMs ?: Double.POSITIVE_INFINITY) <= nowMs
                else -> false
            }
            if (!due || nowMs - a.atMs < SWEEP_THROTTLE_MS) continue
            if (accepted != null && "rel:${rel.storeId}" !in accepted) continue
            if (isOwned?.invoke(rel) == true && a.state == LikeAddState.OFFLINE) continue
            run(rel.storeId, writeOnly = false)
            ran++
        }
        return ran
    }

    /**
     * Fetch metadata for accepted `rel:` ids the cache has never seen (older likes, another device's, a lost
     * cache) - batches of 50, on the feed's own transport. Never called from a render path.
     */
    suspend fun hydrateMissing(accepted: Map<String, Double>): Int {
        val t = transport ?: return 0
        if (!t.canSync) return 0
        val missing = accepted.keys.mapNotNull(LikedReleaseSelection::storeId)
            .filter { store.releases[it] == null }.sorted()
        if (missing.isEmpty()) return 0
        var got = 0
        for (batch in missing.chunked(LikedReleaseHydration.IDS_PER_REQUEST)) {
            val found = LikedReleaseHydration.fetch(batch, t, likedAtMs = { accepted["rel:$it"] }) ?: continue
            store.upsert(found)
            got += found.size
        }
        return got
    }

    // ---- outcome -> state (pure, the table in the design section 1.3) ----

    data class Outcome(val state: LikeAddState, val message: String?)

    companion object {
        const val OFFLINE_MESSAGE = "Will add when you’re back online"
        const val GENERIC_FAILURE = "Couldn’t add this record — try again."
        /** A release is retried by the sweep at most once per this window. */
        const val SWEEP_THROTTLE_MS = 6 * 3_600_000.0

        /**
         * Every row of the outcome table:
         *  - recorded + proven write -> ADDED
         *  - recorded + a skip on a device that cannot write at all ([canWrite] false) -> ADDED
         *  - recorded + unproven write -> FAILED with the library notice (Retry re-runs only the write)
         *  - nothing recorded, release in the future -> AWAITING_RELEASE (a pre-order: tried now, re-run on
         *    release day, whether or not the write landed)
         *  - nothing recorded, offline -> OFFLINE (the sweep retries)
         *  - nothing recorded, anything else -> FAILED with the honest message
         */
        fun state(
            report: ReleaseAddReport,
            releaseAtMs: Double?,
            nowMs: Double,
            offline: Boolean = false,
            canWrite: Boolean = true,
        ): Outcome {
            if (report.recorded) {
                if (report.writeProven) return Outcome(LikeAddState.ADDED, null)
                val skipped = report.writeToken?.startsWith("Apple Music write skipped") == true
                if (skipped && !canWrite) return Outcome(LikeAddState.ADDED, null)
                return Outcome(LikeAddState.FAILED, report.error ?: LikeAddWording.libraryNotice(report.writeToken))
            }
            if (releaseAtMs != null && releaseAtMs > nowMs) return Outcome(LikeAddState.AWAITING_RELEASE, null)
            if (offline) return Outcome(LikeAddState.OFFLINE, OFFLINE_MESSAGE)
            return Outcome(LikeAddState.FAILED, report.error ?: GENERIC_FAILURE)
        }

        @Volatile private var instance: NewReleaseLikeAdder? = null

        /**
         * The process singleton. Touches the release feed (it reads its file on first use), so call off Main.
         * Built here, not in `BrowseGraph`, so this feature adds no lines to the file the parity branch edits.
         */
        fun get(graph: AppGraph): NewReleaseLikeAdder = instance ?: synchronized(this) {
            instance ?: build(graph).also { instance = it }
        }

        private fun build(graph: AppGraph): NewReleaseLikeAdder {
            val browse = graph.browseGraph
            val feed = browse.releaseFeed
            val scope = graph.appScope + Dispatchers.IO
            // The feed's own transport shape (token plumbing, debug base), over a synchronous mirror of
            // "Apple Music is signed in": its `canSync` is read off suspend paths.
            val signedIn = AtomicBoolean(false)
            scope.launch { graph.settings.settings.map { it.hasAppleMusic }.distinctUntilChanged().collect { signedIn.set(it) } }
            val transport = AppleMusicReleaseTransport(
                http = graph.httpClient,
                tokens = DefaultAppleMusicTokens(graph.musicKitDevTokenClient, graph.settings),
                canSyncProvider = { signedIn.get() },
                baseOverride = { if (com.levi.pocketdj.BuildConfig.DEBUG) com.levi.pocketdj.data.applemusic.AppleMusicApi.debugBase else null },
            )
            val store = LikedReleasesStore(File(graph.appContext.filesDir, LikedReleasesStore.FILE_NAME))
            val port = DiscoverReleaseAddPort(browse.discoverController, browse.discoverAdds) { isOnline(graph.appContext) }
            return NewReleaseLikeAdder(store, port, transport, scope).also { a ->
                a.isOwned = { rel ->
                    feed.ownsRelease?.invoke(rel.identity) == true ||
                        (rel.title?.let { feed.ownsReleaseVersion?.invoke(rel.artistId ?: 0, rel.artistName, it) } == true)
                }
                a.acceptedProvider = { browse.recFeedbackStore.acceptedInScope(NewReleasesPresentation.SCOPE) }
            }
        }

        /** Optimistic: an unreadable network state (no permission, no service) reads as online. */
        private fun isOnline(context: Context): Boolean = runCatching {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return@runCatching false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }.getOrDefault(true)
    }
}

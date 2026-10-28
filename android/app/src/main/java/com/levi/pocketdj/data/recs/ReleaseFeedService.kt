package com.levi.pocketdj.data.recs

import java.io.File
import java.io.IOException
import kotlin.math.min
import kotlin.math.pow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * How the feed reaches Apple Music. Injected so the TTL policy and parsing are testable with no
 * network, and so a build with no Apple Music credentials supplies none (service still loads its cache).
 */
interface ReleaseFeedTransport {
    /** Apple Music is on and authorised; the single gate for every fetch. */
    val canSync: Boolean

    /** GET [url] and return the body; throws [ReleaseFeedTransportError] (or [IOException]). */
    suspend fun fetch(url: String): String
}

/**
 * What went wrong reaching the catalog, in the only detail the retry policy needs. 429 and 5xx are worth
 * waiting out; everything else (400 bad id list, 401/403 revoked token) fails identically five times over
 * while spending budget against an already-unhappy limiter - and a failed batch re-queues.
 */
sealed class ReleaseFeedTransportError(message: String) : Exception(message) {
    class Http(val status: Int) : ReleaseFeedTransportError("HTTP $status")
    class Unavailable : ReleaseFeedTransportError("Apple Music unavailable")

    val isRetryable: Boolean
        get() = when (this) {
            is Http -> status == 429 || status in 500..599
            is Unavailable -> false
        }
}

/** WHY THE TILE IS EMPTY - so it can say which instead of rendering blank. */
sealed interface ReleaseEmptyReason {
    data object Checking : ReleaseEmptyReason
    data object NotAuthorized : ReleaseEmptyReason
    data class Unreachable(val message: String) : ReleaseEmptyReason
    data object NotCheckedYet : ReleaseEmptyReason
    data object NothingNew : ReleaseEmptyReason

    /** The tile card's one-line note; null for [NothingNew] (the card's own wording is right). */
    val tileNote: String?
        get() = when (this) {
            Checking -> "Checking for new releases…"
            NotAuthorized -> "Apple Music isn’t connected"
            is Unreachable -> "Couldn’t reach Apple Music"
            NotCheckedYet -> "Play something to start checking"
            NothingNew -> null
        }
}

/**
 * The "New" tile's engine: what the artists the owner plays have released in the last 30 days (port of
 * iOS `ReleaseFeedService`).
 *
 *  - ONE endpoint: `GET /v1/catalog/us/artists?ids=<=50&views=latest-release,similar-artists`.
 *  - LAZY, ON-PLAY: [noteArtistPlayed] is the only steady-state trigger; reading ([feed]) is a pure
 *    filter over the cache and never fires HTTP.
 *  - [drain] is single-flight (`isFetching`), which is what makes the 2-in-flight cap GLOBAL: a 429
 *    storm with plays still arriving must not stack drains (measured 12 in flight unguarded).
 *  - A failed batch NEVER stamps TTL clocks (it would blind the feed to those artists for up to 14 d)
 *    and re-queues its ids; it does not re-arm itself (that would spin against an outage).
 *  - Persisted to [file] (`pocketdj-release-feed.json`), atomic tmp+rename.
 *
 * Thread-safety: all mutable state is guarded by [lock]; nothing suspends inside it.
 */
class ReleaseFeedService(
    private val transport: ReleaseFeedTransport?,
    private val file: File?,
    private val scope: CoroutineScope,
    /** Scales EVERY wall-clock wait (debounce + backoff). 1 in production; ~0 in tests. */
    private val timeScale: Double = 1.0,
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
    /** 0..1, for backoff jitter. */
    private val random: () -> Double = { Math.random() },
) {
    private val lock = Any()

    private val entries = HashMap<Int, ArtistReleaseEntry>()
    private var seededAtMs: Double? = null
    private var isFetching = false
    private var isSeeding = false
    private var lastError: String? = null
    private var revision = 0
    private val pending = LinkedHashMap<Int, String>()
    private var drainJob: Job? = null

    private val _revisionFlow = MutableStateFlow(0)
    /** Bumped on every cache mutation so UIs can memo off it instead of the map. */
    val revisionFlow: StateFlow<Int> = _revisionFlow.asStateFlow()

    /** Play counts for the TTL math (injected so this service never owns capture lifecycle). */
    @Volatile var playsForArtist: ((Int) -> Int)? = null

    /**
     * Does the local catalog ALREADY have this release, on ANY identity it carries? Unset = assume
     * nothing is owned (the honest cold-launch default: "owned" would silently empty the feed).
     */
    @Volatile var ownsRelease: ((ReleaseIdentity) -> Boolean)? = null

    /** Does he already have this record in ANOTHER VERSION (Deluxe, remix)? (artistId, artistName, title). */
    @Volatile var ownsReleaseVersion: ((Int, String, String) -> Boolean)? = null

    init {
        load()
    }

    // ---- reading (pure, render-path safe) ---------------------------------------------------

    /**
     * Everything inside the window, classified, newest first, minus what he already has. Ownership is
     * filtered HERE (read time), so an album added today drops out immediately with no refetch.
     */
    fun feed(nowMs: Double = clock()): List<ReleaseFeedItem> {
        val snapshot = synchronized(lock) { entries.values.toList() }
        val own = ownsRelease
        val ownVersion = ownsReleaseVersion
        return snapshot.mapNotNull { e ->
            val at = e.releaseAtMs ?: return@mapNotNull null
            val status = ReleaseFeedPolicy.classify(at, nowMs) ?: return@mapNotNull null
            // No store id = cannot be matched against the catalog OR opened: nothing to do with the row.
            val releaseId = e.releaseId ?: return@mapNotNull null
            val identity = ReleaseIdentity(releaseId, e.artistId, e.artistName, e.releaseName)
            if (own?.invoke(identity) == true) return@mapNotNull null
            val name = e.releaseName
            if (name != null && ownVersion?.invoke(e.artistId, e.artistName, name) == true) return@mapNotNull null
            ReleaseFeedItem(e, status)
        }.sortedByDescending { it.entry.releaseAtMs ?: 0.0 }
    }

    fun outNow(nowMs: Double = clock()): List<ReleaseFeedItem> = feed(nowMs).filter { it.status == ReleaseStatus.OUT_NOW }

    /** Pre-orders, SOONEST first (opposite of [outNow]: for the future, "next" is the useful order). */
    fun comingSoon(nowMs: Double = clock()): List<ReleaseFeedItem> =
        feed(nowMs).filter { it.status == ReleaseStatus.COMING_SOON }.sortedBy { it.entry.releaseAtMs ?: 0.0 }

    /** Flat projection the tile's COUNT reads. */
    fun newReleases(nowMs: Double = clock()): List<ArtistReleaseEntry> = feed(nowMs).map { it.entry }

    /** Similar-artist ids for a set of artists; a cold/stale entry contributes nothing (no fetch). */
    fun similarArtistIds(artistIds: List<Int>): List<Int> {
        val out = ArrayList<Int>()
        val seen = HashSet(artistIds)
        synchronized(lock) {
            for (id in artistIds) for (s in entries[id]?.similarArtistIds.orEmpty()) if (seen.add(s)) out += s
        }
        return out
    }

    val canSync: Boolean get() = transport?.canSync ?: false
    val isFetchingNow: Boolean get() = synchronized(lock) { isFetching }
    val seededAt: Double? get() = synchronized(lock) { seededAtMs }
    val cachedArtistCount: Int get() = synchronized(lock) { entries.size }
    val pendingCount: Int get() = synchronized(lock) { pending.size }
    fun entry(artistId: Int): ArtistReleaseEntry? = synchronized(lock) { entries[artistId] }

    // ---- first population: the one-shot listening seed ---------------------------------------

    /** True only on an install that has never seeded AND has nothing cached - fires once, ever. */
    val needsSeed: Boolean get() = synchronized(lock) { seededAtMs == null && entries.isEmpty() }

    /**
     * Seed from the last 30 days of listening. One shot whatever the outcome: [seededAtMs] is stamped and
     * PERSISTED before the fetch, so a failed seed rides the ordinary re-queue path rather than
     * re-seeding every launch. NOT stamped when [canSync] is false (an unauthorised install must be free
     * to seed the moment Apple Music is turned on). Returns whether a fetch was queued.
     */
    fun seedFromRecentListening(artists: List<Pair<Int, String>>, nowMs: Double = clock()): Boolean {
        synchronized(lock) {
            if (!(seededAtMs == null && entries.isEmpty())) return false
            if (!canSync) return false
            seededAtMs = nowMs
            for ((id, name) in artists) if (entries[id] == null) pending[id] = name
            save()
            if (pending.isEmpty()) return false
            isSeeding = true
            bump()
        }
        scheduleDrain()
        return true
    }

    fun emptyReason(): ReleaseEmptyReason = synchronized(lock) {
        when {
            isSeeding || isFetching -> ReleaseEmptyReason.Checking
            !canSync -> ReleaseEmptyReason.NotAuthorized
            lastError != null -> ReleaseEmptyReason.Unreachable(lastError!!)
            entries.isEmpty() -> ReleaseEmptyReason.NotCheckedYet
            else -> ReleaseEmptyReason.NothingNew
        }
    }

    // ---- the ONLY steady-state trigger: a play happened --------------------------------------

    /** Is a manual re-check available right now? Disabled (never hidden) while busy / off / empty. */
    val canRecheck: Boolean get() = synchronized(lock) { canSync && !isFetching && !isSeeding && entries.isNotEmpty() }

    /**
     * "Check for new releases" from the New screen's overflow: re-queue every cached artist through the
     * ordinary batched drain. TTL is deliberately NOT consulted (a recheck that no-ops because everything
     * is fresh is a dead control). Cannot stack: [scheduleDrain] refuses while one is armed or running.
     */
    fun recheckKnownArtists() {
        synchronized(lock) {
            if (!(canSync && !isFetching && !isSeeding && entries.isNotEmpty())) return
            for ((id, e) in entries) pending[id] = e.artistName
            if (pending.isEmpty()) return
            bump()
        }
        scheduleDrain()
    }

    /**
     * Call from the PLAY event (never a render path). Enqueues the artist if its TTL expired and arms a
     * batched drain. Drains whenever ANYTHING is queued, not only when this artist queued it: a re-queued
     * batch must not stall until one of its own artists happens to be played again.
     */
    fun noteArtistPlayed(artistId: Int, name: String, nowMs: Double = clock()) {
        if (!canSync) return
        val plays = playsForArtist?.invoke(artistId) ?: 0
        val arm = synchronized(lock) {
            if (ReleaseFeedPolicy.isDue(entries[artistId]?.checkedAtMs, plays, nowMs)) pending[artistId] = name
            pending.isNotEmpty()
        }
        if (arm) scheduleDrain()
    }

    /**
     * Arm the debounced drain unless one is already armed OR running. `!isFetching` is load-bearing: the
     * 2-request budget is spent INSIDE one drain, so this guard is the only thing making the cap global.
     * Nothing is lost by not arming - a clean drain re-arms itself for whatever queued while it ran.
     */
    private fun scheduleDrain() {
        synchronized(lock) {
            if (drainJob != null || isFetching) return
            val waitMs = (DRAIN_DEBOUNCE_SECONDS * timeScale * 1000).toLong().coerceAtLeast(0)
            // LAZY then start: the handle is stored before the body can run, even on an inline dispatcher.
            val job = scope.launch(start = CoroutineStart.LAZY) {
                // Let a burst of plays (a set list starting, a shuffle) accumulate into one batch.
                delay(waitMs)
                drain()
            }
            drainJob = job
            job.start()
        }
    }

    /**
     * Fetch every pending artist in batches of 50, two requests in flight - and never beside another
     * drain (`isFetching` is the reentrancy guard; it also keeps the flag honest for the UI).
     */
    suspend fun drain() {
        val batches: List<List<Int>>
        val due: Map<Int, String>
        synchronized(lock) {
            if (isFetching) return
            drainJob = null
            val t = transport
            if (t == null || !t.canSync || pending.isEmpty()) {
                finishSeedingLocked(allSucceeded = false, pass = false)
                return
            }
            due = LinkedHashMap(pending)
            pending.clear()
            isFetching = true
            batches = due.keys.toList().chunked(ReleaseFeedPolicy.IDS_PER_REQUEST)
        }
        var allSucceeded = true
        try {
            val sem = Semaphore(ReleaseFeedPolicy.MAX_CONCURRENT_REQUESTS)
            coroutineScope {
                batches.map { batch ->
                    async {
                        val outcome = sem.withPermit { fetchBatch(batch) }
                        synchronized(lock) {
                            if (!outcome.succeeded) allSucceeded = false
                            apply(outcome, due)
                        }
                    }
                }.awaitAll()
            }
        } finally {
            synchronized(lock) {
                save()
                isFetching = false
            }
        }
        val rearm = synchronized(lock) {
            finishSeedingLocked(allSucceeded, pass = true)
            allSucceeded && pending.isNotEmpty()
        }
        // ONLY on a clean pass: a failed batch re-queues its own ids, so re-arming there would spin
        // against an outage instead of riding the next play (the lazy trigger the feature runs on).
        if (rearm) scheduleDrain()
    }

    private fun finishSeedingLocked(allSucceeded: Boolean, pass: Boolean) {
        // The seed is over once its batches have been through, whatever they returned - the tile must
        // stop saying "Checking…" and say which empty state it is really in.
        if (isSeeding && (pending.isEmpty() || !allSucceeded || !pass)) {
            isSeeding = false
            bump()
        }
    }

    private class BatchOutcome(val ids: List<Int>, val entries: List<ArtistReleaseEntry>, val succeeded: Boolean)

    /** One batch, with backoff (only 429 / 5xx / IO are retried; 5 attempts, exponential + jitter). */
    private suspend fun fetchBatch(ids: List<Int>): BatchOutcome {
        val failed = BatchOutcome(ids, emptyList(), false)
        if (ids.isEmpty()) return BatchOutcome(ids, emptyList(), true)
        val t = transport ?: return failed
        val url = requestUrl(ids)
        for (attempt in 0 until MAX_ATTEMPTS) {
            try {
                val body = t.fetch(url)
                val parsed = ArtistsCatalogResponse.parse(body, clock()) ?: return failed
                return BatchOutcome(ids, parsed, true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val retryable = when (e) {
                    is ReleaseFeedTransportError -> e.isRetryable
                    is IOException -> true // offline / timeout: transient by nature
                    else -> false
                }
                if (!retryable || attempt >= MAX_ATTEMPTS - 1) return failed
                // Exponential plus jitter: the two in-flight batches hit one limiter, and an unjittered
                // schedule would wake them in lockstep - reproducing the burst that caused the 429.
                val base = min(30.0, 2.0.pow(attempt + 1))
                val waitSec = (base + random() * (base / 2)) * timeScale
                delay((waitSec * 1000).toLong().coerceAtLeast(0))
            }
        }
        return failed
    }

    /**
     * Merge one batch into the cache. On SUCCESS an artist Apple returned nothing for still gets its
     * clock stamped (else it is re-requested on every play forever). On FAILURE nothing is stamped and the
     * ids go back on the queue: stamping would blind the feed to up to fifty artists for up to 14 days
     * with no error anywhere. Does NOT re-arm a drain.
     */
    private fun apply(outcome: BatchOutcome, fallbackNames: Map<Int, String>) {
        if (!outcome.succeeded) {
            for (id in outcome.ids) pending[id] = fallbackNames[id] ?: entries[id]?.artistName ?: ""
            lastError = "Couldn't check ${outcome.ids.size} artists for new releases."
            return
        }
        lastError = null
        val now = clock()
        val returned = HashSet<Int>()
        for (raw in outcome.entries) {
            var e = raw
            returned += e.artistId
            if (e.artistName.isEmpty()) e = e.copy(artistName = fallbackNames[e.artistId].orEmpty())
            // Carry a known similar list forward when this response had none: a sparse answer never
            // erases good data.
            if (e.similarArtistIds == null) {
                val prior = entries[e.artistId]
                e = e.copy(similarArtistIds = prior?.similarArtistIds, similarCheckedAtMs = prior?.similarCheckedAtMs)
            }
            entries[e.artistId] = e
        }
        // ONLY this batch's ids: walking the whole due set would let the first batch to return stamp the
        // clocks of artists belonging to batches still in flight (which may then fail).
        for (id in outcome.ids) {
            if (id in returned) continue
            val existing = entries[id]
            entries[id] = existing?.copy(checkedAtMs = now)
                ?: ArtistReleaseEntry(artistId = id, artistName = fallbackNames[id].orEmpty(), checkedAtMs = now)
        }
        bump()
    }

    // ---- durability ---------------------------------------------------------------------------

    private fun bump() {
        revision++
        _revisionFlow.value = revision
    }

    private fun load() {
        val f = file ?: return
        val doc = runCatching { ReleaseFeedDocumentCodec.decode(f.readText()) }.getOrNull() ?: return
        for (e in doc.entries) entries.putIfAbsent(e.artistId, e)
        seededAtMs = doc.seededAtMs
    }

    private fun save() {
        val f = file ?: return
        runCatching {
            val text = ReleaseFeedDocumentCodec.encode(ReleaseFeedDocument(entries.values.toList(), seededAtMs))
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(f)) {
                f.delete()
                if (!tmp.renameTo(f)) lastError = "Couldn't save the release feed."
            }
        }.onFailure { lastError = it.message }
    }

    // ---- test seams ----------------------------------------------------------------------------

    fun resetPendingForTesting() = synchronized(lock) { pending.clear(); drainJob?.cancel(); drainJob = null }

    fun seedForTesting(list: List<ArtistReleaseEntry>) = synchronized(lock) {
        entries.clear()
        for (e in list) entries.putIfAbsent(e.artistId, e)
        bump()
    }

    companion object {
        const val FILE_NAME = "pocketdj-release-feed.json"
        /** A play waits this long before its drain runs, so a burst coalesces into one batch. */
        const val DRAIN_DEBOUNCE_SECONDS = 2.0
        private const val MAX_ATTEMPTS = 5

        /** The one request shape. Commas stay literal (iOS URLQueryItem leaves them). */
        fun requestUrl(ids: List<Int>, base: String = "https://api.music.apple.com"): String =
            "$base/v1/catalog/us/artists?ids=${ids.joinToString(",")}&views=latest-release,similar-artists"


        /** Debug/UI-test canned rows: two out-now releases and one pre-order. */
        fun uiFixtureEntries(nowMs: Double): List<ArtistReleaseEntry> {
            val day = 86_400_000.0
            return listOf(
                ArtistReleaseEntry(900_001, "The Test Pressing", nowMs, "9000000001", "Second Side", nowMs - 2 * day, null, "album", 9),
                ArtistReleaseEntry(900_002, "Dust & Groove", nowMs, "9000000002", "Late Cut", nowMs - 9 * day, null, "single", 2),
                ArtistReleaseEntry(900_003, "Northbound", nowMs, "9000000003", "Preorder EP", nowMs + 6 * day, null, "ep", 5),
            )
        }
    }
}

/** The For You grid's view of the feed (feeds the New tile count / Coming soon count / empty note). */
class ReleaseFeedForYouSource(private val service: ReleaseFeedService) : ForYouReleaseSource {
    override fun feed(nowMs: Double): List<ForYouRelease> =
        service.feed(nowMs).map { ForYouRelease(it.feedbackId, it.status == ReleaseStatus.COMING_SOON) }

    override fun emptyTileNote(): String? = service.emptyReason().tileNote
}

/**
 * The real transport: the Apple Music Web API with the developer token (+ Music-User-Token when signed in),
 * reusing the app's existing token plumbing (no new credential). [canSyncProvider] is a synchronous mirror of
 * "Apple Music is on" because [ReleaseFeedTransport.canSync] is read on non-suspending paths.
 */
class AppleMusicReleaseTransport(
    private val http: okhttp3.OkHttpClient,
    private val tokens: com.levi.pocketdj.data.applemusic.AppleMusicTokens,
    private val canSyncProvider: () -> Boolean,
    /** DEBUG emulator hook: replaces `https://api.music.apple.com` (see AppleMusicApi.debugBase). */
    private val baseOverride: () -> String? = { null },
) : ReleaseFeedTransport {
    override val canSync: Boolean get() = canSyncProvider()

    override suspend fun fetch(url: String): String {
        if (!canSync) throw ReleaseFeedTransportError.Unavailable()
        val dev = try {
            tokens.developerToken()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            throw ReleaseFeedTransportError.Unavailable()
        }
        val mut = try { tokens.musicUserToken() } catch (e: CancellationException) { throw e } catch (_: Throwable) { null }
        val target = baseOverride()?.let { url.replaceFirst("https://api.music.apple.com", it.trimEnd('/')) } ?: url
        val request = try {
            okhttp3.Request.Builder().url(target).get()
                .header("Authorization", "Bearer ${dev.trim()}")
                .apply { if (mut != null) header("Music-User-Token", mut.trim()) }
                .build()
        } catch (_: IllegalArgumentException) {
            throw ReleaseFeedTransportError.Unavailable()
        }
        val (code, body) = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            http.newCall(request).execute().use { it.code to it.body?.string().orEmpty() }
        }
        if (code == 401) runCatching { tokens.invalidateDeveloperToken() }
        if (code !in 200..299) throw ReleaseFeedTransportError.Http(code)
        return body
    }
}

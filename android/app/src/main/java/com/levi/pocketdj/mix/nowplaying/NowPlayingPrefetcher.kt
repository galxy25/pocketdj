package com.levi.pocketdj.mix.nowplaying

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The Stem Lock download lane (iOS `StemLockPrefetcher`): ONE fetch at a time, in plan order, so the
 * next track's whole-song audio never competes with its own stems (or a further-ahead track).
 *
 * [plan] is pure (the ordering contract, unit-tested): whole song FIRST (it is what plays at the
 * boundary), then its ENABLED stems in [StemLock.partPriority] (vocals, drums, other, bass), then the
 * further-ahead tracks, and the muted parts LAST. [apply] runs a plan, keeping an in-flight fetch the
 * new plan still wants and cancelling one it no longer does (a skip, a queue edit, the lock turned
 * off). A failed step is not retried for [failureCooldownMs]. Cloud stem separation for a next track
 * with no stems is requested once per song id (fire-and-forget; playback never waits on it).
 *
 * Main-thread API; the fetches run on [scope] (the seams do their own IO dispatching).
 */
class NowPlayingPrefetcher(
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
) {
    sealed interface Step {
        /** The song id the step downloads for (audio id for a song, row id for a stem). */
        val songId: String

        /** The whole song (`id` = the id playback resolves under). */
        data class Song(val id: String, val title: String, val artist: String) : Step {
            override val songId: String get() = id
            override fun toString() = "song:$id"
        }
        /** One stem part of [songId]. */
        data class StemPart(override val songId: String, val part: String) : Step { override fun toString() = "$part:$songId" }
    }

    /** One queue row as the planner sees it. */
    data class Track(
        val songId: String,
        /** The id the whole-song audio resolves under (an edition-substituted row's variant id). */
        val audioId: String,
        val title: String,
        val artist: String,
        /** The whole song already plays from this device (burned / a finished stream). */
        val songLocal: Boolean,
        /** The whole song can be fetched now (ripped, a rip server, a network path). */
        val songFetchable: Boolean,
        /** Stem parts already on disk. */
        val stemsLocal: Set<String>,
        /** The catalog has stems for it (separated server-side). */
        val stemsRemote: Boolean,
        val source: Source = Source.RIPPED,
    ) {
        /** What kind of row this is (np-mix-mode 2.1); the plan only needs songLocal / songFetchable. */
        enum class Source { LOCAL, RIPPED, APPLE_MUSIC_ONLY, CATALOG_ONLY, LIVE, STUDIO_OR_PROFILE, UNAVAILABLE }
    }

    data class Plan(
        val steps: List<Step> = emptyList(),
        /** Songs to ask the cloud to separate (fire-and-forget). */
        val stemify: List<String> = emptyList(),
        /** Apple-Music-only rows to ask the rip server to capture (step 0; rip-server-configured only). */
        val rips: List<String> = emptyList(),
    )

    /** Everything the Now Playing prefetch plan is a pure function of (np-mix-mode 2.1). */
    data class Input(
        /** The PLAYING row (null when held / not running / a studio or profile row). */
        val current: Track?,
        /** queue[index+1 ...]: at least max(window, stemLockWindow) rows when that many exist. */
        val upcoming: List<Track>,
        val stemLock: StemLockState,
        /** Pass DISABLED while Mix Mode is suspended (a Mix-tab session is live). */
        val mixMode: NpMixModeState = NpMixModeState(),
        val network: NetworkClass = NetworkClass.UNMETERED,
        /** Mix Mode's Wi-Fi window (npMixBufferAhead, default 3). */
        val window: Int = NpMixSettings.DEFAULT_BUFFER_AHEAD,
        /** The Stem Lock's own window (unchanged). */
        val stemLockWindow: Int = 3,
        val cellular: NpMixCellularPolicy = NpMixCellularPolicy.NEXT_SONG,
        /** The current track's carried stems are wired PARTIALLY (its missing enabled parts lead). */
        val currentStemsPartial: Boolean = false,
        /** The listener has the Stems toggle ON for the playing track (cellular: fetched only when asked for). */
        val currentStemsWanted: Boolean = false,
        /**
         * A rip server is configured AND this install may use it (the caller folds ownership in; a public
         * install never enqueues server work). Gates [Plan.rips] and Mix Mode's cloud stem requests.
         */
        val isRipServerConfigured: Boolean = false,
        /** FX Lock carrying a live effect: the window's WHOLE SONGS are made local (no stems). */
        val fxLockSongs: Boolean = false,
    )

    /** State of an explicit download's ledger row. */
    enum class PendingDownload { READY, DOWNLOADING, OTHER }

    /** Mix Mode's reach on a network (iOS StemPolicy). */
    enum class StemPolicy { ALL, ON_REQUEST, NONE }
    data class Reach(val ahead: Int, val stems: StemPolicy)

    // ---- seams (production wiring in MixGraph) ----
    /** Fetch the whole song of a [Step.Song] to the device; true once it plays from there. */
    var fetchSong: suspend (Step.Song) -> Boolean = { false }
    /** Burn one stem part (`BurnStore.burnStemPart`). */
    var fetchStemPart: suspend (songId: String, part: String) -> Boolean = { _, _ -> false }
    /** Ask the cloud to separate a song (fire-and-forget; deduped here per song id). */
    var requestStemify: (String) -> Unit = {}
    var network: () -> NetworkClass = { NetworkClass.UNMETERED }
    /** Ask the rip server to capture an Apple-Music-only row (fire-and-forget; deduped per song id for [ripRetryMs]). */
    var requestRip: (String) -> Unit = {}
    /**
     * DISK GUARD: may this step start? Sweeps temporary assets first when it has to; false = the step is
     * skipped ([blockedCooldownMs]). null = always (tests that don't exercise it).
     */
    var diskGuard: (suspend (Step) -> Boolean)? = null
    /** A step finished (`ok` = its audio is on disk). */
    var onStepFinished: ((Step, Boolean) -> Unit)? = null

    var failureCooldownMs: Long = 120_000
    var blockedCooldownMs: Long = 120_000
    var ripRetryMs: Long = 600_000

    // ---- state ----
    var pending: List<Step> = emptyList(); private set
    var inFlight: Step? = null; private set
    /** Every step STARTED, in order (test seam + diagnostics). */
    val startedLog = ArrayList<Step>()
    private var worker: Job? = null
    private val failedAt = HashMap<Step, Long>()
    private val blockedAt = HashMap<Step, Long>()
    private val ripRequestedAt = HashMap<String, Long>()
    /** Every rip the lane asked for, in order (test seam + diagnostics). */
    val ripLog = ArrayList<String>()
    private val stemifyRequested = HashSet<String>()
    private var lastLoggedOrder: List<Step> = emptyList()

    val isIdle: Boolean get() = worker == null && pending.isEmpty()

    /** Song ids the lane is fetching or about to fetch (in-flight + pending) - the temporary sweep never deletes these. */
    val activeSongIds: Set<String> get() = (listOfNotNull(inFlight) + pending).map { it.songId }.toSet()

    private fun songStepRecently(audioId: String, at: Map<Step, Long>, cooldown: Long): Boolean {
        val t = now()
        return at.any { (s, w) -> s is Step.Song && s.id == audioId && t - w < cooldown }
    }

    /** The whole-song step for [audioId] failed within the cooldown (the indicator's "Download failed"). */
    fun songFailedRecently(audioId: String) = songStepRecently(audioId, failedAt, failureCooldownMs)

    /** The whole-song step for [audioId] was refused by the disk guard within the cooldown ("Storage full"). */
    fun songBlockedRecently(audioId: String) = songStepRecently(audioId, blockedAt, blockedCooldownMs)

    /** [audioId]'s whole song is the step in flight. */
    fun isFetchingSong(audioId: String) = (inFlight as? Step.Song)?.id == audioId

    /** [audioId]'s whole song is planned (in flight or pending). */
    fun isPlannedSong(audioId: String) = (listOfNotNull(inFlight) + pending).any { it is Step.Song && it.id == audioId }

    /** Run [plan]: keep the in-flight fetch if the plan still wants it, otherwise cancel it. */
    fun apply(plan: Plan) {
        for (id in plan.stemify) if (stemifyRequested.add(id)) {
            StemLock.log("stemify request song=$id (next track has no stems)")
            requestStemify(id)
        }
        val t = now()
        for (id in plan.rips) if (ripRequestedAt[id]?.let { t - it >= ripRetryMs } ?: true) {
            ripRequestedAt[id] = t
            ripLog += id
            NpMixMode.log("rip request song=$id (Apple Music only - mixable next play)")
            requestRip(id)
        }
        val steps = plan.steps.filter { s ->
            (failedAt[s]?.let { t - it >= failureCooldownMs } ?: true) && (blockedAt[s]?.let { t - it >= blockedCooldownMs } ?: true)
        }
        val cur = inFlight
        if (cur != null && cur in steps) {
            pending = steps.filter { it != cur }
        } else {
            if (cur != null) StemLock.log("prefetch cancel $cur (no longer planned)")
            worker?.cancel(); worker = null; inFlight = null
            pending = steps
        }
        val order = listOfNotNull(inFlight) + pending
        if (order != lastLoggedOrder) {
            lastLoggedOrder = order
            if (order.isNotEmpty()) StemLock.log("prefetch order net=${network().raw} ${order.joinToString(" -> ")}")
        }
        if (worker == null && pending.isNotEmpty()) startWorker()
    }

    fun cancelAll() {
        if (inFlight != null || pending.isNotEmpty()) StemLock.log("prefetch cancel all")
        worker?.cancel(); worker = null
        inFlight = null
        pending = emptyList()
        lastLoggedOrder = emptyList()
    }

    private fun startWorker() {
        lateinit var job: Job
        job = scope.launch {
            while (isActive) {
                if (pending.isEmpty()) break
                val step = pending.first()
                pending = pending.drop(1)
                inFlight = step // protected from the sweep from here on (activeSongIds)
                val guardFn = diskGuard
                if (guardFn != null) {
                    val allowed = try { guardFn(step) } catch (e: CancellationException) { throw e } catch (_: Exception) { true }
                    // Superseded while the guard ran: the canceller owns the lane's state.
                    if (!isActive) return@launch
                    if (!allowed) {
                        inFlight = null
                        blockedAt[step] = now()
                        StemLock.log("prefetch $step SKIPPED (storage: free space / buffer cap)")
                        onStepFinished?.invoke(step, false)
                        continue
                    }
                }
                startedLog += step
                val t0 = now()
                val ok = try {
                    when (step) {
                        is Step.Song -> fetchSong(step)
                        is Step.StemPart -> fetchStemPart(step.songId, step.part)
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) { false }
                // Superseded - the canceller owns the lane's state. A fetch that LANDED anyway (bytes on
                // disk) is still reported: a re-plan between the write and here must not swallow the
                // playing track's late part.
                if (!isActive) {
                    if (ok) withContext(NonCancellable) { onStepFinished?.invoke(step, true) }
                    return@launch
                }
                inFlight = null
                // A song fetch that "succeeded" (a finished stream that was never adopted as a burn stays non-local)
                // must not be re-planned straight away either: share the failure cooldown, else replan -> fetch ->
                // replan hard-spins the main thread (Final review).
                if (!ok || step is Step.Song) failedAt[step] = now()
                StemLock.log("prefetch $step ${if (ok) "ok" else "FAILED"} ms=${now() - t0}")
                onStepFinished?.invoke(step, ok)
            }
            if (isActive && worker === job) worker = null
        }
        worker = job
    }

    companion object {
        /**
         * THE ORDER. [current]: the playing track when its carried stems are wired PARTIALLY (its missing
         * enabled parts lead - audible the moment they land). Then, per upcoming track within [window]:
         * its whole song (if not already local), then its enabled stems in priority order; the next track
         * gets a cloud stem request when it has none. Muted parts - the current track's included - come
         * LAST, after every track (skipped on a constrained network). A track whose audio cannot be made
         * local is skipped: its stems could never play (Now Playing stems need the full song on the device).
         */
        fun plan(current: Track?, upcoming: List<Track>, carry: StemLockState, network: NetworkClass, window: Int): Plan {
            if (!carry.wantsStems || network == NetworkClass.OFFLINE) return Plan()
            val steps = ArrayList<Step>()
            val stemify = ArrayList<String>()
            val reach = if (network == NetworkClass.UNMETERED) maxOf(0, window) else minOf(1, maxOf(0, window))
            val deferred = ArrayList<Step>()
            fun stems(t: Track) {
                for (p in carry.enabledParts) if (p !in t.stemsLocal) steps += Step.StemPart(t.songId, p)
                if (network == NetworkClass.CONSTRAINED) return
                for (p in carry.disabledParts) if (p !in t.stemsLocal) deferred += Step.StemPart(t.songId, p)
            }
            if (current != null && current.stemsRemote) stems(current)
            for ((i, t) in upcoming.take(reach).withIndex()) {
                val hasStems = t.stemsRemote || t.stemsLocal.size == StemLock.partPriority.size
                if (i == 0 && !hasStems) stemify += t.songId
                if (!(t.songLocal || t.songFetchable)) continue
                if (!t.songLocal) steps += Step.Song(t.audioId, t.title, t.artist)
                if (t.stemsRemote) stems(t)
            }
            steps += deferred
            return Plan(steps, stemify)
        }

        /** The FX Lock's whole-song steps: rows in reach whose audio isn't local but can be fetched. */
        fun fxLockSongSteps(upcoming: List<Track>, network: NetworkClass, window: Int): List<Step> {
            if (network == NetworkClass.OFFLINE) return emptyList()
            val reach = if (network == NetworkClass.UNMETERED) maxOf(0, window) else minOf(1, maxOf(0, window))
            return upcoming.take(reach).filter { !it.songLocal && it.songFetchable }.map { Step.Song(it.audioId, it.title, it.artist) }
        }

        /** How far Mix Mode reaches on [network] and which stems it fetches there; null = adds nothing. */
        fun mixReach(network: NetworkClass, cellular: NpMixCellularPolicy, window: Int): Reach? = when (network) {
            NetworkClass.OFFLINE -> null
            NetworkClass.UNMETERED -> Reach(maxOf(0, window), StemPolicy.ALL)
            NetworkClass.CONSTRAINED -> Reach(0, StemPolicy.NONE)
            NetworkClass.EXPENSIVE -> when (cellular) {
                NpMixCellularPolicy.OFF -> null
                NpMixCellularPolicy.NEXT_SONG -> Reach(minOf(1, maxOf(0, window)), StemPolicy.ON_REQUEST)
                NpMixCellularPolicy.FULL -> Reach(maxOf(0, window), StemPolicy.ALL)
            }
        }

        /** How many Apple-Music-only rows ahead Mix Mode asks the rip server for. */
        const val RIP_AHEAD = 2

        /**
         * THE PLAN (np-mix-mode 2.2). Mix Mode OFF (or suspended - caller passes it disabled): exactly the
         * Stem Lock plan, byte for byte. ON: rips (step 0, side list), the CURRENT row's whole song when it
         * is ripped-not-local, its stems, then row by row (next song, next stems, rows 2..window), muted parts
         * last - sized by [mixReach]; then every Stem Lock step this order doesn't hold is appended (Mix Mode
         * never fetches LESS than the lock alone would).
         */
        fun plan(i: Input): Plan {
            val lockUpcoming = i.upcoming.take(maxOf(0, i.stemLockWindow))
            val lock0 = plan(if (i.currentStemsPartial) i.current else null, lockUpcoming, i.stemLock, i.network, i.stemLockWindow)
            var lock = lock0
            if (i.fxLockSongs) {
                val extra = lock.steps.toMutableList()
                for (s in fxLockSongSteps(lockUpcoming, i.network, i.stemLockWindow)) if (s !in extra) extra += s
                lock = lock.copy(steps = extra)
            }
            val reach = if (i.mixMode.enabled) mixReach(i.network, i.cellular, i.window) else null
            if (reach == null) return lock

            val steps = ArrayList<Step>()
            val seen = HashSet<Step>()
            val deferred = ArrayList<Step>()
            fun add(s: Step) { if (seen.add(s)) steps += s }
            fun defer(s: Step) { if (s !in seen && s !in deferred) deferred += s }
            val locked = i.stemLock.wantsStems
            fun stems(t: Track, isCurrent: Boolean, isNext: Boolean) {
                if (!t.stemsRemote) return
                var now: List<String> = emptyList()
                var later: List<String> = emptyList()
                when (reach.stems) {
                    StemPolicy.ALL ->
                        if (locked) { now = i.stemLock.enabledParts; later = i.stemLock.disabledParts } else now = StemLock.partPriority
                    StemPolicy.ON_REQUEST ->
                        if (isCurrent && (locked || i.currentStemsWanted)) {
                            now = if (locked) i.stemLock.enabledParts else StemLock.partPriority
                            if (locked) later = i.stemLock.disabledParts
                        } else if (isNext && locked) {
                            now = i.stemLock.enabledParts; later = i.stemLock.disabledParts
                        }
                    StemPolicy.NONE -> {}
                }
                for (p in now) if (p !in t.stemsLocal) add(Step.StemPart(t.songId, p))
                for (p in later) if (p !in t.stemsLocal) defer(Step.StemPart(t.songId, p))
            }
            i.current?.let { c ->
                if (c.songLocal || c.songFetchable) {
                    if (!c.songLocal) add(Step.Song(c.audioId, c.title, c.artist))
                    stems(c, isCurrent = true, isNext = false)
                }
            }
            for ((k, t) in i.upcoming.take(reach.ahead).withIndex()) {
                if (!(t.songLocal || t.songFetchable)) continue
                if (!t.songLocal) add(Step.Song(t.audioId, t.title, t.artist))
                stems(t, isCurrent = false, isNext = k == 0)
            }
            for (s in deferred) add(s)
            for (s in lock.steps) add(s)
            val stemify = ArrayList(lock.stemify)
            var rips = emptyList<String>()
            if (i.isRipServerConfigured) {
                val ripRows = i.upcoming.take(maxOf(reach.ahead, RIP_AHEAD))
                rips = ripRows.filter { it.source == Track.Source.APPLE_MUSIC_ONLY && !it.songLocal }.map { it.audioId }.take(RIP_AHEAD)
                val rows = listOfNotNull(i.current) + i.upcoming.take(reach.ahead)
                for (t in rows) {
                    if ((t.songLocal || t.songFetchable) && t.source != Track.Source.APPLE_MUSIC_ONLY &&
                        t.source != Track.Source.CATALOG_ONLY && !t.stemsRemote &&
                        t.stemsLocal.size < StemLock.partPriority.size && t.songId !in stemify
                    ) stemify += t.songId
                }
            }
            return Plan(steps, stemify, rips)
        }

        /** How long the lane waits on an explicit download before letting the step go (the download carries on untouched). */
        const val PENDING_DOWNLOAD_WAIT_MS = 90_000L

        /**
         * Wait (cancellably) for an explicit download to leave DOWNLOADING: true once READY, false when it
         * errored / vanished / [timeoutMs] ran out. The lane never cancels an explicit Download.
         */
        suspend fun awaitPendingDownload(
            state: () -> PendingDownload,
            timeoutMs: Long = PENDING_DOWNLOAD_WAIT_MS,
            pollMs: Long = 250,
            nowMs: () -> Long = System::currentTimeMillis,
        ): Boolean {
            val deadline = nowMs() + timeoutMs
            while (nowMs() < deadline) {
                when (state()) {
                    PendingDownload.READY -> return true
                    PendingDownload.DOWNLOADING -> delay(pollMs)
                    PendingDownload.OTHER -> return false
                }
            }
            return false
        }
    }
}

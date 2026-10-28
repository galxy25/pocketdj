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
class StemLockPrefetcher(
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
) {
    sealed interface Step {
        /** The whole song (`id` = the id playback resolves under). */
        data class Song(val id: String, val title: String, val artist: String) : Step { override fun toString() = "song:$id" }
        /** One stem part of [songId]. */
        data class StemPart(val songId: String, val part: String) : Step { override fun toString() = "$part:$songId" }
    }

    enum class Network {
        /** Wi-Fi / wired: the whole prefetch window. */
        UNMETERED,
        /** Cellular: the NEXT track only (its song + all its stems). */
        EXPENSIVE,
        /** Data saver: the next track's song + ENABLED stems only - muted parts are skipped. */
        CONSTRAINED,
        /** No path: nothing. */
        OFFLINE,
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
    )

    data class Plan(val steps: List<Step> = emptyList(), /** Songs to ask the cloud to separate (fire-and-forget). */ val stemify: List<String> = emptyList())

    // ---- seams (production wiring in MixGraph) ----
    /** Fetch the whole song of a [Step.Song] to the device; true once it plays from there. */
    var fetchSong: suspend (Step.Song) -> Boolean = { false }
    /** Burn one stem part (`BurnStore.burnStemPart`). */
    var fetchStemPart: suspend (songId: String, part: String) -> Boolean = { _, _ -> false }
    /** Ask the cloud to separate a song (fire-and-forget; deduped here per song id). */
    var requestStemify: (String) -> Unit = {}
    var network: () -> Network = { Network.UNMETERED }
    /** A step finished (`ok` = its audio is on disk). */
    var onStepFinished: ((Step, Boolean) -> Unit)? = null

    var failureCooldownMs: Long = 120_000

    // ---- state ----
    var pending: List<Step> = emptyList(); private set
    var inFlight: Step? = null; private set
    /** Every step STARTED, in order (test seam + diagnostics). */
    val startedLog = ArrayList<Step>()
    private var worker: Job? = null
    private val failedAt = HashMap<Step, Long>()
    private val stemifyRequested = HashSet<String>()
    private var lastLoggedOrder: List<Step> = emptyList()

    val isIdle: Boolean get() = worker == null && pending.isEmpty()

    /** Run [plan]: keep the in-flight fetch if the plan still wants it, otherwise cancel it. */
    fun apply(plan: Plan) {
        for (id in plan.stemify) if (stemifyRequested.add(id)) {
            StemLock.log("stemify request song=$id (next track has no stems)")
            requestStemify(id)
        }
        val t = now()
        val steps = plan.steps.filter { s -> failedAt[s]?.let { t - it >= failureCooldownMs } ?: true }
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
            if (order.isNotEmpty()) StemLock.log("prefetch order net=${network().name.lowercase()} ${order.joinToString(" -> ")}")
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
                inFlight = step
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
        fun plan(current: Track?, upcoming: List<Track>, carry: StemLockState, network: Network, window: Int): Plan {
            if (!carry.wantsStems || network == Network.OFFLINE) return Plan()
            val steps = ArrayList<Step>()
            val stemify = ArrayList<String>()
            val reach = if (network == Network.UNMETERED) maxOf(0, window) else minOf(1, maxOf(0, window))
            val deferred = ArrayList<Step>()
            fun stems(t: Track) {
                for (p in carry.enabledParts) if (p !in t.stemsLocal) steps += Step.StemPart(t.songId, p)
                if (network == Network.CONSTRAINED) return
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
    }
}

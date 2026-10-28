package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.stems.StemClient
import com.levi.pocketdj.data.stems.StemJob
import com.levi.pocketdj.data.stems.StemPhase
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Tracks rip jobs per song (iOS `RipsStore.jobs` / `pollToReady` / `onRipReady`).
 *
 * [pollToReady] keeps watching a job after the interactive wait gave up (StillRipping): every
 * [pollMs] it fetches the job; on `ready` it refreshes the manifest and fires [onRipReady]
 * once. It deliberately does NOT stop on `phase == "error"`: the server auto-heals failed jobs
 * (error -> queued), so a poll that bailed left rows stuck. The cap ([maxTries], 1 h at 2 s) is
 * the only other terminal condition.
 */
class RipJobTracker(
    private val scope: CoroutineScope,
    private val fetchJob: suspend (jobId: String) -> RipJob,
    private val refreshManifest: suspend () -> Unit = {},
    private val pollMs: Long = RipSettings.TRACKER_POLL_MS,
    private val maxTries: Int = RipSettings.TRACKER_MAX_TRIES,
    /** Stemify (SVC-11): POST /stemify for one song; null = refused/unreachable. */
    private val requestStemify: suspend (songId: String) -> StemJob? = { null },
    private val fetchStemJob: suspend (jobId: String) -> StemJob = { error("stem polling not wired") },
    /** Manifest truth: presence of stemVersion. */
    private val isStemmed: (songId: String) -> Boolean = { false },
    private val hasServer: suspend () -> Boolean = { true },
    private val stemPollMs: Long = 3_000L,
    /** 4 h — well past the slowest Demucs run. */
    private val stemDeadlineMs: Long = 4L * 60 * 60 * 1000,
) {
    private val _jobs = MutableStateFlow<Map<String, RipJob>>(emptyMap())

    /** Latest known job view per songId (drives row phase labels). */
    val jobs: StateFlow<Map<String, RipJob>> = _jobs.asStateFlow()

    /** Fired once per tracked job when its rip lands and the manifest has been refreshed. */
    @Volatile
    var onRipReady: ((songId: String) -> Unit)? = null

    /** Songs the USER asked to rip (collection RIP): the playback rip window must never cancel them. */
    private val userRequested = ConcurrentHashMap.newKeySet<String>()
    private val polls = ConcurrentHashMap<String, Job>()

    fun markUserRequested(ids: Collection<String>) { userRequested.addAll(ids) }
    fun isUserRequestedRip(songId: String): Boolean = songId in userRequested

    fun adopt(songId: String, job: RipJob) { _jobs.update { it + (songId to job) } }
    fun clear(songIds: Collection<String>) { _jobs.update { it - songIds.toSet() } }

    /**
     * A canceled rip (iOS `cancelCollection`): stop its polls, drop its job rows and lift the
     * user-requested protection.
     */
    fun cancel(songIds: Collection<String>) {
        for (id in songIds) polls.remove(id)?.cancel()
        userRequested.removeAll(songIds.toSet())
        clear(songIds)
    }

    /** Whether a [pollToReady] for this song is still running. */
    fun isPolling(songId: String): Boolean = polls[songId]?.isActive == true

    /** Start (or keep) watching [jobId] for [songId]. One poll per song. */
    fun pollToReady(songId: String, jobId: String): Job {
        polls[songId]?.takeIf { it.isActive }?.let { return it }
        val job = scope.launch {
            repeat(maxTries) {
                delay(pollMs)
                val view = runCatching { fetchJob(jobId) }.let { r ->
                    r.exceptionOrNull()?.let { if (it is kotlinx.coroutines.CancellationException) throw it }
                    r.getOrNull()
                } ?: return@repeat
                adopt(songId, view)
                if (view.isReady) {
                    runCatching { refreshManifest() }
                    onRipReady?.invoke(songId)
                    return@launch
                }
                // phase == error: keep polling (server auto-heal).
            }
        }
        polls[songId] = job
        return job
    }

    // ---- Stemify (iOS RipsStore.stemify / pollStemReady) ----------------------------------------

    private val _stemJobs = MutableStateFlow<Map<String, StemJob>>(emptyMap())

    /** Active / last STEM job per songId (drives the row's Stemify phase label). */
    val stemJobs: StateFlow<Map<String, StemJob>> = _stemJobs.asStateFlow()

    private val requestingStems = ConcurrentHashMap.newKeySet<String>()
    private val stemPolls = ConcurrentHashMap<String, Job>()

    /** StateFlow dedups equal values already; kept as the named iOS seam. */
    fun adoptStemJob(songId: String, job: StemJob) { _stemJobs.update { it + (songId to job) } }

    /** Seed a queued stem job (collection batch) so the row shows "Queued\u2026" at once. */
    fun seedStemJob(songId: String, jobId: String) {
        adoptStemJob(songId, StemJob(phase = StemPhase.QUEUED, jobId = jobId, songId = songId))
    }

    /** Drop stem-job rows whose song is now stemmed (a stale job must not read "Queued\u2026" forever). */
    fun pruneFinishedStemJobs() {
        _stemJobs.update { m -> m.filterKeys { !isStemmed(it) } }
    }

    fun isStemPolling(songId: String): Boolean = stemPolls[songId]?.isActive == true

    /**
     * FIRE-AND-FORGET Stemify for ONE song. Idempotent at three layers (already stemmed /
     * in-flight phase / requesting set); never fires for studio ids. Stores the returned job and,
     * if still working, polls to a terminal phase. Never throws (except cancellation).
     */
    suspend fun stemify(songId: String) {
        if (!StemClient.shouldRequest(
                songId, isStemmed(songId), _stemJobs.value[songId]?.phase,
                songId in requestingStems, hasServer(),
            )
        ) return
        if (!requestingStems.add(songId)) return
        try {
            val view = requestStemify(songId) ?: return
            adoptStemJob(songId, view)
            if (view.phase == StemPhase.READY) { runCatching { refreshManifest() }; return }
            if (view.phase == StemPhase.INELIGIBLE || view.phase == StemPhase.ERROR) return
            view.jobId?.let { pollStemReady(songId, it) }
        } finally {
            requestingStems.remove(songId)
        }
    }

    /** One poll per song; keeps going through queued/ripping/stemming, stops on ready/error/ineligible. */
    fun pollStemReady(songId: String, jobId: String): Job {
        stemPolls[songId]?.takeIf { it.isActive }?.let { return it }
        val job = scope.launch {
            var waited = 0L
            while (waited < stemDeadlineMs) {
                delay(stemPollMs)
                waited += stemPollMs
                val r = runCatching { fetchStemJob(jobId) }
                r.exceptionOrNull()?.let { if (it is kotlinx.coroutines.CancellationException) throw it }
                val view = r.getOrNull() ?: continue
                adoptStemJob(songId, view)
                when (view.phase) {
                    StemPhase.READY -> { runCatching { refreshManifest() }; pruneFinishedStemJobs(); return@launch }
                    StemPhase.ERROR, StemPhase.INELIGIBLE -> return@launch
                    else -> Unit
                }
            }
        }
        stemPolls[songId] = job
        return job
    }

    /** Stop stem polls + drop job rows (collection Stop). */
    fun cancelStems(songIds: Collection<String>) {
        for (id in songIds) stemPolls.remove(id)?.cancel()
        _stemJobs.update { it - songIds.toSet() }
    }
}

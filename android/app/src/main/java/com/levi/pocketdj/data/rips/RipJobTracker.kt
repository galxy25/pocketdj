package com.levi.pocketdj.data.rips

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
}

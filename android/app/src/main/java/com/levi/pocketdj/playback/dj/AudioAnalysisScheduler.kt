package com.levi.pocketdj.playback.dj

import android.content.Context
import android.os.PowerManager
import com.levi.pocketdj.audio.dsp.LoudnessSegment
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Runs quick -> full passes off the main thread (port of iOS `AudioAnalysisScheduler`), at most [maxConcurrent]
 * (1) at a time, highest priority first: the CURRENT song -> the next-up (a listener's pick first) -> the rest
 * of the plan window. Nothing starts while power-save is on or the device is thermally SEVERE+ (it resumes on
 * the next enqueue / completion / [resume] once that clears). DJ off => [cancelPending].
 */
class AudioAnalysisScheduler(
    private val cache: AudioAnalysisCache,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val source: AudioAnalysis.PassSource = AudioAnalysis.Platform,
    /** SEAM: the device may run analysis now. */
    private val mayRun: () -> Boolean = { true },
    private val maxConcurrent: Int = 1,
    private val headRetryMs: Long = HEAD_RETRY_MS,
    private val maxHeadRetries: Int = MAX_HEAD_RETRIES,
    private val log: (String) -> Unit = {},
    /** Fired after each stored result: (key, result, usableChanged). The caller re-plans only when true. */
    var onResult: (LoudnessCache.Key, AudioAnalysis.Result, Boolean) -> Unit = { _, _, _ -> },
) {
    enum class Priority { CURRENT, USER_NEXT, NEXT, WINDOW }

    /** A file the scheduler opened for one job; [release] runs when the job ends. */
    class Opened(val path: String, val release: (() -> Unit)? = null)

    class Job(
        val key: LoudnessCache.Key,
        /** Opens the file when the job STARTS (40 queued rows never pin 40 handles). Null => the file is gone. */
        val open: () -> Opened?,
        val sliceStartSeconds: Double = 0.0,
        val durationSeconds: Double? = null,
        /** The whole file is on disk (false: a growing / ripping file - the head pass, re-run later). */
        val complete: Boolean = true,
        var priority: Priority = Priority.WINDOW,
        var headRetries: Int = 0,
        var generation: Int = 0,
    ) {
        internal val headId: HeadId get() = HeadId(key.songId, key.segment)
        internal fun copyWith(complete: Boolean = this.complete, duration: Double? = this.durationSeconds, priority: Priority = this.priority) =
            Job(key, open, sliceStartSeconds, duration, complete, priority, headRetries, generation)
    }

    internal data class HeadId(val songId: String, val segment: LoudnessSegment?)

    private val lock = Any()
    private val pending = ArrayList<Job>()
    private val running = HashSet<LoudnessCache.Key>()
    private val runningHeads = HashSet<HeadId>()
    private val deferred = HashMap<HeadId, Job>()
    private var generation = 0
    private val started = ArrayList<String>()

    /** Started order of song ids (tests). */
    val startedOrder: List<String> get() = synchronized(lock) { started.toList() }
    /** Queued song ids in the order they would start (tests). */
    val pendingSongIds: List<String> get() = synchronized(lock) { ordered().map { it.key.songId } }
    val runningCount: Int get() = synchronized(lock) { running.size }

    /** Queue (or re-prioritise) a file. A file already fully analysed is skipped; a head-only hint re-runs once complete. */
    fun enqueue(job: Job) {
        synchronized(lock) {
            job.generation = generation
            if (cache.full(job.key) != null) return
            // Still arriving and its head hint is in (under any interim size): nothing new until it completes.
            if (!job.complete && cache.quick(job.key.songId, job.key.segment) != null) return
            if (job.key in running || job.headId in runningHeads) {
                // The file completed while its head pass ran: the better window + full pass follow.
                if (job.complete) deferred[job.headId] = job
                return
            }
            // One head job per song + segment, whatever size the file has reached.
            if (!job.complete) {
                val i = pending.indexOfFirst { !it.complete && it.headId == job.headId }
                if (i >= 0) { pending[i].priority = minOf(pending[i].priority, job.priority); pumpLocked(); return }
            } else {
                pending.removeAll { !it.complete && it.headId == job.headId }
            }
            val i = pending.indexOfFirst { it.key == job.key }
            if (i >= 0) {
                val j = pending[i]
                pending[i] = j.copyWith(complete = j.complete || job.complete, duration = job.durationSeconds ?: j.durationSeconds,
                    priority = minOf(j.priority, job.priority))
            } else pending.add(job)
            pumpLocked()
        }
    }

    /** Drop queued (not running) work and stale head retries - DJ Mode off / the session ended. */
    fun cancelPending() = synchronized(lock) { pending.clear(); deferred.clear(); generation++ }

    /** Re-check the power gate (call when power-save / thermal state changes). */
    fun resume() = synchronized(lock) { pumpLocked() }

    private fun ordered(): List<Job> = pending.withIndex().sortedWith(compareBy({ it.value.priority }, { it.index })).map { it.value }

    private fun pumpLocked() {
        if (!mayRun()) return
        while (running.size < maxOf(1, maxConcurrent)) {
            val job = ordered().firstOrNull() ?: break
            pending.removeAll { it.key == job.key }
            running.add(job.key)
            if (!job.complete) runningHeads.add(job.headId)
            started.add(job.key.songId)
            scope.launch { run(job) }
        }
    }

    private suspend fun run(job: Job) {
        val opened = try { job.open() } catch (_: Throwable) { null }
        if (opened == null) { finished(job, retryHead = false, release = null); return }
        var waitForHead = false
        try {
            val slice = job.sliceStartSeconds
            val avail = source.availableSeconds(opened.path)
            val dur = job.durationSeconds?.let { minOf(it, avail) } ?: avail
            val hadFinalHint = cache.quick(job.key)?.let { !it.headOnly } ?: false
            // QUICK: on a better window unless a non-head hint already exists.
            if (!hadFinalHint) {
                val w = AudioAnalysis.quickWindow(job.durationSeconds, avail, job.complete)
                if (w != null) AudioAnalysis.quickPass(source, opened.path, slice, w)?.let { landed(job.key, it) }
                else if (!job.complete) waitForHead = true
            }
            // FULL: only once the whole file is here.
            if (job.complete && dur > 2) AudioAnalysis.fullPass(source, opened.path, slice, dur)?.let { landed(job.key, it) }
        } catch (t: Throwable) {
            log("analysis song=${job.key.songId} failed: ${t.message}")
        } finally {
            finished(job, waitForHead, opened.release)
        }
    }

    private fun landed(key: LoudnessCache.Key, r: AudioAnalysis.Result) {
        val (bf, bq) = cache.results(key.songId)
        cache.store(r, key)
        val (af, aq) = cache.results(key.songId)
        val changed = AudioAnalysis.usableChanged(bf, bq, af, aq)
        log("analysis ${r.kind}${if (r.headOnly) " (head)" else ""} song=${key.songId} bpm=${r.bpm?.let { "%.1f".format(it) } ?: "-"}" +
            "@${"%.2f".format(r.bpmConfidence)} key=${r.camelot ?: "-"}@${"%.2f".format(r.keyConfidence)} " +
            "lufs=${r.lufs?.let { "%.1f".format(it) } ?: "-"}")
        onResult(key, r, changed)
    }

    private fun finished(job: Job, retryHead: Boolean, release: (() -> Unit)?) {
        runCatching { release?.invoke() }
        synchronized(lock) {
            running.remove(job.key)
            if (!job.complete) runningHeads.remove(job.headId)
            val next = deferred.remove(job.headId)
            if (next != null) {
                enqueue(next)
            } else if (retryHead && job.headRetries < maxHeadRetries && job.generation == generation) {
                val retry = job.copyWith().also { it.headRetries = job.headRetries + 1 }
                val gen = generation
                scope.launch {
                    delay(headRetryMs)
                    val stale = synchronized(lock) { generation != gen }
                    if (!stale) enqueue(retry)
                }
            }
            pumpLocked()
        }
    }

    companion object {
        const val HEAD_RETRY_MS = 5_000L
        const val MAX_HEAD_RETRIES = 24
        /** PowerManager.THERMAL_STATUS_SEVERE */
        const val THERMAL_SEVERE = 3

        /** Pure gate: analysis may run unless power-save is on or the thermal status is SEVERE or worse. */
        fun deviceMayRun(powerSave: Boolean, thermalStatus: Int): Boolean = !powerSave && thermalStatus < THERMAL_SEVERE

        /** The Android mapping of iOS Low Power Mode / serious thermal state. */
        fun powerGate(context: Context): () -> Boolean {
            val pm = context.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            return { deviceMayRun(pm.isPowerSaveMode, pm.currentThermalStatus) }
        }
    }
}

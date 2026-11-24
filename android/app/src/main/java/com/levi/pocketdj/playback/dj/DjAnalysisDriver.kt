package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.playback.sequencer.QueueItem

/**
 * Drives the on-device analysis for DJ Mode (P2-DJ-11; port of iOS `djScheduleAnalysis / djAnalyzeUpcoming / djAnalysisLanded`).
 *
 * Queues the quick -> full BPM / key / loudness passes on the [AudioAnalysisScheduler] in the scheduler's priority order: the
 * CURRENT song first, then the next-up (the listener's pick ahead of a planned next), then the rest of the plan window. A file is
 * opened only when its pass starts (the job's `open`). A growing current file runs its head.
 *
 * A landed result re-levels the playing song through [DjLeveling] (a hint at most +-4 dB; the final ramps over 2 s) and asks the
 * selector to re-plan ONLY when a row's usable BPM / Camelot changed (a loudness-only result, or one that confirms what was planned
 * on, is no reason to reshuffle; analysis re-plans never count deferrals - the planner decides that).
 */
class DjAnalysisDriver(
    private val host: Host,
    private val leveling: DjLeveling,
    private val scheduler: AudioAnalysisScheduler,
) {
    interface Host {
        val djActive: Boolean
        /** Settings > Mixing "Volume leveling". */
        val volumeLeveling: Boolean
        val running: Boolean
        val index: Int
        val queue: List<QueueItem>
        /** The current row's file is still arriving. */
        val currentStreaming: Boolean
        /** The row's complete local file + slice; null = not local. */
        fun localSource(item: QueueItem): DjConductor.LocalSource?
        /** The planner re-reads its facts; it re-plans only when a windowed row's usable BPM / Camelot changed. */
        fun analysisLanded(songId: String)
        fun log(line: String)
    }

    init {
        // Take over the scheduler's result callback (the wiring constructs it without one).
        val prior = scheduler.onResult
        scheduler.onResult = { key, r, changed -> prior(key, r, changed); onResult(key, changed) }
    }

    /** Analysis re-plans requested so far (tests). */
    var replanRequests = 0; private set

    /** Queue the passes for the current row and the plan window. Idempotent: the scheduler dedups by key. */
    fun scheduleAnalysis() {
        if (!host.djActive || !host.running) return
        val q = host.queue
        val index = host.index
        if (index !in q.indices) return
        val cur = q[index]
        host.localSource(cur)?.let { src ->
            leveling.keyFor(cur.id, src)?.let { key ->
                scheduler.enqueue(job(key, src, cur, complete = !host.currentStreaming, AudioAnalysisScheduler.Priority.CURRENT) { src })
            }
        }
        val hi = minOf(q.size, index + 1 + DjCandidates.PLAN_WINDOW)
        for (i in index + 1 until hi) {
            val it = q[i]
            val src = host.localSource(it) ?: continue
            val key = leveling.keyFor(it.id, src) ?: continue
            val pri = if (i == index + 1) {
                if (it.djUserNext) AudioAnalysisScheduler.Priority.USER_NEXT else AudioAnalysisScheduler.Priority.NEXT
            } else AudioAnalysisScheduler.Priority.WINDOW
            scheduler.enqueue(job(key, src, it, complete = true, pri) { host.localSource(it) })
        }
    }

    /**
     * Analyse the next local rows ahead of their starts (so their gain is known at the mix) and queue the window's passes.
     * Loudness is measured only while DJ is on AND Volume leveling is on.
     */
    fun analyzeUpcoming() {
        scheduleAnalysis()
        if (!host.djActive || !host.volumeLeveling || !host.running) return
        val q = host.queue
        val from = host.index + 1
        for (i in from until minOf(q.size, from + UPCOMING_LEVELED)) {
            val src = host.localSource(q[i]) ?: continue
            leveling.levelDb(q[i].id, src)   // kicks the measurement once (never while running / settled)
        }
    }

    /** DJ off / session end: nothing queued runs, running measurements stop. */
    fun cancelAll() {
        scheduler.cancelPending()
        leveling.cancelAnalyses()
    }

    private fun job(
        key: LoudnessCache.Key, src: DjConductor.LocalSource, item: QueueItem, complete: Boolean,
        priority: AudioAnalysisScheduler.Priority, open: () -> DjConductor.LocalSource?,
    ) = AudioAnalysisScheduler.Job(
        key = key,
        open = { open()?.let { AudioAnalysisScheduler.Opened(it.file.path) } },
        sliceStartSeconds = src.startMs / 1000.0,
        durationSeconds = (src.lengthMs.takeIf { it > 0 } ?: item.lengthMs)?.let { it / 1000.0 },
        complete = complete,
        priority = priority,
    )

    /** A hint / final landed for [key]. */
    internal fun onResult(key: LoudnessCache.Key, usableChanged: Boolean) {
        if (!host.djActive || !host.running) return
        val cur = host.queue.getOrNull(host.index)
        if (cur != null && cur.matches(key.songId)) leveling.applyCurrent(ramp = true)
        if (usableChanged) {
            replanRequests++
            host.analysisLanded(key.songId)
        }
    }

    companion object {
        /**
         * The planner's tempo / key facts for a row: the catalog's, with on-device analysis filling what the catalog lacks -
         * full > a CONFIDENT quick hint > nothing; it never overrides a measured value (iOS `djFacts`).
         */
        fun factsWithAnalysis(
            catalogBpm: Double?, catalogCamelot: String?, full: AudioAnalysis.Result?, quick: AudioAnalysis.Result?,
        ): Pair<Double?, String?> {
            val bpm0 = catalogBpm?.takeIf { it > 0 }
            if (bpm0 != null && !catalogCamelot.isNullOrEmpty()) return bpm0 to catalogCamelot
            return AudioAnalysis.bpm(bpm0, full, quick).value to AudioAnalysis.camelot(catalogCamelot, full, quick).value
        }

        /** iOS levels the next two rows ahead of their mix. */
        const val UPCOMING_LEVELED = 2
    }
}

package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.dsp.LoudnessSegment
import com.levi.pocketdj.playback.dj.AudioAnalysisScheduler.Priority
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AudioAnalysisSchedulerTest {
    /** A fake decode seam: records what each pass asked for; the PCM is a (pitched, beatless) tone. */
    private class Src(var avail: Double = 100.0, var fixed: PcmBuffer? = null) : AudioAnalysis.PassSource {
        val decodes = ArrayList<Triple<String, Double, Double>>()
        override fun decode(path: String, startSeconds: Double, lengthSeconds: Double): PcmBuffer? {
            decodes += Triple(path, startSeconds, lengthSeconds)
            return fixed ?: PcmBuffer(8000, 1, FloatArray((8000 * lengthSeconds.coerceAtMost(3.0)).toInt()) { 0.01f })
        }
        override fun availableSeconds(path: String) = avail
    }

    private class Rig(val src: Src = Src(), val gate: AtomicBoolean = AtomicBoolean(true), maxHeadRetries: Int = 24) {
        val test = TestScope()
        val disp = StandardTestDispatcher(test.testScheduler)
        val cache = AudioAnalysisCache(null)
        val landed = ArrayList<Triple<String, AudioAnalysis.Kind, Boolean>>()
        val sched = AudioAnalysisScheduler(cache, CoroutineScope(SupervisorJob() + disp), src, { gate.get() },
            maxHeadRetries = maxHeadRetries, onResult = { k, r, ch -> landed += Triple(k.songId, r.kind, ch) })
        val opened = ArrayList<String>()
        val released = ArrayList<String>()
        fun job(id: String, p: Priority, complete: Boolean = true, size: Long = 1, dur: Double? = 100.0, seg: LoudnessSegment? = null) =
            AudioAnalysisScheduler.Job(LoudnessCache.Key(id, size, seg), open = {
                opened += id; AudioAnalysisScheduler.Opened("/$id", { released += id })
            }, durationSeconds = dur, complete = complete, priority = p)
        fun settle() { test.testScheduler.advanceUntilIdle() }
    }

    @Test fun startsByPriorityCurrentThenUserPickThenNextThenWindowRows() {
        val r = Rig()
        r.gate.set(false)                                       // hold the queue so only ORDER decides
        r.sched.enqueue(r.job("w1", Priority.WINDOW))
        r.sched.enqueue(r.job("n", Priority.NEXT))
        r.sched.enqueue(r.job("w2", Priority.WINDOW))
        r.sched.enqueue(r.job("u", Priority.USER_NEXT))
        r.sched.enqueue(r.job("c", Priority.CURRENT))
        assertEquals(listOf("c", "u", "n", "w1", "w2"), r.sched.pendingSongIds)   // ties keep arrival order
        r.gate.set(true); r.sched.resume(); r.settle()
        assertEquals(listOf("c", "u", "n", "w1", "w2"), r.sched.startedOrder)
        assertEquals(5, r.released.size)                        // every opened handle released
    }

    @Test fun onlyOnePassRunsAtATime() {
        val r = Rig()
        r.sched.enqueue(r.job("a", Priority.CURRENT))
        r.sched.enqueue(r.job("b", Priority.NEXT))
        r.sched.enqueue(r.job("c", Priority.WINDOW))
        assertEquals(1, r.sched.runningCount)                   // a launched, b/c wait for it
        assertEquals(listOf("a"), r.sched.startedOrder)
        assertEquals(listOf("b", "c"), r.sched.pendingSongIds)
        r.settle()
        assertEquals(listOf("a", "b", "c"), r.sched.startedOrder)
    }

    @Test fun reprioritisingAQueuedRowMovesItForward() {
        val r = Rig(); r.gate.set(false)
        r.sched.enqueue(r.job("a", Priority.WINDOW))
        r.sched.enqueue(r.job("b", Priority.WINDOW))
        r.sched.enqueue(r.job("b", Priority.USER_NEXT))        // the listener picked b
        assertEquals(listOf("b", "a"), r.sched.pendingSongIds)
        assertEquals(1, r.sched.pendingSongIds.count { it == "b" })
    }

    @Test fun powerSaveOrSevereThermalPausesAndResumeContinues() {
        assertFalse(AudioAnalysisScheduler.deviceMayRun(powerSave = true, thermalStatus = 0))
        assertFalse(AudioAnalysisScheduler.deviceMayRun(powerSave = false, thermalStatus = AudioAnalysisScheduler.THERMAL_SEVERE))
        assertFalse(AudioAnalysisScheduler.deviceMayRun(powerSave = false, thermalStatus = 5))
        assertTrue(AudioAnalysisScheduler.deviceMayRun(powerSave = false, thermalStatus = 2))   // MODERATE still runs
        val r = Rig(); r.gate.set(false)
        r.sched.enqueue(r.job("a", Priority.CURRENT))
        r.settle()
        assertEquals(emptyList<String>(), r.sched.startedOrder); assertTrue(r.src.decodes.isEmpty())
        r.gate.set(true); r.sched.enqueue(r.job("b", Priority.NEXT)); r.settle()   // the next enqueue unblocks it
        assertEquals(listOf("a", "b"), r.sched.startedOrder)
    }

    @Test fun cancelPendingDropsQueueButNotTheRunningPass() {
        val r = Rig()
        r.sched.enqueue(r.job("run", Priority.CURRENT))
        r.sched.enqueue(r.job("q1", Priority.NEXT)); r.sched.enqueue(r.job("q2", Priority.WINDOW))
        r.sched.cancelPending()
        assertEquals(emptyList<String>(), r.sched.pendingSongIds)
        r.settle()
        assertEquals(listOf("run"), r.sched.startedOrder)
        assertEquals(0, r.sched.runningCount)
    }

    @Test fun completeFileRunsQuickThenFullAndReportsEach() {
        val r = Rig()
        r.sched.enqueue(r.job("a", Priority.CURRENT)); r.settle()
        assertEquals(listOf("a" to AudioAnalysis.Kind.quick, "a" to AudioAnalysis.Kind.full), r.landed.map { it.first to it.second })
        assertNotNull(r.cache.full(LoudnessCache.Key("a", 1)))
        assertNull(r.cache.quick(LoudnessCache.Key("a", 1)))   // superseded by the final
        // quick window = 20 s from 30 s in
        assertEquals(Triple("/a", 30.0, 20.0), r.src.decodes.first())
        // Already analysed => skipped on a re-enqueue.
        r.sched.enqueue(r.job("a", Priority.CURRENT)); r.settle()
        assertEquals(listOf("a"), r.sched.startedOrder)
    }

    @Test fun growingFileWaitsForAHeadThenRunsQuickHeadOnlyAndNoFull() {
        val r = Rig(Src(avail = 5.0))
        r.sched.enqueue(r.job("g", Priority.CURRENT, complete = false, dur = null))
        r.test.testScheduler.runCurrent()
        assertTrue(r.landed.isEmpty())
        r.src.avail = 20.0                                       // 15 s+ have landed by the next look
        r.test.testScheduler.advanceTimeBy(5_001); r.test.testScheduler.runCurrent(); r.settle()
        assertEquals(listOf("g" to AudioAnalysis.Kind.quick), r.landed.map { it.first to it.second })
        assertTrue(r.cache.quick("g", null)!!.headOnly)
        assertNull(r.cache.full(LoudnessCache.Key("g", 1)))      // never a full pass on a growing file
        // The file completes: the better window + the full pass follow.
        r.sched.enqueue(r.job("g", Priority.CURRENT, complete = true, size = 9)); r.settle()
        assertEquals(AudioAnalysis.Kind.full, r.landed.last().second)
    }

    @Test fun headRetriesStopAfterTheCap() {
        val r = Rig(Src(avail = 1.0), maxHeadRetries = 3)
        r.sched.enqueue(r.job("g", Priority.CURRENT, complete = false, dur = null))
        r.test.testScheduler.advanceTimeBy(5_000L * 10); r.settle()
        assertEquals(4, r.sched.startedOrder.size)               // the first look + 3 retries, then it gives up
        assertTrue(r.landed.isEmpty())
    }

    @Test fun cancelKillsAPendingHeadRetry() {
        val r = Rig(Src(avail = 1.0))
        r.sched.enqueue(r.job("g", Priority.CURRENT, complete = false, dur = null))
        r.test.testScheduler.runCurrent()
        r.sched.cancelPending()
        r.test.testScheduler.advanceTimeBy(5_000L * 30); r.settle()
        assertEquals(1, r.sched.startedOrder.size)
    }

    @Test fun missingFileDropsTheJobWithoutBlockingTheQueue() {
        val r = Rig()
        r.sched.enqueue(AudioAnalysisScheduler.Job(LoudnessCache.Key("gone", 1), open = { null }, priority = Priority.CURRENT))
        r.sched.enqueue(r.job("b", Priority.NEXT)); r.settle()
        assertEquals(listOf("gone", "b"), r.sched.startedOrder)
        assertTrue(r.landed.any { it.first == "b" })
    }

    private fun clicks(bpm: Double, seconds: Double, sr: Int = 22050): PcmBuffer {
        val out = FloatArray((seconds * sr).toInt())
        var pos = 0.0
        while (pos < out.size) {
            val p = pos.toInt()
            for (i in 0 until 600) { if (p + i >= out.size) break; out[p + i] += (kotlin.math.sin(2 * Math.PI * 1500 * i / sr) * kotlin.math.exp(-i / 90.0)).toFloat() }
            pos += 60.0 / bpm * sr
        }
        return PcmBuffer(sr, 1, out)
    }

    @Test fun usableChangedFlagFollowsWhatTheResultAdds() {
        // Silence: no BPM, no key, no loudness - nothing usable appears, so no re-plan is requested.
        val quiet = Rig(Src(fixed = PcmBuffer(8000, 1, FloatArray(8000 * 20))))
        quiet.sched.enqueue(quiet.job("a", Priority.CURRENT)); quiet.settle()
        assertTrue(quiet.landed.isNotEmpty()); assertTrue(quiet.landed.none { it.third })
        // A click track yields a confident BPM hint: the quick landing changes the usable BPM => re-plan.
        val beat = Rig(Src(fixed = clicks(120.0, 20.0)))
        beat.sched.enqueue(beat.job("b", Priority.CURRENT)); beat.settle()
        assertEquals(AudioAnalysis.Kind.quick, beat.landed.first().second)
        assertTrue(beat.landed.first().third)
    }
}

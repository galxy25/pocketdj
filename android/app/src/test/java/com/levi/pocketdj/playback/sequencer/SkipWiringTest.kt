package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.health.EngineProbe
import com.levi.pocketdj.playback.outcome.SkipTracker
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** PB-5 sequencer wiring: which user actions report advance-away to the SkipTracker, and which never do. */
@OptIn(ExperimentalCoroutinesApi::class)
class SkipWiringTest {
    private class Probe(var position: Long = 0L, var duration: Long? = 100_000L) : EngineProbe {
        override val hasLoadedItem = true
        override val isPlaying = true
        override val positionMs get() = position
        override val durationMs get() = duration
        override val trackEnded = false
        override fun rekick(by: String) {}
    }

    private class Rig(h: SequencerHarness, val probe: Probe) {
        val skipped = mutableListOf<String>()
        val listened = mutableMapOf<String, Double>()
        val tracker = SkipTracker({ skipped += it }, { id, f -> listened[id] = maxOf(f, listened[id] ?: 0.0) })
        init {
            h.seq.engine = probe
            h.seq.skipTracker = tracker
        }
        /** Arm like the History choke point does on a fresh load. */
        fun arm(eventId: String, songId: String) = tracker.noteTrackStarted(eventId, songId)
    }

    private fun kotlinx.coroutines.test.TestScope.rig(vararg ids: String, probe: Probe = Probe()): Pair<SequencerHarness, Rig> {
        val h = SequencerHarness(this, backgroundScope, ids.toSet())
        return h to Rig(h, probe)
    }

    @Test
    fun skipNext_at10Percent_isASkip() = runTest {
        val (h, r) = rig("a", "b")
        h.seq.play(rows("a", "b")); h.settle()
        r.arm("e1", "a")
        r.probe.position = 10_000
        h.seq.skipNext(); h.settle()
        assertEquals(listOf("e1"), r.skipped)
    }

    @Test
    fun skipNext_atExactlyHalf_isNotASkip() = runTest {
        val (h, r) = rig("a", "b")
        h.seq.play(rows("a", "b")); h.settle()
        r.arm("e1", "a")
        r.probe.position = 50_000
        h.seq.skipNext(); h.settle()
        assertTrue(r.skipped.isEmpty())
    }

    @Test
    fun skipPrevious_naturalEnd_andStop_neverMarkSkipped() = runTest {
        val (h, r) = rig("a", "b", "c")
        h.seq.play(rows("a", "b", "c")); h.settle()
        r.arm("e1", "a")
        r.probe.position = 5_000
        h.seq.handleEnded("a"); h.settle()
        r.arm("e2", "b")
        r.probe.position = 5_000
        h.seq.skipPrevious(); h.settle()
        r.arm("e3", "a")
        r.probe.position = 5_000
        h.seq.stop(); h.settle()
        assertTrue("no skip expected: ${r.skipped}", r.skipped.isEmpty())
    }

    @Test
    fun jumpToUpcoming_andPlayNow_reportAdvanceAway() = runTest {
        val (h, r) = rig("a", "b", "c")
        h.seq.play(rows("a", "b", "c")); h.settle()
        r.arm("e1", "a")
        r.probe.position = 10_000
        h.seq.playNow(QueueItem("c", title = "c")); h.settle()
        assertEquals(listOf("e1"), r.skipped)
    }

    @Test
    fun catalogLength_beatsMissingEngineDuration() = runTest {
        val (h, r) = rig("a", "b", probe = Probe(duration = null))
        h.seq.play(listOf(QueueItem("a", title = "a", lengthMs = 200_000), QueueItem("b", title = "b")))
        h.settle()
        r.arm("e1", "a")
        r.probe.position = 20_000
        h.seq.skipNext(); h.settle()
        assertEquals(listOf("e1"), r.skipped)
    }

    @Test
    fun unknownDuration_isNeverClassified() = runTest {
        val (h, r) = rig("a", "b", probe = Probe(duration = null))
        h.seq.play(rows("a", "b")); h.settle()
        r.arm("e1", "a")
        r.probe.position = 1_000
        h.seq.skipNext(); h.settle()
        assertTrue(r.skipped.isEmpty())
    }

    @Test
    fun sampleAudible_feedsTheHighWaterMark() = runTest {
        val (h, r) = rig("a")
        h.seq.play(rows("a")); h.settle()
        r.arm("e1", "a")
        r.probe.position = 30_000
        h.seq.sampleAudible()
        r.tracker.checkpoint()
        assertEquals(0.3, r.listened["e1"]!!, 1e-9)
    }

    @Test
    fun repeatOne_secondPassSkip_isClassified() = runTest {
        val (h, r) = rig("a", "b")
        h.seq.setRepeatMode(RepeatMode.ONE)
        h.seq.play(rows("a", "b")); h.settle()
        r.arm("e1", "a")
        r.probe.position = 90_000
        h.seq.sampleAudible()
        h.seq.handleEnded("a"); h.settle() // pass 2 restarts in place
        assertEquals(1.0, r.listened["e1"]!!, 1e-9) // pass 1 played through
        r.probe.position = 5_000
        h.seq.skipNext(); h.settle()
        assertEquals(listOf("e1"), r.skipped)
    }
}

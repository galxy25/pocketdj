package com.levi.pocketdj.playback.outcome

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectPlaySamplerTest {
    private val skipped = mutableListOf<String>()
    private val listened = mutableMapOf<String, Double>()
    private val verdicts = mutableListOf<Triple<String, Boolean, Double>>()
    private val tracker = SkipTracker(
        markSkipped = { skipped += it },
        noteListened = { id, f -> listened[id] = maxOf(listened[id] ?: 0.0, f) },
        onVerdict = { s, k, f -> verdicts += Triple(s, k, f) },
    )
    private val sampler = DirectPlaySampler(tracker)

    @Test fun singleSkippedAt30Percent_isClassifiedSkippedWithFraction() {
        tracker.noteTrackStarted("e1", "s1")
        for (sec in 0..30) sampler.tick("s1", sec * 1000L, 100_000)
        // A different direct play replaces it (called before the new media is set).
        sampler.noteReplacing()
        assertEquals(listOf("e1"), skipped)
        assertEquals(1, verdicts.size)
        assertEquals("s1", verdicts[0].first)
        assertTrue(verdicts[0].second)
        assertEquals(0.30, verdicts[0].third, 1e-9)
        assertEquals(0.30, listened["e1"]!!, 1e-9)
    }

    @Test fun replacedByNextMediaIdInTick_isAnAdvanceAwayToo() {
        tracker.noteTrackStarted("e1", "s1")
        sampler.tick("s1", 10_000, 100_000)
        tracker.noteTrackStarted("e2", "s2") // history armed the new event first (one-deep stash carries s1)
        sampler.tick("s2", 0, 50_000)
        assertEquals(listOf("e1"), skipped)
        assertEquals(0.10, listened["e1"]!!, 1e-9)
    }

    @Test fun naturalEnd_isFullFractionNeverASkip() {
        tracker.noteTrackStarted("e1", "s1")
        sampler.tick("s1", 99_000, 100_000)
        sampler.tick("s1", 100_000, 100_000, ended = true)
        sampler.tick("s1", 100_000, 100_000, ended = true) // STATE_ENDED repeats each tick: reported once
        sampler.noteReplacing()
        assertTrue(skipped.isEmpty())
        assertEquals(1.0, listened["e1"]!!, 1e-9)
        assertTrue(verdicts.isEmpty())
    }

    @Test fun gaplessAutoTransitionNearTheEnd_isNotASkip() {
        tracker.noteTrackStarted("e1", "s1")
        sampler.tick("s1", 98_500, 100_000) // the 1 Hz sample missed the final second
        tracker.noteTrackStarted("e2", "s2")
        sampler.tick("s2", 0, 60_000)
        assertTrue(skipped.isEmpty())
    }

    @Test fun stopCheckpointsTheFractionWithoutClassifying() {
        tracker.noteTrackStarted("e1", "s1")
        sampler.tick("s1", 20_000, 100_000)
        sampler.tick(null, 0, null) // controller holds nothing for us
        assertTrue(skipped.isEmpty())
        assertTrue(verdicts.isEmpty())
        assertEquals(0.20, listened["e1"]!!, 1e-9)
        assertEquals(null, sampler.activeSongId)
    }

    @Test fun seekBackKeepsTheHighWaterMark() {
        tracker.noteTrackStarted("e1", "s1")
        sampler.tick("s1", 70_000, 100_000)
        sampler.tick("s1", 5_000, 100_000)
        sampler.noteReplacing() // last position 5 s, but the high-water 70 % wins: not a skip
        assertTrue(skipped.isEmpty())
        assertEquals(0.70, listened["e1"]!!, 1e-9)
    }
}

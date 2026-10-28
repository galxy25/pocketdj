package com.levi.pocketdj.playback.outcome

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SkipTrackerTest {
    private val skipped = mutableListOf<String>()
    private val listened = mutableMapOf<String, Double>()
    private val noteSkips = mutableListOf<String>()
    private val verdicts = mutableListOf<Triple<String, Boolean, Double>>()

    private val t = SkipTracker(
        markSkipped = { skipped += it },
        noteListened = { id, f -> listened[id] = maxOf(listened[id] ?: 0.0, f) },
        noteSkip = { noteSkips += it },
        onVerdict = { s, k, f -> verdicts += Triple(s, k, f) },
    )

    private fun start(ev: String, song: String, dur: Long = 100_000) {
        t.noteTrackStarted(ev, song)
        t.samplePosition(song, 0, dur)
    }

    @Test fun strictHalf_exactlyHalfIsNotSkip_justUnderIs() {
        start("e1", "s1")
        t.noteAdvanceAway("s1", 50_000, 100_000)
        assertTrue(skipped.isEmpty())
        assertEquals(0.5, listened["e1"]!!, 1e-9)
        start("e2", "s2")
        t.noteAdvanceAway("s2", 49_999, 100_000)
        assertEquals(listOf("e2"), skipped)
        assertEquals(listOf("s2"), noteSkips)
    }

    @Test fun naturalEnd_reportsFullFractionNeverSkips() {
        start("e1", "s1")
        t.noteNaturalEnd("s1")
        assertEquals(1.0, listened["e1"]!!, 1e-9)
        assertTrue(skipped.isEmpty())
        assertTrue(verdicts.isEmpty())
    }

    @Test fun pauseAndStop_checkpointReportsFractionWithoutSkip() {
        start("e1", "s1")
        t.samplePosition("s1", 30_000, 100_000)
        t.checkpoint()
        assertEquals(0.3, listened["e1"]!!, 1e-9)
        assertTrue(skipped.isEmpty())
    }

    @Test fun unknownDuration_isNotASkip_andReportsNothing() {
        t.noteTrackStarted("e1", "s1")
        t.samplePosition("s1", 1_000, null)
        t.noteAdvanceAway("s1", 1_000, null)
        assertTrue(skipped.isEmpty())
        assertTrue(listened.isEmpty())
        assertTrue(verdicts.isEmpty())
    }

    @Test fun highWater_beatsClobberedLiveRead() {
        start("e1", "s1")
        t.samplePosition("s1", 80_000, 100_000)
        t.samplePosition("s1", 5_000, 100_000) // seek back: mark holds
        t.noteAdvanceAway("s1", 0, 100_000) // AM systemSkip clobbered the clock
        assertTrue(skipped.isEmpty())
        assertEquals(0.8, listened["e1"]!!, 1e-9)
    }

    @Test fun liveReadPastMark_beatsMark() {
        start("e1", "s1")
        t.samplePosition("s1", 10_000, 100_000)
        t.noteAdvanceAway("s1", 90_000, 100_000)
        assertTrue(skipped.isEmpty())
    }

    @Test fun jumpToRow_lateVerdictClassifiesPreviousViaStash() {
        start("e1", "s1")
        t.samplePosition("s1", 10_000, 100_000)
        start("e2", "s2") // new play already re-armed
        t.noteAdvanceAway("s1", null, null) // adopt path: no clock, samples only
        assertEquals(listOf("e1"), skipped)
        // second verdict for the same event is ignored
        t.noteAdvanceAway("s1", null, null)
        assertEquals(listOf("e1"), skipped)
        assertEquals(1, noteSkips.size)
    }

    @Test fun stashIsOneDeep_ancientVerdictDropped() {
        start("e1", "s1")
        t.samplePosition("s1", 1_000, 100_000)
        start("e2", "s2")
        start("e3", "s3")
        t.noteAdvanceAway("s1", null, null)
        assertTrue(skipped.isEmpty())
    }

    @Test fun doubleClassifyGuard_currentTrack() {
        start("e1", "s1")
        t.noteAdvanceAway("s1", 1_000, 100_000)
        t.noteAdvanceAway("s1", 1_000, 100_000)
        assertEquals(listOf("e1"), skipped)
        assertEquals(1, verdicts.size)
        assertTrue(verdicts[0].second)
    }

    @Test fun restart_reZeroesMarkAfterReportingPassOne() {
        start("e1", "s1")
        t.samplePosition("s1", 90_000, 100_000)
        t.noteTrackRestarted("s1")
        assertEquals(0.9, listened["e1"]!!, 1e-9)
        t.samplePosition("s1", 5_000, 100_000)
        t.noteAdvanceAway("s1", 5_000, 100_000)
        assertEquals(listOf("e1"), skipped) // classified against pass 2, not pass 1's peak
        assertEquals(0.9, listened["e1"]!!, 1e-9) // max-merge keeps pass 1
    }

    @Test fun restart_ofOtherSong_isDropped() {
        start("e1", "s1")
        t.samplePosition("s1", 90_000, 100_000)
        t.noteTrackRestarted("other")
        t.noteAdvanceAway("s1", 0, 100_000)
        assertTrue(skipped.isEmpty())
    }

    @Test fun resumedAlreadySkipped_staysClassified() {
        t.noteTrackResumed("e1", "s1", wasSkipped = true)
        t.samplePosition("s1", 1_000, 100_000)
        t.noteAdvanceAway("s1", 1_000, 100_000)
        assertTrue(noteSkips.isEmpty())
        assertTrue(verdicts.isEmpty())
    }

    @Test fun staleSamples_forOtherSong_doNotPolluteMark() {
        start("e1", "s1")
        t.samplePosition("s2", 99_000, 100_000)
        t.noteAdvanceAway("s1", 1_000, 100_000)
        assertEquals(listOf("e1"), skipped)
    }

    @Test fun variantIds_matchByBase() {
        start("e1", "song123")
        t.samplePosition("song123_clean", 5_000, 100_000)
        t.noteAdvanceAway("song123", null, null)
        assertEquals(listOf("e1"), skipped)
    }

    @Test fun nothingArmed_advanceAwayIsNoOp() {
        t.noteAdvanceAway("s1", 1, 100)
        assertNull(t.currentEventId)
        assertTrue(skipped.isEmpty())
    }

    @Test
    fun sinks_runOutsideTheTrackerLock() {
        var holdsLock: Boolean? = null
        lateinit var t: SkipTracker
        t = SkipTracker(
            markSkipped = { holdsLock = holdsTrackerLock(t) },
            noteListened = { _, _ -> },
        )
        t.noteTrackStarted("e1", "a")
        t.noteAdvanceAway("a", 10_000, 100_000)
        assertEquals(false, holdsLock)
    }

    /** True if another thread can NOT take the tracker's monitor right now (i.e. we hold it). */
    private fun holdsTrackerLock(t: SkipTracker): Boolean {
        var blocked = true
        val th = Thread { t.currentEventId; blocked = false }
        th.start()
        th.join(500)
        return blocked && th.isAlive.also { if (it) th.interrupt() }
    }

    @Test
    fun currentEventIdState_tracksArming() {
        val t = SkipTracker({ }, { _, _ -> })
        assertEquals(null, t.currentEventIdState.value)
        t.noteTrackStarted("e1", "a")
        assertEquals("e1", t.currentEventIdState.value)
    }
}

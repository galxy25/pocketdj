package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.model.StudioNoteEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

class InstrumentEventLogTest {
    private val ms = 1_000_000L   // nanos per ms
    private val beat1 = 10_000 * ms

    @Test fun eventsAreMsFromBeat1AndCountInIsNotRecorded() {
        val log = InstrumentEventLog()
        log.arm(beat1)
        log.noteOn(60, 90, beat1 - 500 * ms)     // warm-up during the count-in
        log.noteOff(60, beat1 - 300 * ms)
        log.noteOn(64, 100, beat1 + 250 * ms)
        log.noteOff(64, beat1 + 750 * ms)
        val ev = log.disarmAndFinish(beat1 + 2_000 * ms)
        assertEquals(listOf(StudioNoteEvent(250, 750, 64, 100)), ev)
    }

    @Test fun noteStartedInCountInAndReleasedAfterBeat1IsDropped() {
        val log = InstrumentEventLog()
        log.arm(beat1)
        log.noteOn(60, 90, beat1 - 100 * ms)
        log.noteOff(60, beat1 + 100 * ms)
        assertTrue(log.disarmAndFinish(beat1 + 500 * ms).isEmpty())
    }

    @Test fun heldNoteIsClosedAtStopAndOutputIsOnsetSorted() {
        val log = InstrumentEventLog()
        log.arm(beat1)
        log.noteOn(67, 80, beat1 + 900 * ms)
        log.noteOn(60, 70, beat1 + 100 * ms)
        log.noteOff(60, beat1 + 400 * ms)
        val ev = log.disarmAndFinish(beat1 + 1_500 * ms)
        assertEquals(listOf(StudioNoteEvent(100, 400, 60, 70), StudioNoteEvent(900, 1_500, 67, 80)), ev)
    }

    @Test fun retriggerWithoutOffClosesPreviousAtNewOnset() {
        val log = InstrumentEventLog()
        log.arm(beat1)
        log.noteOn(60, 50, beat1 + 100 * ms)
        log.noteOn(60, 90, beat1 + 300 * ms)
        log.noteOff(60, beat1 + 500 * ms)
        assertEquals(
            listOf(StudioNoteEvent(100, 300, 60, 50), StudioNoteEvent(300, 500, 60, 90)),
            log.disarmAndFinish(beat1 + 600 * ms),
        )
    }

    @Test fun disarmedLogIgnoresNotesAndRearmingStartsClean() {
        val log = InstrumentEventLog()
        log.noteOn(60, 90, beat1 + 100 * ms); log.noteOff(60, beat1 + 200 * ms)
        assertEquals(0, log.recordedCount)
        log.arm(beat1)
        log.noteOn(62, 90, beat1 + 10 * ms)
        assertEquals(1, log.recordedCount)
        log.disarmAndFinish(beat1 + 50 * ms)
        log.noteOn(64, 90, beat1 + 60 * ms)                  // after stop: highlight only
        log.arm(beat1)                                         // fresh take
        assertEquals(0, log.recordedCount)
        assertFalse(log.isArmed.not())
    }

    @Test fun offAfterStopOnlyUpdatesHighlights() {
        val log = InstrumentEventLog()
        log.arm(beat1)
        log.noteOn(60, 90, beat1 + 10 * ms)
        log.disarmAndFinish(beat1 + 20 * ms)
        log.noteOff(60, beat1 + 900 * ms)
        assertEquals(emptySet<Int>(), log.drainHighlightsIfDirty())
    }

    @Test fun highlightDrainCoalescesBurstsIntoOneSnapshot() {
        val log = InstrumentEventLog()
        assertNull(log.drainHighlightsIfDirty())              // idle => nothing to publish
        log.noteOn(60, 90, 0); log.noteOn(64, 90, 1); log.noteOn(67, 90, 2); log.noteOff(64, 3)
        assertEquals(setOf(60, 67), log.drainHighlightsIfDirty())
        assertNull(log.drainHighlightsIfDirty())              // clean until the next change
        log.noteOff(60, 4)
        assertEquals(setOf(67), log.drainHighlightsIfDirty())
        log.clearHighlights()
        assertEquals(emptySet<Int>(), log.drainHighlightsIfDirty())
    }

    @Test fun liveStreamAnchorsAtFirstNoteAndOnlyShowsCompletedNotes() {
        val log = InstrumentEventLog()
        assertNull(log.snapshotLiveIfDirty())
        log.liveOn(60, 90, 5_000 * ms)                         // first note defines time 0
        log.liveOn(64, 80, 5_250 * ms)
        log.liveOff(60, 5_500 * ms)
        assertEquals(listOf(StudioNoteEvent(0, 500, 60, 90)), log.snapshotLiveIfDirty())   // 64 still held
        assertNull(log.snapshotLiveIfDirty())
        log.liveOff(64, 6_000 * ms)
        assertEquals(listOf(StudioNoteEvent(0, 500, 60, 90), StudioNoteEvent(250, 1_000, 64, 80)), log.snapshotLiveIfDirty())
    }

    @Test fun liveIsIndependentOfTheTakeGate() {
        val log = InstrumentEventLog()
        log.arm(beat1)
        log.liveOn(60, 90, 0); log.liveOff(60, 100 * ms)
        assertEquals(1, log.snapshotLiveIfDirty()!!.size)
        assertEquals(0, log.recordedCount)
    }

    @Test fun liveCaptureStopsAtBudgetAndClearResets() {
        val log = InstrumentEventLog()
        for (i in 0 until InstrumentEventLog.MAX_LIVE_EVENTS + 25) {
            log.liveOn(60, 90, i * ms); log.liveOff(60, i * ms + 1)
        }
        assertTrue(log.liveCaptureFull)
        assertEquals(InstrumentEventLog.MAX_LIVE_EVENTS, log.snapshotLiveIfDirty()!!.size)
        log.clearLive()
        assertFalse(log.liveCaptureFull)
        assertEquals(emptyList<StudioNoteEvent>(), log.snapshotLiveIfDirty())
        log.liveOn(60, 90, 99_000 * ms); log.liveOff(60, 99_100 * ms)    // re-anchors at the next first note
        assertEquals(listOf(StudioNoteEvent(0, 100, 60, 90)), log.snapshotLiveIfDirty())
    }

    @Test fun setLiveReplacesEventsButKeepsAnchorForLaterNotes() {
        val log = InstrumentEventLog()
        log.liveOn(60, 90, 1_000 * ms); log.liveOff(60, 1_100 * ms)
        log.setLive(listOf(StudioNoteEvent(0, 50, 72, 64)))
        log.liveOn(62, 90, 1_400 * ms); log.liveOff(62, 1_500 * ms)
        assertEquals(listOf(StudioNoteEvent(0, 50, 72, 64), StudioNoteEvent(400, 500, 62, 90)), log.snapshotLiveIfDirty())
    }

    @Test fun concurrentProducersLoseNoCompletedNotes() {
        val log = InstrumentEventLog()
        log.arm(0)
        val n = 500
        val start = CountDownLatch(1)
        val threads = (0 until 4).map { t ->
            thread {
                start.await()
                for (i in 0 until n) { val note = 20 + t * 20 + (i % 20); log.noteOn(note, 90, (i * 10L + 1) * ms); log.noteOff(note, (i * 10L + 5) * ms) }
            }
        }
        start.countDown(); threads.forEach { it.join() }
        assertEquals(4 * n, log.disarmAndFinish(10_000 * ms).size)
    }
}

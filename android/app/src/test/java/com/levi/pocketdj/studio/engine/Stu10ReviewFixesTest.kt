package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.screens.producer.instruments.LiveStaffSave
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

private fun ev(on: Int, off: Int, note: Int = 60) = StudioNoteEvent(on, off, note, 90)

/** Review fixes for STU-10: overdub staffs are saved/finished/cleared with the live score. */
class LiveStaffSaveExtrasTest {
    @Test fun saveFilesTheOverdubStaffsAsExtraStaffsOfTheTake() {
        val extras = listOf(LiveExtraStaff("s2", InstrumentKey.VIOLIN, listOf(ev(0, 900, 64))), LiveExtraStaff("s3", InstrumentKey.HARP, listOf(ev(0, 400, 67))))
        val r = LiveStaffSave.result(listOf(ev(0, 500)), InstrumentKey.PIANO, extras) { "tk_x" }!!
        assertEquals(extras, r.extraStaffs)
        assertEquals(InstrumentKey.PIANO, r.instrument)
        assertEquals("duration covers the longest staff", 900, r.durationMs)
    }

    @Test fun overdubFromSilenceStillSavesWithTheFirstExtraAsPrimary() {
        val extras = listOf(LiveExtraStaff("s2", InstrumentKey.VIOLIN, listOf(ev(0, 900, 64))), LiveExtraStaff("s3", InstrumentKey.HARP, listOf(ev(0, 400, 67))))
        val r = LiveStaffSave.result(emptyList(), InstrumentKey.PIANO, extras) { "tk_x" }!!
        assertEquals(InstrumentKey.VIOLIN, r.instrument)
        assertEquals(listOf(ev(0, 900, 64)), r.events)
        assertEquals(listOf("s3"), r.extraStaffs.map { it.id })
    }

    @Test fun nothingToSaveWhenEveryStaffIsEmpty() {
        assertNull(LiveStaffSave.result(emptyList(), InstrumentKey.PIANO, listOf(LiveExtraStaff("s2", InstrumentKey.HARP, emptyList()))))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class OverdubLifecycleTest {
    private class Rig(val t: TestScope) {
        val sink = FakeSink()
        val voices = ArrayList<FakeSynth>()
        val engine = InstrumentEngine(
            sinkFactory = { sink }, scope = t.backgroundScope,
            synthFactory = { FakeSynth().also { voices.add(it) } },
            loadDispatcher = StandardTestDispatcher(t.testScheduler),
            nanoClock = { t.currentTime * 1_000_000L },
        )
        suspend fun load() = engine.loadInstrument(InstrumentKey.PIANO, File("/bank.sf2"))
    }

    @Test fun leavingPlayFinishesTheArmedPassStopsTheBackingAndFilesTheStaff() = runTest {
        val r = Rig(this); r.load(); val e = r.engine
        e.setLiveEvents(listOf(ev(0, 1000)))
        assertTrue(e.overdub.start(0, 1000, loop = true, anchorNanos = currentTime * 1_000_000L))
        assertTrue(e.replay(emptyList(), 0, listOf(e.createVoice() to e.state.value.liveEvents), 0 to 1000))
        e.noteOn(64, 90); advanceTimeBy(200); e.noteOff(64)
        assertTrue(e.state.value.isReplaying)

        assertEquals(OverdubFinish.ADDED, e.finishOverdub(InstrumentKey.PIANO))   // what the Play section's onDispose calls

        assertFalse(e.overdub.isActive)
        assertFalse("the looping backing must not outlive the screen", e.state.value.isReplaying)
        assertEquals(1, e.overdub.state.value.staffs.size)
        // the next note goes to the live staff again, not into a stale armed capture
        e.noteOn(70, 90); advanceTimeBy(50); e.noteOff(70)
        assertEquals(0, e.overdub.capture.count)
        assertTrue(e.eventLog.snapshotLiveIfDirty().orEmpty().any { it.note == 70 })
    }

    @Test fun finishWithoutAPassIsInactiveAndAnEmptyPassAddsNoStaff() = runTest {
        val r = Rig(this); r.load(); val e = r.engine
        assertEquals(OverdubFinish.INACTIVE, e.finishOverdub(InstrumentKey.PIANO))
        assertTrue(e.overdub.start(0, anchorNanos = currentTime * 1_000_000L))
        assertEquals(OverdubFinish.NOTHING, e.finishOverdub(InstrumentKey.PIANO))
        assertTrue(e.overdub.state.value.staffs.isEmpty())
    }

    @Test fun clearLiveScoreEndsAnArmedPassUnfiledAndDropsTheOverdubStaffs() = runTest {
        val r = Rig(this); r.load(); val e = r.engine
        e.overdub.appendStaff(InstrumentKey.HARP, listOf(ev(0, 800)))
        e.setLiveEvents(listOf(ev(0, 1000)))
        assertTrue(e.overdub.start(0, 1000, anchorNanos = currentTime * 1_000_000L))
        e.noteOn(64, 90); advanceTimeBy(100); e.noteOff(64)
        e.replay(e.state.value.liveEvents, 0)
        assertTrue(e.state.value.isReplaying)

        e.clearLiveScore()

        assertFalse(e.overdub.isActive)
        assertFalse(e.state.value.isReplaying)
        assertTrue("staffs 2-4 go with the live staff", e.overdub.state.value.staffs.isEmpty())
        assertTrue(e.state.value.liveEvents.isEmpty())
        assertEquals("the unfiled pass is discarded", 0, e.overdub.state.value.staffs.size)
        assertEquals(0, OverdubMath.scoreEndMs(listOf(e.state.value.liveEvents) + e.overdub.state.value.staffs.map { it.events }))
    }

    @Test fun loopWrapNeverSilencesTheUsersVoiceWhenTheBackingHasItsOwn() = runTest {
        val r = Rig(this); r.load(); val e = r.engine
        val user = r.voices.first()
        val backingVoice = e.createVoice()
        // staff 1 plays through its own voice; the primary carries no backing events
        assertTrue(e.replay(emptyList(), 0, listOf(backingVoice to listOf(ev(0, 400))), 0 to 1000))
        e.noteOn(72, 100)                                  // the user holds a note across the wrap
        advanceTimeBy(1_500); runCurrent()
        assertTrue("the user's held note must survive the loop wrap", user.hits.none { it.note == 72 && !it.on })
        e.stopReplay()
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ArpStopRaceTest {
    @Test fun aStopLandingDuringAStrikeStillClosesThatNote() = runTest {
        val log = ArrayList<Pair<Int, Boolean>>()
        lateinit var arp: ArpeggiatorEngine
        var stopped = false
        val host = object : ArpHost {
            override fun arpStrikeOn(note: Int) { log.add(note to true); if (!stopped) { stopped = true; arp.stop() } }   // stop() races the onset
            override fun arpStrikeOff(note: Int) { log.add(note to false) }
            override fun arpPreviewOn(note: Int, velocity: Int) {}
            override fun arpPreviewOff(note: Int) {}
        }
        arp = ArpeggiatorEngine(backgroundScope, host, nowMs = { currentTime }, rng = { Random(7) })
        arp.setEnabled(true); arp.setProgramming(true); arp.consumeKeyOn(60, 90)
        arp.setProgramming(false)
        assertTrue(arp.start(120.0))
        advanceTimeBy(500); runCurrent()
        val last = log.last { it.first == 60 }
        assertFalse("the final event for the note must be its gate-off", last.second)
        assertNotNull(log.firstOrNull { it.second })
        assertFalse(arp.isPlaying)
    }

    @Test fun aStopBeforeTheOnsetSuppressesTheStrike() = runTest {
        val log = ArrayList<Pair<Int, Boolean>>()
        val host = object : ArpHost {
            override fun arpStrikeOn(note: Int) { log.add(note to true) }
            override fun arpStrikeOff(note: Int) { log.add(note to false) }
            override fun arpPreviewOn(note: Int, velocity: Int) {}
            override fun arpPreviewOff(note: Int) {}
        }
        val arp = ArpeggiatorEngine(backgroundScope, host, nowMs = { currentTime }, rng = { Random(7) })
        arp.setEnabled(true); arp.setProgramming(true); arp.consumeKeyOn(60, 90)
        assertTrue(arp.start(120.0)); arp.stop(); advanceTimeBy(500); runCurrent()
        assertTrue("nothing may sound after stop", log.none { it.second })
    }
}

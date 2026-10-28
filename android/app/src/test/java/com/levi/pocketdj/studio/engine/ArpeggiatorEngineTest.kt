package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.studio.model.InstrumentKey
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

class ArpPatternTest {
    private val rng = Random(1)
    private fun cycle(notes: List<Int>, order: ArpOrder, oct: Int = 1) = ArpPattern.cycle(notes, order, oct, rng)

    @Test fun upDownSortRegardlessOfRecordedOrder() {
        assertEquals(listOf(60, 64, 67), cycle(listOf(67, 60, 64), ArpOrder.UP))
        assertEquals(listOf(67, 64, 60), cycle(listOf(67, 60, 64), ArpOrder.DOWN))
    }

    @Test fun exclusiveNeverRepeatsEndpointsBackToBack() {
        assertEquals(listOf(60, 64, 67, 64), cycle(listOf(60, 64, 67), ArpOrder.EXCLUSIVE))
        assertEquals(listOf(60, 64), cycle(listOf(60, 64), ArpOrder.EXCLUSIVE))
        assertEquals(listOf(60), cycle(listOf(60), ArpOrder.EXCLUSIVE))
    }

    @Test fun inclusiveRepeatsBothEndpoints() {
        assertEquals(listOf(60, 64, 67, 67, 64, 60), cycle(listOf(60, 64, 67), ArpOrder.INCLUSIVE))
        assertEquals(listOf(60, 60), cycle(listOf(60), ArpOrder.INCLUSIVE))
    }

    @Test fun orderKeepsRecordedOrderPerOctave() {
        assertEquals(listOf(67, 60, 79, 72), cycle(listOf(67, 60), ArpOrder.ORDER, 2))
    }

    @Test fun octavesReplicateClampDedupeAndDropOutOfRange() {
        assertEquals(listOf(60, 72, 84, 96), ArpPattern.pool(listOf(60), 4))
        assertEquals(listOf(60), ArpPattern.pool(listOf(60), 0))                   // clamped up to 1
        assertEquals(listOf(60, 72, 84, 96), ArpPattern.pool(listOf(60), 9))       // clamped down to 4
        assertEquals(listOf(60, 72), ArpPattern.pool(listOf(60, 72), 2).take(2))
        assertEquals(listOf(60, 72, 84), ArpPattern.pool(listOf(60, 72), 2).distinct().take(3))
        assertEquals(listOf(120, 127), ArpPattern.pool(listOf(120, 127), 2).take(2))
        assertEquals(listOf(125), ArpPattern.pool(listOf(125), 4))                 // 137+ are out of MIDI range
        assertTrue(ArpPattern.pool(emptyList(), 2).isEmpty())
    }

    @Test fun randomIsSeededDeterministicPoolSizedAndFromThePool() {
        val notes = listOf(60, 62, 64, 65)
        val a = ArpPattern.cycle(notes, ArpOrder.RANDOM, 2, Random(42))
        val b = ArpPattern.cycle(notes, ArpOrder.RANDOM, 2, Random(42))
        assertEquals(a, b)
        assertEquals(8, a.size)
        assertTrue(ArpPattern.pool(notes, 2).containsAll(a))
        assertTrue(ArpPattern.cycle(notes, ArpOrder.RANDOM, 2, Random(43)) != a)
    }

    @Test fun stepMsIsPureNoteValueMath() {
        assertEquals(125.0, ArpPattern.stepMs(ArpStepLength.SIXTEENTH, 120.0), 1e-9)
        assertEquals(500.0, ArpPattern.stepMs(ArpStepLength.QUARTER, 120.0), 1e-9)
        assertEquals(62.5, ArpPattern.stepMs(ArpStepLength.THIRTYSECOND, 120.0), 1e-9)
        assertEquals(ArpPattern.stepMs(ArpStepLength.EIGHTH, 120.0), ArpPattern.stepMs(ArpStepLength.EIGHTH, 0.0), 1e-9)   // bad bpm -> 120
        assertEquals(ArpPattern.stepMs(ArpStepLength.EIGHTH, 120.0), ArpPattern.stepMs(ArpStepLength.EIGHTH, Double.NaN), 1e-9)
    }

    @Test fun onsetFollowsPairFormulaWithSwing() {
        val step = 125.0                                   // pairMs = 250
        assertEquals(0, ArpPattern.onsetMs(0, step, 50.0))
        assertEquals(125, ArpPattern.onsetMs(1, step, 50.0))    // straight
        assertEquals(250, ArpPattern.onsetMs(2, step, 50.0))
        assertEquals(375, ArpPattern.onsetMs(3, step, 50.0))
        // (k/2)*pair + (odd ? pair*s : 0)
        assertEquals(Math.round(250 * 0.667).toInt(), ArpPattern.onsetMs(1, step, 66.7))
        assertEquals(250 + Math.round(250 * 0.75).toInt(), ArpPattern.onsetMs(3, step, 75.0))
        assertEquals(ArpPattern.onsetMs(1, step, 75.0), ArpPattern.onsetMs(1, step, 99.0))   // clamped at 75
        assertEquals(ArpPattern.onsetMs(1, step, 50.0), ArpPattern.onsetMs(1, step, 10.0))   // clamped at 50
    }

    @Test fun onsetClampsWildInputBeforeIntConversion() {
        assertEquals(0, ArpPattern.onsetMs(-5, 125.0, 50.0))
        assertEquals(0, ArpPattern.onsetMs(3, Double.NaN, 50.0))
        assertEquals(ArpPattern.MAX_ONSET_MS, ArpPattern.onsetMs(Int.MAX_VALUE, 1e12, 50.0))
    }

    @Test fun gateOffIsEightyPercentOfTheGapToTheNextOnset() {
        assertEquals(100, ArpPattern.gateOffMs(0, 125.0, 50.0))
        // swung: step 0 gap = 187.5 (75%) -> 150; step 1 gap = 62.5 -> 187.5 + 50
        assertEquals(150, ArpPattern.gateOffMs(0, 125.0, 75.0))
        assertEquals(Math.round(187.5 + 0.8 * 62.5).toInt(), ArpPattern.gateOffMs(1, 125.0, 75.0))
        assertTrue(ArpPattern.gateOffMs(1, 125.0, 75.0) < ArpPattern.onsetMs(2, 125.0, 75.0))
    }

    @Test fun cycleSpanRoundsUpToWholePairs() {
        assertEquals(250, ArpPattern.cycleSpanMs(1, 125.0))
        assertEquals(250, ArpPattern.cycleSpanMs(2, 125.0))
        assertEquals(500, ArpPattern.cycleSpanMs(3, 125.0))
    }

    @Test fun persistedKnobsDegradeInsteadOfCrashing() {
        val d = ArpSettings.fromPersisted("sideways", 7, 99, Double.NaN, false)
        assertEquals(ArpSettings(ArpOrder.UP, ArpStepLength.SIXTEENTH, 4, 50.0, false), d)
        val ok = ArpSettings.fromPersisted("inclusive", 8, 0, 200.0, true)
        assertEquals(ArpSettings(ArpOrder.INCLUSIVE, ArpStepLength.EIGHTH, 1, 75.0, true), ok)
        assertEquals(listOf("up", "down", "exclusive", "inclusive", "order", "random"), ArpOrder.entries.map { it.raw })
        assertEquals(listOf(32, 16, 8, 4), ArpStepLength.entries.map { it.denominator })
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ArpTransportTest {
    private class Host(val t: TestScope) : ArpHost {
        val log = ArrayList<Triple<Long, Int, Boolean>>()
        val previews = ArrayList<Triple<Long, Int, Boolean>>()
        override fun arpStrikeOn(note: Int) { log.add(Triple(t.currentTime, note, true)) }
        override fun arpStrikeOff(note: Int) { log.add(Triple(t.currentTime, note, false)) }
        override fun arpPreviewOn(note: Int, velocity: Int) { previews.add(Triple(t.currentTime, note, true)) }
        override fun arpPreviewOff(note: Int) { previews.add(Triple(t.currentTime, note, false)) }
    }
    private fun rig(t: TestScope): Pair<ArpeggiatorEngine, Host> {
        val h = Host(t)
        return ArpeggiatorEngine(t.backgroundScope, h, nowMs = { t.currentTime }, rng = { Random(7) }) to h
    }

    @Test fun latchOffPlaysExactlyOneCycleThenPauses() = runTest {
        val (arp, host) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true)
        arp.consumeKeyOn(60, 90); arp.consumeKeyOn(64, 90)
        arp.setSettings(ArpSettings(latch = false))
        assertTrue(arp.start(120.0))
        assertTrue(arp.isPlaying)
        advanceTimeBy(10_000); runCurrent()
        assertEquals(listOf(Triple(0L, 60, true), Triple(100L, 60, false), Triple(125L, 64, true), Triple(225L, 64, false)), host.log)
        assertFalse("latch OFF auto-pauses after one cycle", arp.isPlaying)
    }

    @Test fun latchOnLoopsOnTheGridUntilPaused() = runTest {
        val (arp, host) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true)
        arp.consumeKeyOn(60, 90); arp.consumeKeyOn(64, 90)
        assertTrue(arp.start(120.0))
        advanceTimeBy(1_000); runCurrent()
        assertTrue(arp.isPlaying)
        val ons = host.log.filter { it.third }.map { it.first to it.second }
        assertEquals(listOf(0L to 60, 125L to 64, 250L to 60, 375L to 64, 500L to 60, 625L to 64, 750L to 60, 875L to 64, 1000L to 60), ons)
        arp.stop()
        assertFalse(arp.isPlaying)
        val n = host.log.size
        advanceTimeBy(2_000); runCurrent()
        assertEquals("nothing strikes after pause", n, host.log.size)
    }

    @Test fun pauseWhileSoundingClosesTheNoteThroughTheGateOffPath() = runTest {
        val (arp, host) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true); arp.consumeKeyOn(60, 90)
        arp.start(120.0)
        advanceTimeBy(50); runCurrent()                       // note 60 on, gate-off at 100
        assertEquals(listOf(Triple(0L, 60, true)), host.log)
        arp.stop()
        assertEquals(Triple(50L, 60, false), host.log.last())
    }

    @Test fun cycleIsRegeneratedAtTheBoundaryFromTheCurrentSet() = runTest {
        val (arp, host) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true); arp.consumeKeyOn(60, 90)
        arp.start(120.0)
        advanceTimeBy(100); runCurrent()
        arp.consumeKeyOn(67, 90)                              // program while playing
        advanceTimeBy(900); runCurrent()
        val notes = host.log.filter { it.third }.map { it.second }
        assertEquals(60, notes.first())
        assertTrue("added note enters on a later cycle", 67 in notes)
    }

    @Test fun startRefusedWithNoNotes() = runTest {
        val (arp, _) = rig(this)
        assertFalse(arp.start(120.0))
        assertFalse(arp.isPlaying)
    }

    @Test fun togglingASelectedNoteRemovesItSilently() = runTest {
        val (arp, host) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true)
        arp.consumeKeyOn(60, 90); arp.consumeKeyOn(60, 90)
        assertTrue(arp.selectedNotes.isEmpty())
        assertEquals("only the add previews", 1, host.previews.count { it.third })
    }

    @Test fun previewSoundsOnceThenSelfTerminates() = runTest {
        val (arp, host) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true); arp.consumeKeyOn(60, 90)
        advanceTimeBy(ArpeggiatorEngine.PREVIEW_MS + 10); runCurrent()
        assertEquals(listOf(Triple(0L, 60, true), Triple(ArpeggiatorEngine.PREVIEW_MS, 60, false)), host.previews)
    }

    @Test fun previewDoesNotCutANoteTheSchedulerIsSounding() = runTest {
        val (arp, host) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true)
        arp.stepForTesting(62, on = true)                     // the scheduler is sounding 62 (owns its gate-off)
        arp.consumeKeyOn(62, 90)                              // program-add 62 -> audition
        advanceTimeBy(ArpeggiatorEngine.PREVIEW_MS + 10); runCurrent()
        assertTrue(host.previews.any { it.second == 62 && it.third })
        assertFalse("the audition must not cut a scheduler-owned note", host.previews.any { it.second == 62 && !it.third })
        arp.stepForTesting(62, on = false)
        assertEquals(Triple(ArpeggiatorEngine.PREVIEW_MS + 10, 62, false), host.log.last())
    }

    @Test fun disablingKeepsTheSetPausesAndLeavesProgramMode() = runTest {
        val (arp, _) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true); arp.consumeKeyOn(60, 90)
        arp.start(120.0)
        arp.setEnabled(false)
        assertFalse(arp.isPlaying)
        assertFalse(arp.state.value.programming)
        assertEquals(listOf(60), arp.selectedNotes)
        assertFalse("keys are no longer consumed once off", arp.consumeKeyOn(62, 90))
    }

    @Test fun clearingStopsTheTransportAndEmptiesTheSet() = runTest {
        val (arp, _) = rig(this)
        arp.setEnabled(true); arp.setProgramming(true); arp.consumeKeyOn(60, 90)
        arp.start(120.0)
        arp.clearSelection()
        assertFalse(arp.isPlaying); assertTrue(arp.selectedNotes.isEmpty())
    }

    @Test fun programModeRequiresTheMasterSwitch() = runTest {
        val (arp, _) = rig(this)
        arp.setProgramming(true)
        assertFalse(arp.state.value.programming)
        assertFalse(arp.consumeKeyOn(60, 90))
    }
}

/** Engine-level pins: the arp and program mode against the REAL InstrumentEngine write paths. */
@OptIn(ExperimentalCoroutinesApi::class)
class ArpEngineIntegrationTest {
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

    @Test fun programModeWritesNothingToAnyScoreEvenWhileTheTransportPlays() = runTest {
        val r = Rig(this); r.load()
        val e = r.engine
        e.arp.setEnabled(true); e.arp.setProgramming(true)
        e.noteOn(60, 100); advanceTimeBy(40); e.noteOff(60)
        // program key presses: no live stream, no take stream, no overdub stream
        assertNull(e.eventLog.snapshotLiveIfDirty())
        assertEquals(0, e.eventLog.recordedCount)
        assertEquals(0, e.overdub.capture.count)
        assertEquals(listOf(60), e.arp.selectedNotes)

        // transport playing: it captures ITS OWN strikes like hand keys, but a program key press adds nothing
        assertTrue(e.startArp(120.0))
        advanceTimeBy(10); runCurrent()
        val before = e.eventLog.snapshotLiveIfDirty()
        e.noteOn(72, 100); e.noteOff(72)
        val after = e.eventLog.snapshotLiveIfDirty()
        assertTrue("the program key 72 must not reach the live staff", (before.orEmpty() + after.orEmpty()).none { it.note == 72 })
        assertEquals(0, e.overdub.capture.count)
        assertTrue(72 in e.arp.selectedNotes)
        e.arp.stop()
    }

    @Test fun arpNotesGoToTheOverdubStaffInsteadOfLive() = runTest {
        val r = Rig(this); r.load()
        val e = r.engine
        assertTrue(e.overdub.start(0, scoreEndMs = Int.MAX_VALUE, anchorNanos = currentTime * 1_000_000L))
        e.arp.setEnabled(true); e.arp.setProgramming(true); e.noteOn(60, 100)
        e.arp.setProgramming(false)
        e.arp.setSettings(ArpSettings(latch = false))
        assertTrue(e.startArp(120.0))
        advanceTimeBy(500); runCurrent()
        assertNull("arp strikes must NOT also write the live staff", e.eventLog.snapshotLiveIfDirty())
        val captured = e.overdub.stop()
        assertEquals(1, captured.size)
        assertEquals(60, captured[0].note)
        assertEquals(0, captured[0].onMs)
        assertEquals(100, captured[0].offMs)
    }

    @Test fun handNotesDuringOverdubSkipTheLiveStaffButAnEarlierNoteStillCloses() = runTest {
        val r = Rig(this); r.load()
        val e = r.engine
        e.noteOn(50, 90)                                      // pressed BEFORE the pass armed -> live staff
        advanceTimeBy(100)
        assertTrue(e.overdub.start(0, anchorNanos = currentTime * 1_000_000L))
        e.noteOn(64, 90); advanceTimeBy(200); e.noteOff(64)
        e.noteOff(50)                                          // liveOff is unconditional
        val live = e.eventLog.snapshotLiveIfDirty().orEmpty()
        assertEquals(listOf(50), live.map { it.note })
        val od = e.overdub.stop()
        assertEquals(listOf(64), od.map { it.note })
        assertEquals(200, od[0].offMs - od[0].onMs)
    }

    @Test fun loopingBackingRepeatsTheRegionAndWrapsItsCursor() = runTest {
        val r = Rig(this); r.load()
        val e = r.engine
        val ev = listOf(com.levi.pocketdj.studio.model.StudioNoteEvent(0, 400, 60, 90))
        assertTrue(e.replay(ev, 0, emptyList(), 0 to 1000))
        advanceTimeBy(2_500); runCurrent()
        val ons = r.voices.first().hits.count { it.on && it.note == 60 }
        assertEquals("iterations at 0, 1000, 2000", 3, ons)
        assertEquals(500, e.replayPositionMs())               // 2500 wraps into [0,1000)
        e.stopReplay()
    }
}

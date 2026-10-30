package com.levi.pocketdj.studio.engine

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

@OptIn(ExperimentalCoroutinesApi::class)
class InstrumentEngineTest {
    private class Rig(val t: TestScope, val loadOk: Boolean = true) {
        val sink = FakeSink()
        val voices = ArrayList<FakeSynth>()
        val engine = InstrumentEngine(
            sinkFactory = { sink }, scope = t.backgroundScope,
            synthFactory = { FakeSynth(loadOk).also { voices.add(it) } },
            loadDispatcher = StandardTestDispatcher(t.testScheduler),
            nanoClock = { t.currentTime * 1_000_000L },
            focus = { focusCalls++ },
        )
        var focusCalls = 0
        suspend fun load(key: InstrumentKey = InstrumentKey.PIANO) = engine.loadInstrument(key, File("/bank.sf2"))
    }

    @Test fun loadPublishesLoadingStateOffTheCallerAndSelectsTheGmProgram() = runTest {
        val r = Rig(this)
        assertFalse(r.engine.isReady)
        val ok = r.load(InstrumentKey.VIOLIN)
        assertTrue(ok)
        assertTrue(r.engine.isReady)
        assertEquals(InstrumentKey.VIOLIN, r.engine.state.value.currentInstrument)
        assertFalse(r.engine.state.value.isLoadingInstrument)
        assertEquals(40, r.voices.single().program)
        assertEquals("/bank.sf2", r.voices.single().loadedPath)
    }

    @Test fun failedLoadReportsAnErrorAndLeavesThePreviousInstrumentPlaying() = runTest {
        val good = Rig(this)
        assertTrue(good.load(InstrumentKey.PIANO))
        val bad = InstrumentEngine({ good.sink }, backgroundScope, { FakeSynth(loadOk = false) }, StandardTestDispatcher(testScheduler), { currentTime * 1_000_000L })
        assertFalse(bad.loadInstrument(InstrumentKey.HARP, File("/missing.sf2")))
        assertEquals("Couldn't load the Harp sound bank", bad.state.value.loadError)
        assertFalse(bad.state.value.isLoadingInstrument)
        assertNull(bad.state.value.currentInstrument)
        assertEquals(InstrumentKey.PIANO, good.engine.state.value.currentInstrument)
    }

    @Test fun reloadRetiresTheOldVoiceAfterADelayNeverWhileRendering() = runTest {
        val r = Rig(this)
        r.load(InstrumentKey.PIANO)
        r.load(InstrumentKey.TRUMPET)
        val (first, second) = r.voices
        runCurrent()
        assertFalse("old voice must outlive any in-flight render block", first.closed)
        advanceTimeBy(InstrumentEngine.RETIRE_DELAY_MS + 50)
        assertTrue(first.closed); assertFalse(second.closed)
        assertEquals(56, second.program)
    }

    @Test fun keyNoteReachesTheSynthOnTheCallingThreadWithNoHop() = runTest {
        val r = Rig(this); r.load()
        var thread: String? = null
        val t = Thread({ r.engine.noteOn(60, 100); thread = Thread.currentThread().name }, "pdj-keys-test")
        t.start(); t.join()
        val hit = r.voices.single().hits.single()
        assertTrue(hit.on); assertEquals(60, hit.note)
        assertEquals("pdj-keys-test", hit.thread)          // the native synth was called ON the caller's thread
        assertEquals(thread, hit.thread)
        assertEquals(1, r.sink.starts)                      // output wakes on the first note
    }

    @Test fun freePlayIsCapturedLiveEvenWithNothingLoaded() = runTest {
        val r = Rig(this)
        r.engine.noteOn(64, 90)
        advanceTimeBy(250); r.engine.noteOff(64)
        advanceTimeBy(100)
        assertEquals(0, r.sink.starts)                      // nothing to hear => output stays asleep
        assertEquals(listOf(StudioNoteEvent(0, 250, 64, 90)), r.engine.state.value.liveEvents)
        r.engine.clearLive()
        assertTrue(r.engine.state.value.liveEvents.isEmpty())
    }

    @Test fun highlightsArePublishedCoalescedAndClearOnRelease() = runTest {
        val r = Rig(this); r.load()
        r.engine.noteOn(60); r.engine.noteOn(64)
        advanceTimeBy(100)
        assertEquals(setOf(60, 64), r.engine.state.value.pressedNotes)
        r.engine.noteOff(60)
        advanceTimeBy(100)
        assertEquals(setOf(64), r.engine.state.value.pressedNotes)
    }

    @Test fun outputGoesToSleepWhenIdleAndWakesOnTheNextNote() = runTest {
        val r = Rig(this); r.load()
        r.engine.noteOn(60); advanceTimeBy(50); r.engine.noteOff(60)
        advanceTimeBy(InstrumentEngine.IDLE_NANOS / 1_000_000L + 2_000)
        assertEquals(1, r.sink.stops)
        r.engine.noteOn(62)
        assertEquals(2, r.sink.starts)
    }

    @Test fun clickAndSynthMixIntoLiveOutputAndClampToUnity() = runTest {
        val r = Rig(this); r.load()
        r.engine.setClickEnabled(true, 120.0)
        assertTrue(r.engine.state.value.clickEnabled)
        val lead = (ClickTrack.START_LEAD_SEC * 44_100).toInt()
        val pre = r.sink.pull(lead)
        assertTrue("silent before the click's start frame", pre.all { it == 0f })
        val bar = ClickTrack.makeBar(120.0, 44_100)
        val blk = r.sink.pull(64)
        for (i in 0 until 64) assertEquals(bar[i], blk[2 * i], 1e-6f)
        r.engine.noteOn(60)                                  // fake synth holds 0.5 on top of the click
        val mixed = r.sink.pull(64)
        for (i in 0 until 64) assertEquals((bar[64 + i] + 0.5f).coerceAtMost(1f), mixed[2 * i], 1e-5f)
        assertTrue(mixed.all { it in -1f..1f })
    }

    @Test fun takeCannotStartWithoutAnInstrumentOrWhileRecording() = runTest {
        val r = Rig(this)
        assertFalse(r.engine.startTake(120.0, click = true, countIn = true))
        r.load()
        assertTrue(r.engine.startTake(120.0, click = false, countIn = false))
        assertFalse(r.engine.startTake(120.0, click = false, countIn = false))
        assertNotNull(r.engine.stopTake())
        assertNull(r.engine.stopTake())
    }

    @Test fun missingNativeLibraryIsALoadErrorNotACrash() = runTest {
        val sink = FakeSink()
        val engine = InstrumentEngine({ sink }, backgroundScope, { throw UnsatisfiedLinkError("libpdjdsp") },
            StandardTestDispatcher(testScheduler), { currentTime * 1_000_000L })
        assertFalse(engine.loadInstrument(InstrumentKey.PIANO, File("/bank.sf2")))
        assertNotNull(engine.state.value.loadError)
        assertFalse(engine.state.value.isLoadingInstrument)
        assertFalse(engine.isReady)
    }

    @Test fun clickToggledMidTakeReentersOnTheTakesBeatGrid() = runTest {
        val r = Rig(this); r.load()
        r.engine.startTake(120.0, click = false, countIn = false)      // beat 1 = output frame 11025; beat = 22050 frames
        r.sink.pull(57_330)                                            // 1.3 s of output
        r.engine.setClickEnabled(true)
        // next grid beat at/after now+50 ms: 11025 + 3*22050 = 77175 (beat index 3, not the accent)
        val before = r.sink.pull(77_175 - 57_330)
        assertTrue("silent until the next grid beat", before.all { it == 0f })
        val tick = r.sink.pull(441)
        assertTrue("click starts exactly on the grid beat", tick.any { it != 0f })
        val bar = ClickTrack.makeBar(120.0, 44_100)
        for (i in 0 until 441) assertEquals(bar[3 * 22_050 + i], tick[2 * i], 1e-6f)   // beat 4 of the bar (1000 Hz), phase kept
    }

    @Test fun takeBeat1IncludesOutputLatency() = runTest {
        val sink = FakeSink(latency = 4_410)                           // 100 ms
        val engine = InstrumentEngine({ sink }, backgroundScope, { FakeSynth() }, StandardTestDispatcher(testScheduler), { currentTime * 1_000_000L })
        engine.loadInstrument(InstrumentKey.PIANO, File("/bank.sf2"))
        engine.startTake(100.0, click = false, countIn = false)
        advanceTimeBy(250)                                             // the scheduled click time, but not yet AUDIBLE
        engine.noteOn(60); advanceTimeBy(100); engine.noteOff(60)
        advanceTimeBy(100)
        engine.noteOn(62); advanceTimeBy(50); engine.noteOff(62)
        assertEquals(listOf(StudioNoteEvent(100, 150, 62, 96)), engine.stopTake()!!.events.filter { it.note == 62 })
    }

    @Test fun takeEventsAreMsFromBeat1AfterTheCountInAndTheCountInIsNotRecorded() = runTest {
        val r = Rig(this); r.load()
        assertTrue(r.engine.startTake(bpm = 120.0, click = true, countIn = true))
        assertTrue(r.engine.state.value.isRecordingTake); assertTrue(r.engine.state.value.isCountingIn)
        // beat 1 = start lead (250 ms) + one 4/4 bar at 120 BPM (2000 ms) = 2250 ms
        advanceTimeBy(1_000); r.engine.noteOn(48); advanceTimeBy(200); r.engine.noteOff(48)   // warm-up in the count-in
        advanceTimeBy(1_300)                                                                      // t = 2500 => beat1 + 250
        assertFalse(r.engine.state.value.isCountingIn)
        r.engine.noteOn(60, 100); advanceTimeBy(500); r.engine.noteOff(60)
        advanceTimeBy(100)
        r.engine.noteOn(64, 80)                                                                   // held at stop
        advanceTimeBy(150)
        val res = r.engine.stopTake()!!
        assertEquals(listOf(StudioNoteEvent(250, 750, 60, 100), StudioNoteEvent(850, 1_000, 64, 80)), res.events)
        assertEquals(1_000, res.durationMs)
        assertEquals(120.0, res.bpm, 0.0)
        assertEquals(InstrumentKey.PIANO, res.instrument)
        assertEquals("take-${res.takeId}.m4a", res.fileName)
        assertTrue(res.takeId.startsWith("tk_"))
        assertFalse(r.engine.state.value.clickEnabled)
        // the 48 warm-up note was heard (it reached the synth) but is not in the take
        assertTrue(r.voices.single().hits.any { it.note == 48 && it.on })
    }

    @Test fun noCountInMeansBeat1IsTheStartLeadAndStopInsideTheCountInCancels() = runTest {
        val r = Rig(this); r.load()
        r.engine.startTake(100.0, click = false, countIn = false)
        advanceTimeBy(250)
        r.engine.noteOn(60); advanceTimeBy(100); r.engine.noteOff(60)
        assertEquals(listOf(StudioNoteEvent(0, 100, 60, 96)), r.engine.stopTake()!!.events)
        r.engine.startTake(100.0, click = true, countIn = true)
        advanceTimeBy(500)
        assertNull(r.engine.stopTake())                      // cancelled during the count-in
        assertFalse(r.engine.state.value.isRecordingTake)
    }

    @Test fun takeTempoIsClampedAndMidTakeClickKeepsTheTakeTempo() = runTest {
        val r = Rig(this); r.load()
        r.engine.startTake(9_999.0, click = false, countIn = false)
        r.engine.setClickEnabled(true, 60.0)                 // mid-take the take's own BPM wins
        advanceTimeBy(300)
        val res = r.engine.stopTake()!!
        assertEquals(300.0, res.bpm, 0.0)
    }

    @Test fun replayFiresEventsThroughTheSynthAtTheirScoreTimeOffsBeforeOns() = runTest {
        val r = Rig(this); r.load()
        val score = listOf(StudioNoteEvent(0, 300, 60, 90), StudioNoteEvent(300, 600, 60, 70), StudioNoteEvent(100, 400, 64, 80))
        assertTrue(r.engine.replay(score))
        assertTrue(r.engine.state.value.isReplaying)
        runCurrent()
        val synth = r.voices.single()
        assertEquals(listOf(60 to true), synth.hits.map { it.note to it.on })       // t=0
        advanceTimeBy(150)
        assertEquals(1, synth.hits.count { it.note == 64 && it.on })
        assertEquals(150, r.engine.replayPositionMs())
        advanceTimeBy(160)                                                             // t=310: 60 re-struck after its off
        val sixty = synth.hits.filter { it.note == 60 }.map { it.on }
        assertEquals(listOf(true, false, true), sixty)
        advanceTimeBy(2_000)
        assertEquals(listOf(true, false, true, false), synth.hits.filter { it.note == 60 }.map { it.on })
        assertFalse(r.engine.state.value.isReplaying)
        assertNull(r.engine.replayPositionMs())
    }

    @Test fun stopReplayParksThePositionAndSilencesHeldNotes() = runTest {
        val r = Rig(this); r.load()
        r.engine.replay(listOf(StudioNoteEvent(0, 5_000, 60, 90)))
        advanceTimeBy(1_200)
        r.engine.stopReplay()
        assertFalse(r.engine.state.value.isReplaying)
        assertEquals(1_200, r.engine.replayPositionMs())     // parked
        advanceTimeBy(6_000)
        assertEquals(1, r.voices.single().hits.size)         // the cancelled score never sent its note-off/any more events
    }

    // ---- ANS-STU-3: transient-loss park/resume of a replay ----

    @Test fun transientLossParksTheReplayAndGainResumesFromThePosition() = runTest {
        val r = Rig(this); r.load()
        val score = listOf(StudioNoteEvent(0, 500, 60, 90), StudioNoteEvent(3_000, 3_500, 62, 90))
        r.engine.replay(score)
        advanceTimeBy(1_200)
        assertTrue(r.engine.isReplayAudible)
        assertTrue(r.engine.parkReplayForInterruption())
        assertFalse(r.engine.isReplayAudible)
        val parked = r.engine.parkedReplay!!
        assertEquals(1_200, parked.positionMs)
        assertEquals(score, parked.args.events)
        advanceTimeBy(5_000)
        assertEquals("a parked score emits nothing", 2, r.voices.single().hits.size)   // note 60 on/off only
        assertTrue(r.engine.resumeReplayFromInterruption())
        assertTrue(r.engine.isReplayAudible)
        assertNull(r.engine.parkedReplay)
        advanceTimeBy(2_000)                                      // resumed at 1200 -> the 3000 note is due at +1800
        assertTrue(r.voices.single().hits.any { it.note == 62 && it.on })
    }

    @Test fun userStopWhileParkedClearsParkAndNeverResumes() = runTest {
        val r = Rig(this); r.load()
        var user = 0
        r.engine.onUserTransport = { user++ }
        r.engine.replay(listOf(StudioNoteEvent(0, 5_000, 60, 90)))
        advanceTimeBy(500)
        r.engine.parkReplayForInterruption()
        r.engine.stopReplay()
        assertNull(r.engine.parkedReplay)
        assertFalse(r.engine.resumeReplayFromInterruption())
        assertTrue(user >= 1)
    }

    @Test fun permanentLossClearsAParkedReplay() = runTest {
        val r = Rig(this); r.load()
        r.engine.replay(listOf(StudioNoteEvent(0, 5_000, 60, 90)))
        advanceTimeBy(500)
        r.engine.parkReplayForInterruption()
        r.engine.stopReplay("focus-loss")
        assertNull(r.engine.parkedReplay)
        assertFalse(r.engine.resumeReplayFromInterruption())
    }

    @Test fun multiStaffReplayEndsOnInterruptionInsteadOfResumingPartially() = runTest {
        val r = Rig(this); r.load()
        val score = listOf(StudioNoteEvent(0, 5_000, 60, 90))
        r.engine.replay(score, extraStaffs = listOf(FakeSynth() to listOf(StudioNoteEvent(0, 5_000, 64, 90))))
        advanceTimeBy(500)
        assertFalse(r.engine.parkReplayForInterruption())
        assertFalse("the arrangement must not silently shrink to the primary voice", r.engine.isReplayAudible)
        assertNull(r.engine.parkedReplay)
        assertFalse(r.engine.resumeReplayFromInterruption())
    }

    @Test fun transientLossSilencesLivePlayedNotesEvenWithoutAReplay() = runTest {
        val r = Rig(this); r.load()
        r.engine.noteOn(60)
        advanceTimeBy(100)
        assertTrue("held live notes count as audible for the interruption coordinator", r.engine.isAudibleForPark)
        r.engine.parkForInterruption()
        assertTrue(r.voices.single().hits.isNotEmpty())
        assertFalse(r.engine.state.value.pressedNotes.isNotEmpty() && r.engine.isReplayAudible)
        assertNull(r.engine.parkedReplay)
    }

    @Test fun liveNotesDuringAParkDropTheParkSoFocusIsNotHeldForever() = runTest {
        val r = Rig(this); r.load()
        var forgot = 0
        r.engine.onUserTransport = { forgot++ }
        r.engine.replay(listOf(StudioNoteEvent(0, 5_000, 60, 90)))
        advanceTimeBy(500)
        assertTrue(r.engine.parkReplayForInterruption())
        advanceTimeBy(10_000)                                   // sink idle-stops (the park holds focus meanwhile)
        forgot = 0
        r.engine.noteOn(64)                                     // re-requests focus: no AUDIOFOCUS_GAIN will ever come
        assertNull(r.engine.parkedReplay)
        assertTrue(forgot >= 1)
    }

    @Test fun parkWithoutAReplayIsANoOp() = runTest {
        val r = Rig(this); r.load()
        assertFalse(r.engine.parkReplayForInterruption())
        assertNull(r.engine.parkedReplay)
    }

    @Test fun replayFromMidScoreChasesTheSoundingNote() = runTest {
        val r = Rig(this); r.load()
        r.engine.replay(listOf(StudioNoteEvent(0, 1_000, 60, 90), StudioNoteEvent(2_000, 2_500, 62, 90)), fromMs = 500)
        runCurrent()
        assertEquals(60, r.voices.single().hits.first().note)    // struck at the seek point
        advanceTimeBy(600)
        assertEquals(listOf(60 to true, 60 to false), r.voices.single().hits.filter { it.note == 60 }.map { it.note to it.on })
    }

    @Test fun replayRefusedWithoutInstrumentOrWhileRecording() = runTest {
        val r = Rig(this)
        assertFalse(r.engine.replay(listOf(StudioNoteEvent(0, 10, 60, 90))))
        r.load()
        assertFalse(r.engine.replay(emptyList()))
        r.engine.startTake(120.0, false, false)
        assertFalse(r.engine.replay(listOf(StudioNoteEvent(0, 10, 60, 90))))
    }

    @Test fun releaseResetsEverythingAndClosesTheVoice() = runTest {
        val r = Rig(this); r.load(); r.engine.noteOn(60)
        r.engine.release()
        assertTrue(r.voices.single().closed)
        assertFalse(r.engine.isReady)
        assertNull(r.engine.state.value.currentInstrument)
    }

    @Test fun replayLogsStartAndStopReason() = runTest {
        captureAudioDiag { lines ->
            val r = Rig(this); r.load()
            assertTrue(r.engine.replay(listOf(StudioNoteEvent(0, 5_000, 60, 90))))
            assertTrue(lines.any { it.startsWith("audio.play owner=studio.instrument reason=user-play") })
            r.engine.stopReplay("focus-loss")
            assertTrue(lines.contains("audio.stop owner=studio.instrument reason=focus-loss"))
        }
    }
}

package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.PcmSource
import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.longestSilence
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.rms
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.store.MixEventKind
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

class StemHandoverTest {
    private val A = Deck.A
    /** 0.5-amp sine RMS (0.354) x the centered crossfader's equal-power -3 dB (0.707). */
    private val TONE_RMS = 0.25

    // ---------------------------------------------------------------- pure rules

    @Test fun handoverReadyCompleteNeedsOnlyToCoverThePlayhead() {
        assertFalse(StemRules.handoverReady(0.04, true, 100.0))
        assertTrue(StemRules.handoverReady(0.06, true, 100.0))
        assertFalse(StemRules.handoverReady(3.9, false, 100.0))
        assertTrue(StemRules.handoverReady(4.0, false, 100.0))
        // near the song's end only what is left is required
        assertTrue(StemRules.handoverReady(1.0, false, 1.05))
        assertFalse(StemRules.handoverReady(0.5, false, 1.05))
    }

    @Test fun balanceFollowsStemOrderMuteBeatsVolume() {
        val b = StemRules.balance(setOf("drums"), mapOf("vocals" to 0.4, "drums" to 0.9, "other" to 7.0))
        assertEquals(listOf(0.4f, 0f, 1f, 1f), b.toList())
    }

    @Test fun stemUnderrunDecisionTable() {
        // far from the frontier: nothing
        assertEquals(StemRules.Underrun.None, StemRules.stemUnderrun(2.0, 8.0, 20.0, true, true, false, false))
        // inside the 1 s lead and the full mix has runway: hand back, keep the intent while the stream lives
        assertEquals(StemRules.Underrun.CutToFullMix(true), StemRules.stemUnderrun(7.2, 8.0, 20.0, true, true, false, false))
        assertEquals(StemRules.Underrun.CutToFullMix(false), StemRules.stemUnderrun(7.2, 8.0, 20.0, true, true, true, false))
        // stems reach the song end: never an underrun
        assertEquals(StemRules.Underrun.None, StemRules.stemUnderrun(19.5, 19.98, 20.0, true, true, false, false))
        // no full-mix runway: play the stems out, then hold
        assertEquals(StemRules.Underrun.None, StemRules.stemUnderrun(7.2, 8.0, 20.0, false, true, false, true))
        assertEquals(StemRules.Underrun.Hold(true), StemRules.stemUnderrun(7.99, 8.0, 20.0, false, true, false, true))
        // neither voice can grow: the song ends
        assertEquals(StemRules.Underrun.EndSong, StemRules.stemUnderrun(7.99, 8.0, 20.0, false, false, false, false))
    }

    @Test fun mainUnderrunAndDeadSourceEnd() {
        assertEquals(StemRules.MainUnderrun.CutToStems, StemRules.mainUnderrun(5.0, 5.5, 20.0, true, false))
        assertEquals(StemRules.MainUnderrun.None, StemRules.mainUnderrun(5.0, 5.5, 20.0, false, true))
        assertEquals(StemRules.MainUnderrun.Hold, StemRules.mainUnderrun(5.49, 5.5, 20.0, false, true))
        assertEquals(StemRules.MainUnderrun.EndSong, StemRules.mainUnderrun(5.49, 5.5, 20.0, false, false))
        assertEquals(7.0, StemRules.deadSourceEnd(5.0, true, 7.0), 0.0)
        assertEquals(5.0, StemRules.deadSourceEnd(5.0, false, 7.0), 0.0)
    }

    @Test fun shiftedSourceMapsStemFramesIntoTheMainDomain() {
        val inner = SyntheticPcmSource.counter(1_000)
        val s = ShiftedSource(inner, 400)
        assertEquals(1_400L, s.totalFrames)
        s.seek(400)
        assertEquals(0L, inner.position)
        s.seek(450)
        assertEquals(50L, inner.position)
        val buf = FloatArray(8)
        assertEquals(4, s.read(buf, 4))
        assertEquals(50L, SyntheticPcmSource.frameOf(buf[0]))
    }

    // ---------------------------------------------------------------- stems on disk

    @Test fun stemsOnDiskPausedDeckSwitchesOutright() {
        val r = StemRig(); r.load(); r.burn()
        r.stems.setStemMode(true, A)
        assertTrue(r.engine.deckState(A).stemMode)
        assertTrue(r.stems.active(A))
        assertNull(r.stems.handover(A))
        assertTrue(r.engine.graph.isOnStems(A))
        assertNotNull(r.engine.controller(A).stems)
        assertEquals(listOf(true), r.h.recorder.of(MixEventKind.StemMode).map { it.flag })
    }

    @Test fun playingDeckCrossesOverWithZeroDeadAir() {
        val r = StemRig(); r.load(); r.burn()
        r.engine.play(A)
        val before = r.run(1.0)
        r.stems.setStemMode(true, A)
        assertTrue("an audible deck crosses over, it does not cut", r.stems.fadeInFlight(A))
        val out = r.run(1.5)
        assertTrue(r.engine.deckState(A).stemMode)
        assertFalse(r.stems.fadeInFlight(A))
        val h = r.engine.graph.deck(A).handover
        assertTrue(h.landedToStems)
        assertEquals(1f, h.stemGain, 0f)
        assertFalse("the full mix is paused once the stems carry", r.engine.controller(A).voice!!.isPlaying)
        assertTrue(longestSilence(out, 0, out.size / 2) < 300)
        val n = out.size / 2
        assertEquals(TONE_RMS, rms(out, n - 22_050, n, 0), TONE_RMS * 0.1)
        assertEquals(TONE_RMS, rms(before, before.size / 2 - 22_050, before.size / 2, 0), TONE_RMS * 0.1)
    }

    @Test fun rapidTogglesLandOnTheLastIntentWithoutDeadAir() {
        val r = StemRig(); r.load(); r.burn()
        r.engine.play(A)
        r.run(1.0)
        val chunks = ArrayList<FloatArray>()
        for (on in listOf(true, false, true, false, true)) {
            r.stems.setStemMode(on, A)
            chunks += r.h.render(3000)   // < fade lead: the next toggle supersedes the one in flight
            r.h.tick(100)
        }
        chunks += r.run(2.0)
        val all = chunks.fold(FloatArray(0)) { a, b -> a + b }
        assertTrue("last intent was ON", r.engine.deckState(A).stemMode)
        assertNull(r.stems.handover(A))
        assertTrue(r.engine.graph.isOnStems(A))
        assertTrue("no gap longer than a zero crossing: ${longestSilence(all, 0, all.size / 2)}", longestSilence(all, 0, all.size / 2) < 300)
        val tail = r.h.render(22_050)
        assertEquals(TONE_RMS, rms(tail, 0, 22_050, 0), TONE_RMS * 0.1)
    }

    @Test fun fourStemsMatchTheFullMixOnTheSyntheticFixture() {
        val full = StemRig(); full.load(); full.engine.play(A)
        val a = full.run(1.5)
        val stemmed = StemRig(); stemmed.load(); stemmed.burn(); stemmed.stems.setStemMode(true, A); stemmed.engine.play(A)
        val b = stemmed.run(1.5)
        // the stems start on a 60 ms scheduled frame: align both runs on their first audible frame
        val oa = com.levi.pocketdj.audio.core.OfflineRenderer.firstNonZeroFrame(a)
        val ob = com.levi.pocketdj.audio.core.OfflineRenderer.firstNonZeroFrame(b)
        assertTrue(oa >= 0 && ob >= 0)
        val from = 8_000; val to = 60_000
        var sa = 0.0; var sb = 0.0; var saa = 0.0; var sbb = 0.0; var sab = 0.0
        for (f in from until to) {
            val x = a[(f + oa) * 2].toDouble(); val y = b[(f + ob) * 2].toDouble()
            sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y
        }
        val n = (to - from).toDouble()
        val r = (sab - sa * sb / n) / sqrt((saa - sa * sa / n) * (sbb - sb * sb / n))
        assertTrue("r=$r", r > 0.999)
    }

    @Test fun stemMuteAndVolumeShapeTheMixAndAreRecorded() {
        val r = StemRig(); r.load(); r.burn()
        r.stems.setStemMode(true, A); r.engine.play(A)
        val full = r.run(1.0)
        for (n in listOf("vocals", "drums", "bass")) r.stems.toggleStemMute(n, A)
        val out = r.run(1.0)
        assertTrue(r.stems.isMuted("drums", A))
        // one stem of four left: a quarter of the amplitude
        assertEquals(TONE_RMS / 4, rms(out, 22_050, 44_100, 0), TONE_RMS * 0.05)
        r.stems.setStemVolume("other", 0.5, A)
        val half = r.run(1.0)
        assertEquals(TONE_RMS / 8, rms(half, 22_050, 44_100, 0), TONE_RMS * 0.04)
        r.stems.toggleStemMute("drums", A)
        assertFalse(r.stems.isMuted("drums", A))
        assertEquals(listOf("drums", "vocals", "bass", "drums").sorted(), r.h.recorder.of(MixEventKind.StemMute).mapNotNull { it.param }.sorted())
        assertEquals(0.5, r.h.recorder.of(MixEventKind.StemVolume).single().value!!, 0.0)
        assertTrue(rms(full, 22_050, 44_100, 0) > TONE_RMS * 0.9)
    }

    @Test fun stemsFollowAnAnalogWindowThroughTheShiftedSource() {
        val r = StemRig()
        val item = r.h.addSong("an", seconds = 10.0, isCut = false, startMs = 2_000).copy(lengthMs = 3_000)
        r.engine.load(item, A)
        var firstSeek = -1L
        var lastSeek = -1L
        r.fake.local["an"] = {
            StemParts(List(4) {
                val inner = SyntheticPcmSource.counter(r.h.sr * 10L)
                object : PcmSource by inner {
                    override fun seek(frame: Long) { if (firstSeek < 0) firstSeek = frame; lastSeek = frame; inner.seek(frame) }
                }
            }, complete = true)
        }
        r.stems.setStemMode(true, A)
        r.engine.ensureEngine()
        r.h.render(4_096)
        // the voice window starts at the song's offset into the side, but the stem file is read from ITS 0:00
        assertEquals(88_200L, r.engine.controller(A).startFrame)
        assertEquals(0L, firstSeek)
        r.engine.seek(A, 1.0)
        r.h.render(4_096)
        // 1.0 s into the song = stem frame 44_100 (song-relative), whatever the album offset
        assertEquals(44_100L, lastSeek)
    }

    // ---------------------------------------------------------------- stems NOT on disk

    @Test fun streamingStemsLoadWhilePlayingThenTakeOverWithRunway() {
        val r = StemRig(20.0); r.load(); val st = r.stream(secs = 20.0, availableSec = 3.0)
        r.engine.play(A)
        r.run(1.0)
        r.stems.setStemMode(true, A)
        // only 2 s of runway: the full mix stays on air and the UI shows Loading stems...
        assertEquals(StemHandover.TO_STEMS, r.stems.handover(A))
        assertEquals(StemHandover.TO_STEMS, r.stems.handovers.value[A])
        assertTrue(r.stems.modeOn(A)); assertFalse(r.stems.active(A))
        val during = r.run(0.5)
        assertFalse(r.engine.deckState(A).stemMode)
        assertTrue(longestSilence(during, 0, during.size / 2) < 300)
        st.growTo(9.0)
        r.stems.streamProgressed("s")
        val out = r.run(1.5)
        assertTrue(r.engine.deckState(A).stemMode)
        assertNull(r.stems.handover(A))
        assertTrue(r.stems.handovers.value.isEmpty())
        assertTrue("dead air ${longestSilence(out, 0, out.size / 2)}", longestSilence(out, 0, out.size / 2) < 300)
    }

    @Test fun partialStemsHandBackBeforeTheirFrontierAndReEngageWithRunway() {
        val r = StemRig(20.0); r.load(); val st = r.stream(secs = 20.0, availableSec = 8.0)
        r.engine.play(A)
        r.run(0.5)
        r.stems.setStemMode(true, A)
        val a = r.run(1.0)
        assertTrue("stems with 7 s of runway take over", r.engine.deckState(A).stemMode)
        // run toward the frontier: hand back to the full mix 1 s before it, intent stays pending
        val b = r.run(5.7)
        assertFalse(r.engine.deckState(A).stemMode)
        assertEquals(StemHandover.TO_STEMS, r.stems.handover(A))
        assertTrue(r.engine.position(A) < 8.0)
        assertTrue(longestSilence(b, 0, b.size / 2) < 300)
        // the stream catches up: re-engage with the 4 s runway
        st.growTo(20.0)
        r.stems.streamProgressed("s")
        val c = r.run(1.5)
        assertTrue(r.engine.deckState(A).stemMode)
        assertNull(r.stems.handover(A))
        assertTrue(longestSilence(c, 0, c.size / 2) < 300)
        assertTrue(longestSilence(a, 0, a.size / 2) < 300)
        assertNull("complete stream retires", r.stems.reach(A)!!.frontierSec)
    }

    @Test fun toggleOffBeforeLandingDropsTheRequestAndALateFetchTouchesNothing() {
        val r = StemRig(); r.load()
        val gate = CompletableDeferred<Boolean>(); r.fake.fetchGate = gate
        r.stems.setStemMode(true, A)
        assertEquals(1, r.fake.fetchCalls)
        assertTrue(r.stems.isFetching(A))
        r.stems.setStemMode(false, A)
        assertNull(r.stems.handover(A))
        assertFalse(r.stems.isFetching(A))
        r.burn()
        gate.complete(true)
        assertFalse(r.engine.deckState(A).stemMode)
        assertNull(r.engine.controller(A).stems)
    }

    @Test fun aFetchLandingWiresAndCutsWhenStillWanted() {
        val r = StemRig(); r.load()
        val gate = CompletableDeferred<Boolean>(); r.fake.fetchGate = gate
        r.stems.setStemMode(true, A)
        r.burn()
        gate.complete(true)
        assertTrue(r.engine.deckState(A).stemMode)
        assertNull(r.stems.handover(A))
    }

    @Test fun aFailedFetchDropsTheIntentAndTheFullMixStays() {
        val r = StemRig(); r.load()
        val gate = CompletableDeferred<Boolean>(); r.fake.fetchGate = gate
        r.stems.setStemMode(true, A)
        gate.complete(false)
        assertNull(r.stems.handover(A))
        assertFalse(r.engine.deckState(A).stemMode)
        assertTrue(r.stems.handovers.value.isEmpty())
    }

    @Test fun aNewTrackBumpsTheIntentGenerationSoALateFetchTouchesNothing() {
        val r = StemRig(); r.load("one")
        val gate = CompletableDeferred<Boolean>(); r.fake.fetchGate = gate
        r.stems.setStemMode(true, A)
        val gen = r.stems.intentGen(A)
        r.load("two")
        assertTrue(r.stems.intentGen(A) > gen)
        r.burn("one"); r.burn("two")
        gate.complete(true)
        assertEquals("two", r.engine.loaded(A)!!.songId)
        assertFalse(r.engine.deckState(A).stemMode)
        assertNull(r.stems.handover(A))
        assertNull(r.engine.controller(A).stems)
    }

    @Test fun ejectReleasesTheStemStreamAndWiring() {
        val r = StemRig(20.0); r.load(); val st = r.stream(secs = 20.0, availableSec = 2.0)
        r.stems.setStemMode(true, A)
        assertTrue(r.stems.isStreaming(A))
        r.engine.clearDeck(A)
        assertEquals(1, st.cancelled)
        assertFalse(r.stems.isStreaming(A))
        assertNull(r.engine.controller(A).stems)
        assertTrue(r.stems.handovers.value.isEmpty())
    }

    @Test fun aFailedStreamDropsAPendingRequestAndHandsOnAirStemsBack() {
        val r = StemRig(20.0); r.load(); val st = r.stream(secs = 20.0, availableSec = 2.0)
        r.stems.setStemMode(true, A)
        assertEquals(StemHandover.TO_STEMS, r.stems.handover(A))
        st.isFailed = true
        r.stems.streamProgressed("s")
        assertNull(r.stems.handover(A))
        assertFalse(r.engine.deckState(A).stemMode)
    }

    // ---------------------------------------------------------------- transactional / edge cases

    @Test fun stemsThatCannotCoverThePlayheadLeaveTheDeckOnItsFullMix() {
        val r = StemRig(); r.load(); r.burn("s", 2.0)   // stems are only 2 s of a 10 s song
        r.engine.play(A)
        r.run(3.0)
        r.stems.setStemMode(true, A)
        assertFalse(r.engine.deckState(A).stemMode)
        assertNull(r.stems.handover(A))
        assertNull("unwired", r.engine.controller(A).stems)
        val out = r.run(0.5)
        assertEquals(TONE_RMS, rms(out, 0, out.size / 2, 0), TONE_RMS * 0.1)
    }

    @Test fun togglingStemsAtTheEndOfAPausedTrackNeverLeavesTheDeckSilent() {
        val r = StemRig(); r.load(); r.burn("s", 9.9)   // shortest stem ends just inside the song
        r.engine.seek(A, 10.0)                           // an auto tick pins the playhead at duration
        r.stems.setStemMode(true, A)
        assertTrue("clamped inside the shortest stem, schedule succeeded", r.engine.deckState(A).stemMode)
        r.engine.play(A)
        val out = r.h.render(8_000)   // the 60 ms group-start lead, then the last 50 ms of stem audio
        assertTrue(com.levi.pocketdj.mix.graph.GraphHarness.peak(out) > 0.05f)
    }

    @Test fun truncatedMainUnderStemsStaysOnStems() {
        val r = StemRig(); r.load(); r.burn()
        r.stems.setStemMode(true, A); r.engine.play(A)
        r.run(2.0)
        r.stems.main = FakeMain(end = 3.0, complete = false, truncated = true)
        r.stems.setStemMode(false, A)
        r.run(0.5)
        // 3 s of full mix at a 2.5 s playhead is not enough runway for a still-arriving source
        assertTrue(r.engine.deckState(A).stemMode)
        assertEquals(StemHandover.TO_FULL_MIX, r.stems.handover(A))
        assertFalse("modeOn follows the intent", r.stems.modeOn(A))
    }

    @Test fun neitherVoiceAbleToGrowEndsTheSongAtTheLongerAudio() {
        val r = StemRig(20.0); r.load(); val st = r.stream(secs = 20.0, availableSec = 7.0)
        r.stems.main = FakeMain(end = 5.0, complete = false, truncated = true, canGrow = false)
        r.stems.setStemMode(true, A)
        assertTrue(r.engine.deckState(A).stemMode)
        st.isFailed = true
        r.stems.streamProgressed("s")
        assertEquals(7.0, r.engine.duration(A), 1e-6)
        assertFalse(r.stems.isHeld(A))
    }

    @Test fun pausingMidCrossfadeSettlesItAndNeverParksAHalfFadedDeck() {
        val r = StemRig(); r.load(); r.burn()
        r.engine.play(A); r.run(1.0)
        r.stems.setStemMode(true, A)
        assertTrue(r.stems.fadeInFlight(A))
        r.engine.pause(A)
        assertFalse(r.stems.fadeInFlight(A))
        r.h.render(2_000)
        // the incoming side was still inside its start lead: the fade is undone, the intent re-queued
        assertFalse(r.engine.deckState(A).stemMode)
        r.engine.play(A)
        val out = r.run(1.5)
        assertTrue(longestSilence(out, 0, out.size / 2) < 400)
        assertTrue(rms(out, out.size / 2 - 22_050, out.size / 2, 0) > TONE_RMS * 0.8)
    }

    @Test fun aRestoredDecksStemSourceWaitsForItsFirstPlay() {
        val r = StemRig(); r.load()
        val gate = CompletableDeferred<Boolean>(); r.fake.fetchGate = gate
        r.stems.applyStemIntent(true, A, deferSourceUntilPlay = true)
        assertEquals("a restore must not start transfers for a deck nobody is listening to", 0, r.fake.fetchCalls)
        assertEquals(StemHandover.TO_STEMS, r.stems.handover(A))
        r.engine.play(A)
        assertEquals(1, r.fake.fetchCalls)
    }

    @Test fun theDurableSnapshotSavesTheStemIntentNotTheCommittedFlag() {
        val r = StemRig(); r.load()
        val gate = CompletableDeferred<Boolean>(); r.fake.fetchGate = gate
        r.stems.applyStemIntent(true, A, deferSourceUntilPlay = true)
        assertFalse("committed flag is still off while loading", r.engine.deckState(A).stemMode)
        assertEquals(true, r.engine.mixDeckSnapshot()?.deckA?.stemMode)
        r.engine.setVolume(0.5, A)   // a persist during "Loading stems..." keeps the intent
        assertEquals(true, r.engine.mixDeckSnapshot()?.deckA?.stemMode)
    }

    @Test fun aStemHoldSurvivesMix10ReassigningTheStreamHoldProvider() {
        val r = StemRig(); r.load()
        r.engine.streamHeldProvider = { false }   // MIX-10 wiring AFTER MixDeckExtras was built
        assertFalse(r.engine.streamHeld(A))
        r.engine.stemHeldProvider = { true }
        assertTrue(r.engine.streamHeld(A))
    }

    @Test fun aHeldDeckSwitchesOutrightEvenWhileItsMainVoiceReportsPlaying() {
        val r = StemRig(); r.load(); r.burn()
        r.engine.play(A)
        r.run(0.5)
        r.engine.streamHeldProvider = { true }   // StemController decides "not audible"; the graph must agree
        r.stems.applyStemIntent(true, A, deferSourceUntilPlay = false)
        assertTrue(r.engine.deckState(A).stemMode)
        assertTrue("graph and controller agree on the stems", r.engine.graph.isOnStems(A))
        r.run(0.5)
        assertTrue(r.engine.graph.isOnStems(A))
    }
}

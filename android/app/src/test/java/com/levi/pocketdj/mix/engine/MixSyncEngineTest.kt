package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import com.levi.pocketdj.mix.store.ManualScheduler
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.TestClock
import com.levi.pocketdj.mix.store.tempFile
import com.levi.pocketdj.remote.MixTogetherBlock
import com.levi.pocketdj.remote.mix.MixSyncEvent
import com.levi.pocketdj.remote.mix.MixSyncKind
import kotlinx.serialization.encodeToString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** P2-REM-12: the Mix engine's multiplayer seams (gesture tap, remote guard, scheduled start, nudge, loop, board, session). */
class MixSyncEngineTest {
    private val A = Deck.A
    private val B = Deck.B

    @Before @After fun reset() { MixTogetherBlock.set(null); MixTogetherBlock.onChanged = null }

    private fun onset(out: FloatArray): Int {
        for (i in out.indices step 2) if (Math.abs(out[i]) > 1e-4f) return i / 2
        return -1
    }

    private fun ev(kind: String, deck: Deck = A, value: Double? = null, param: String? = null, flag: Boolean? = null, slot: Int? = null) =
        MixSyncEvent(kind = kind, deck = deck.label, value = value, param = param, flag = flag, slot = slot)

    // ---------------------------------------------------------------- pure math

    @Test fun scheduledLeadIsClampedBetweenTheStemLeadAndTwoSeconds() {
        assertEquals(MixSyncMath.MIN_LEAD, MixSyncMath.scheduledLead(-3.0), 0.0)
        assertEquals(MixSyncMath.MIN_LEAD, MixSyncMath.scheduledLead(0.0), 0.0)
        assertEquals(0.3, MixSyncMath.scheduledLead(0.3), 0.0)
        assertEquals(2.0, MixSyncMath.scheduledLead(10.0), 0.0)
    }

    @Test fun theStartFiresEarlyByTheOutputLatency() {
        assertEquals(0.28, MixSyncMath.desiredLead(1_300.0, 1_000.0, 0.02), 1e-9)
        assertEquals(-0.1, MixSyncMath.desiredLead(900.0, 1_000.0, 0.0), 1e-9)
    }

    @Test fun aPushedOutStartMovesTheCueForwardByTheGapTimesRate() {
        // asked 0.5 s ago: scheduled at the 0.06 s floor, so the cue sits (0.06 + 0.5) x rate ahead
        assertEquals(1.12, MixSyncMath.cueSeconds(0, 0.06, -0.5, 2.0, 100.0), 1e-9)
        assertEquals("an on-time start does not move the cue", 5.0, MixSyncMath.cueSeconds(5_000, 0.3, 0.3, 1.0, 100.0), 1e-9)
        assertEquals("clamped to the deck", 10.0, MixSyncMath.cueSeconds(9_900, 0.06, -5.0, 1.0, 10.0), 1e-9)
        assertEquals("a too-far instant waits the cap and the cue never goes negative", 0.0, MixSyncMath.cueSeconds(0, 2.0, 10.0, 1.0, 10.0), 1e-9)
        assertEquals(3.5, MixSyncMath.nowSeconds(4_000, 0.5, 1.0), 1e-9)
    }

    @Test fun foldIntoLoopWrapsForwardsAndBackwards() {
        assertEquals(1.5, MixSyncMath.foldIntoLoop(5.5, 1.0, 3.0), 1e-9)
        assertEquals(2.5, MixSyncMath.foldIntoLoop(0.5, 1.0, 3.0), 1e-9)
        assertEquals(1.0, MixSyncMath.foldIntoLoop(3.0, 1.0, 3.0), 1e-9)
        assertEquals("a degenerate window leaves the second alone", 7.0, MixSyncMath.foldIntoLoop(7.0, 2.0, 2.0), 0.0)
    }

    @Test fun nudgeIsBoundedToOnePercentAndNeutralClears() {
        assertEquals(1.01, MixSyncMath.clampNudge(1.5), 0.0)
        assertEquals(0.99, MixSyncMath.clampNudge(0.2), 0.0)
        assertEquals(1.004, MixSyncMath.clampNudge(1.004), 0.0)
        assertTrue(MixSyncMath.isNeutral(1.0))
        assertFalse(MixSyncMath.isNeutral(1.001))
    }

    @Test fun exactWindowIsBoundedToTheDeckAndRejectsDegenerates() {
        assertEquals(1.0 to 3.0, MixSyncMath.exactWindow(1_000, 3_000, 10.0))
        assertEquals(8.0 to 10.0, MixSyncMath.exactWindow(8_000, 12_000, 10.0))
        assertNull(MixSyncMath.exactWindow(3_000, 3_000, 10.0))
        assertNull(MixSyncMath.exactWindow(11_000, 12_000, 10.0))
    }

    // ---------------------------------------------------------------- board fold

    @Test fun anEmptyControlListIsTheFactoryBoard() {
        val b = SyncBoardFold.fold(emptyList())
        assertEquals(1.0, b.rate, 0.0); assertEquals(0.0, b.pitch, 0.0); assertEquals(1.0, b.volume, 0.0)
        assertEquals(0.0, b.eqLow, 0.0)
        assertTrue(b.slots.none { it.enabled })
        assertFalse(b.stemMode); assertTrue(b.stemMuted.isEmpty()); assertFalse(b.lead)
    }

    @Test fun theFoldAppliesEveryControlKindAndClampsToTheRanges() {
        val b = SyncBoardFold.fold(
            listOf(
                ev(MixSyncKind.TEMPO, value = 9.0), ev("pitch", value = -40.0), ev("volume", value = 5.0),
                ev("eq", param = "low", value = -30.0), ev("eq", param = "mid", value = 3.0), ev("eq", param = "high", value = 30.0),
                ev("effectSlot", param = "filter", slot = 0), ev("effectVariant", param = "highPass", slot = 0),
                ev("effectToggle", flag = true, slot = 0), ev("effectStrength", value = 0.9, slot = 0),
                ev("effectMod", param = "lfo:bar:triangle", value = -0.4, slot = 0),
                ev("stemMode", flag = true), ev("stemMute", param = "drums", flag = true), ev("stemMute", param = "bass", flag = true),
                ev("stemMute", param = "bass", flag = false), ev("stemVolume", param = "vocals", value = 3.0),
                ev(MixSyncKind.LEAD, flag = true),
            ),
        )
        assertEquals(2.0, b.rate, 0.0); assertEquals(-12.0, b.pitch, 0.0); assertEquals(2.0, b.volume, 0.0)
        assertEquals(-12.0, b.eqLow, 0.0); assertEquals(3.0, b.eqMid, 0.0); assertEquals(12.0, b.eqHigh, 0.0)
        val s = b.slots[0]
        assertEquals(Effect.FILTER, s.effect); assertEquals(EffectVariant.HIGH_PASS, s.variant)
        assertTrue(s.enabled); assertEquals(0.9, s.strength, 0.0)
        assertEquals(SlotMod.of(ModSource.LFO, ModRate.BAR, -0.4, ModShape.TRIANGLE), s.mod)
        assertTrue(b.stemMode); assertEquals(setOf("drums"), b.stemMuted); assertEquals(1.0, b.stemVol["vocals"]!!, 0.0)
        assertTrue(b.lead)
    }

    @Test fun anEffectEventWithoutASlotFindsTheFirstSlotOfThatFamily() {
        val b = SyncBoardFold.fold(listOf(ev("effectToggle", param = "reverb", flag = true), ev("effectStrength", param = "reverb", value = 0.2)))
        val i = b.slots.indexOfFirst { it.effect == Effect.REVERB }
        assertTrue(b.slots[i].enabled); assertEquals(0.2, b.slots[i].strength, 0.0)
        assertEquals(1, b.slots.count { it.enabled })
    }

    @Test fun aSyncKindSetsTheRateLikeTempoAndALaterEventWins() {
        val b = SyncBoardFold.fold(listOf(ev(MixSyncKind.TEMPO, value = 1.1), ev(MixSyncKind.SYNC, value = 1.25)))
        assertEquals(1.25, b.rate, 0.0)
    }

    @Test fun anEffectModKeepsTheLocalLfoPhaseAndMalformedParamsAreIgnored() {
        val cur = com.levi.pocketdj.mix.model.FxRack.defaultSlots().mapIndexed { i, s -> if (i == 1) s.setMod(SlotMod(phase = 0.25)) else s }
        val b = SyncBoardFold.fold(listOf(ev("effectMod", param = "lfo:bar:sine", value = 0.5, slot = 1), ev("effectMod", param = "junk", slot = 2)), cur)
        assertEquals(0.25, b.slots[1].mod.phase, 0.0)
        assertEquals(ModSource.OFF, b.slots[2].mod.source)
    }

    // ---------------------------------------------------------------- gesture tap + remote guard

    @Test fun everyLocalGestureIsTappedBesideTheSessionLogEvenWithNoRecorder() {
        val h = EngineHarness()
        h.engine.recorder = null
        val taps = mutableListOf<Gesture>()
        h.engine.gestureTap = { taps += it }
        h.engine.load(h.addSong("a"), A)
        h.engine.setVolume(1.3, A)
        h.engine.setCrossfader(0.2)
        h.engine.setEqGain(EQBand.MID, 4.0, A)
        val load = taps.first()
        assertEquals(Gesture.LOAD, load.kind); assertEquals(A, load.deck); assertEquals("a", load.track!!.songId)
        assertEquals(10_000, load.lengthMs); assertEquals(0, load.posMs)
        val vol = taps.first { it.kind == "volume" }
        assertEquals(1.3, vol.value!!, 0.0); assertEquals(A, vol.deck); assertEquals(Gesture.Cause.USER, vol.cause)
        val xf = taps.first { it.kind == "crossfader" }
        assertNull(xf.deck); assertEquals(0.2, xf.value!!, 0.0)
        val eq = taps.first { it.kind == "eq" }
        assertEquals("mid", eq.param); assertEquals(4.0, eq.value!!, 0.0)
    }

    @Test fun theTapKindsAreTheSessionLogKinds() {
        val h = EngineHarness()
        val taps = mutableListOf<Gesture>()
        h.engine.load(h.addSong("a"), A)
        h.engine.gestureTap = { taps += it }
        h.engine.play(A); h.engine.seek(A, 3.0); h.engine.pause(A)
        assertEquals(listOf(MixEventKind.Play.raw, MixEventKind.Seek.raw, MixEventKind.Pause.raw), taps.map { it.kind })
        assertEquals(3_000, taps[1].posMs)
        assertEquals("the log saw the same three", listOf("play", "seek", "pause"), h.recorder.kinds().takeLast(3))
    }

    @Test fun aRemoteApplyIsNeitherTappedNorSessionLogged() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        val taps = mutableListOf<Gesture>()
        h.engine.gestureTap = { taps += it }
        val logged = h.recorder.events.size
        h.engine.applyingRemote {
            assertTrue(h.engine.isApplyingRemote)
            h.engine.setVolume(0.4, A)
            h.engine.applyingRemote { h.engine.setRate(1.2, A) }
            assertTrue("a nested apply leaves the outer one guarded", h.engine.isApplyingRemote)
            h.engine.setPitch(1.0, A)
            h.engine.play(A)
        }
        assertFalse(h.engine.isApplyingRemote)
        assertTrue(taps.isEmpty())
        assertEquals("nothing reached the session log", logged, h.recorder.events.size)
        assertEquals("the state still moved", 0.4, h.engine.volume(A), 0.0)
        assertTrue(h.engine.isPlaying(A))
        assertEquals("a played song still counts as listened", listOf("a"), h.recorder.played)
        h.engine.setVolume(0.9, A)
        assertEquals("the guard is gone: a local gesture taps and logs again", 1, taps.size)
        assertEquals(logged + 1, h.recorder.events.size)
    }

    @Test fun aThrowingRemoteApplyStillReleasesTheGuard() {
        val h = EngineHarness()
        try { h.engine.applyingRemote { error("boom") } } catch (_: IllegalStateException) { }
        assertFalse(h.engine.isApplyingRemote)
    }

    @Test fun aLoadedDeckEjectsAsOneEjectGestureNotAPauseAndAReset() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        h.engine.play(A)
        val taps = mutableListOf<Gesture>()
        h.engine.gestureTap = { taps += it }
        h.engine.clearDeck(A)
        assertEquals(listOf(Gesture.EJECT), taps.map { it.kind })
        assertEquals(A, taps[0].deck)
        assertEquals("the session log still records the pause and the reset", listOf("pause", "resetDeck"), h.recorder.kinds().takeLast(2))
    }

    @Test fun theCauseIsStampedFromTheOutermostNonUserScope() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A); h.engine.load(h.addSong("b"), B)
        h.engine.play(A); h.engine.play(B)
        val taps = mutableListOf<Gesture>()
        h.engine.gestureTap = { taps += it }
        h.engine.caused(Gesture.Cause.SYSTEM) { h.engine.pause(A) }
        h.engine.caused(Gesture.Cause.SYSTEM) { h.engine.caused(Gesture.Cause.ENGINE) { h.engine.pause(B) } }
        assertEquals(Gesture.Cause.SYSTEM, taps[0].cause)
        assertEquals("the outer scope wins", Gesture.Cause.SYSTEM, taps[1].cause)
        h.engine.play(A)
        assertEquals("outside a scope it is the user's hand again", Gesture.Cause.USER, taps[2].cause)
    }

    @Test fun aRestoreOfTheDurableSessionTapsNothing() {
        val clock = TestClock(); val file = tempFile("decks.json")
        val store = MixDeckSessionStore(file, VersionedJsonWriter(file), clock::read, ManualScheduler(clock))
        val h1 = EngineHarness(store)
        h1.engine.load(h1.addSong("a"), A); h1.engine.setVolume(1.2, A); h1.engine.persist()
        store.flush()
        val h2 = EngineHarness(MixDeckSessionStore(file, VersionedJsonWriter(file), clock::read, ManualScheduler(clock)), songs = h1.songs, sources = h1.sources)
        val taps = mutableListOf<Gesture>()
        h2.engine.gestureTap = { taps += it }
        h2.engine.restorePersistedMixIfIdle()
        h2.engine.materializePendingRestoreIfNeeded()
        assertEquals("a", h2.engine.loaded(A)?.songId)
        assertTrue(taps.isEmpty())
    }

    // ---------------------------------------------------------------- loops

    @Test fun engagingAndReleasingALoopTapsOneLoopGestureEachWithTheExactWindow() {
        val r = StemRig()
        r.load()
        val taps = mutableListOf<Gesture>()
        r.engine.gestureTap = { taps += it }
        r.loops.setLoop(A, true)
        assertEquals(listOf(Gesture.LOOP), taps.map { it.kind })
        assertEquals(true, taps[0].flag); assertEquals(0, taps[0].loopStartMs); assertEquals(2_000, taps[0].loopEndMs)
        assertEquals(2.0, taps[0].value!!, 0.0)
        taps.clear()
        r.loops.setLoopUnits(A, 4.0)
        assertEquals(listOf(Gesture.LOOP_UNITS), taps.map { it.kind })
        assertEquals(4.0, taps[0].value!!, 0.0); assertEquals(4_000, taps[0].loopEndMs)
        taps.clear()
        r.loops.setLoop(A, false)
        assertEquals("the release's internal re-seek is not a second gesture", listOf(Gesture.LOOP), taps.map { it.kind })
        assertEquals(false, taps[0].flag); assertNull(taps[0].loopStartMs)
    }

    @Test fun syncSetLoopLoopsExactlyTheOwnersWindowWithoutATap() {
        val r = StemRig()
        r.load()
        val taps = mutableListOf<Gesture>()
        r.engine.gestureTap = { taps += it }
        r.engine.syncSetLoop(A, true, 4.0, 1_000, 3_000)
        assertTrue(r.engine.deckState(A).loopOn)
        assertEquals(1_000 to 3_000, r.engine.loopWindowMs(A))
        assertEquals(4.0, r.engine.deckState(A).loopUnits, 0.0)
        // idempotent for the same window; a moved window re-places it
        r.engine.syncSetLoop(A, true, 4.0, 1_000, 3_000)
        assertEquals(1_000 to 3_000, r.engine.loopWindowMs(A))
        r.engine.syncSetLoop(A, true, 2.0, 5_000, 6_500)
        assertEquals(5_000 to 6_500, r.engine.loopWindowMs(A))
        r.engine.syncSetLoop(A, false, null, null, null)
        assertFalse(r.engine.deckState(A).loopOn); assertNull(r.engine.loopWindowMs(A))
        assertTrue("remote apply: no tap", taps.isEmpty())
    }

    @Test fun anOlderSenderWithNoWindowDerivesItLocallyAndAWindowPastTheDeckIsBounded() {
        val r = StemRig(seconds = 10.0)
        r.load()
        r.engine.syncSetLoop(A, true, 2.0, null, null)
        assertTrue(r.engine.deckState(A).loopOn)
        r.engine.syncSetLoop(A, false, null, null, null)
        r.engine.syncSetLoop(A, true, 2.0, 9_000, 14_000)
        assertEquals(9_000 to 10_000, r.engine.loopWindowMs(A))
        r.engine.syncSetLoop(A, false, null, null, null)
        r.engine.syncSetLoop(A, true, 2.0, 12_000, 14_000)
        assertFalse("a window wholly past the deck is refused", r.engine.deckState(A).loopOn)
    }

    // ---------------------------------------------------------------- rate nudge

    @Test fun theNudgeMultipliesTheUsersTempoIsBoundedAndClearsExactly() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 100.0), A)
        h.engine.setRate(1.2, A)
        h.engine.syncNudgeRate(A, 1.5)
        assertEquals(1.01, h.engine.rateNudgeForTesting(A)!!, 0.0)
        assertEquals(1.2 * 1.01, h.engine.effectiveRate(A), 1e-12)
        assertEquals("the user's tempo is untouched", 1.2, h.engine.rate(A), 0.0)
        h.engine.syncNudgeRate(A, 0.5)
        assertEquals(0.99, h.engine.rateNudgeForTesting(A)!!, 0.0)
        h.engine.syncNudgeRate(A, 1.0)
        assertNull(h.engine.rateNudgeForTesting(A))
        assertEquals(1.2, h.engine.effectiveRate(A), 0.0)
        h.engine.syncNudgeRate(A, 1.004)
        h.engine.load(h.addSong("b", 100.0), A)
        assertNull("a fresh track starts at the user's tempo", h.engine.rateNudgeForTesting(A))
    }

    @Test fun theTickAdvancesThePlayheadAtTheNudgedRate() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 100.0), A)
        h.engine.play(A)
        h.engine.syncNudgeRate(A, 1.01)
        for (i in 0 until 10) h.tick(100)
        assertEquals(1.01, h.engine.position(A), 1e-9)
    }

    // ---------------------------------------------------------------- scheduled start

    @Test fun aScheduledStartSoundsAtTheAskedInstantInOfflineRender() {
        val imm = EngineHarness()
        imm.engine.load(imm.addSong("a", 30.0), A)
        imm.engine.play(A)
        val base = onset(imm.render(8_192))
        assertTrue(base >= 0)

        for (leadMs in listOf(300L, 750L)) {
            val h = EngineHarness()
            h.engine.load(h.addSong("a", 30.0), A)
            h.engine.syncPlay(A, 0, h.nowMs + leadMs.toDouble())
            assertTrue(h.engine.isPlaying(A))
            val out = h.render(h.seconds(1.5))
            val got = onset(out)
            val want = base + (leadMs * 44.1).toInt()
            assertTrue("lead $leadMs ms: onset $got vs $want", Math.abs(got - want) <= 1_024)
        }
    }

    @Test fun aScheduledStartFiresEarlyByTheOutputLatency() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 30.0), A)
        h.engine.outputLatencyProvider = { 0.1 }
        h.engine.syncPlay(A, 0, h.nowMs + 400.0)
        val got = onset(h.render(h.seconds(1.0)))
        val imm = EngineHarness().also { it.engine.load(it.addSong("a", 30.0), A); it.engine.play(A) }
        val base = onset(imm.render(8_192))
        assertTrue("onset $got should be ~0.3 s after $base", Math.abs(got - (base + 13_230)) <= 1_024)
    }

    @Test fun anInstantAlreadyPastStartsAtTheFloorWithTheCueMovedForward() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 30.0), A)
        h.engine.syncPlay(A, 2_000, h.nowMs - 500.0)
        assertTrue(h.engine.isPlaying(A))
        // the deck must sound where it would have been: 2.0 s + the 0.5 s gap + the 0.06 s floor, read back off by the lead
        assertEquals(2.5, h.engine.position(A), 1e-9)
    }

    @Test fun anInstantFarInTheFutureWaitsAtMostTwoSeconds() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 30.0), A)
        h.engine.syncPlay(A, 0, h.nowMs + 60_000.0)
        val out = h.render(h.seconds(3.0))
        val got = onset(out)
        assertTrue("onset $got ~2 s", got in (h.seconds(1.9)..h.seconds(2.2)))
    }

    @Test fun aScheduledStartDoesNotRecordOrTapButStillCountsTheListen() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 30.0), A)
        val taps = mutableListOf<Gesture>()
        h.engine.gestureTap = { taps += it }
        val logged = h.recorder.events.size
        h.engine.syncPlay(A, 1_000, h.nowMs + 300.0)
        assertTrue(taps.isEmpty())
        assertEquals(logged, h.recorder.events.size)
        assertEquals(listOf("a"), h.recorder.played)
    }

    @Test fun aStreamHeldDeckStartsNowFromWhereItMustBeAndKeepsOnlyIntent() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 30.0), A)
        h.engine.streamHeldProvider = { true }
        h.engine.syncPlay(A, 5_000, h.nowMs + 400.0)
        assertTrue(h.engine.isPlaying(A))
        assertEquals("sounds where it must be right now: 5.0 - 0.4", 4.6, h.engine.position(A), 1e-9)
    }

    @Test fun anUnloadedDeckIgnoresASyncPlay() {
        val h = EngineHarness()
        h.engine.syncPlay(A, 0, h.nowMs + 300.0)
        assertFalse(h.engine.isPlaying(A))
    }

    @Test fun aLoopingDeckFoldsTheCueIntoItsExistingWindow() {
        val r = StemRig(seconds = 30.0)
        r.load()
        r.engine.syncSetLoop(A, true, 2.0, 1_000, 3_000)
        r.engine.syncPlay(A, 5_000, r.h.nowMs + 300.0)
        assertTrue(r.engine.isPlaying(A))
        assertEquals("the window is kept exactly", 1_000 to 3_000, r.engine.loopWindowMs(A))
        // 5.0 s folded into [1,3) = 1.0 s; the accumulator reads it 0.3 s after now
        assertEquals(0.7, r.engine.position(A), 1e-9)
        val out = r.h.render(r.h.seconds(3.0))
        assertTrue(onset(out) > 0)
        assertTrue("still looping, still in the window", r.engine.position(A) in 0.0..3.0)
    }

    // ---------------------------------------------------------------- audible playhead

    @Test fun theAudiblePlayheadIsBackedOffByTheOutputLatencyTimesRate() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 60.0), A)
        h.engine.play(A)
        h.render(h.seconds(1.0))
        val t = h.engine.truePlayhead(A)
        assertNotNull(t)
        assertEquals(t!!, h.engine.audiblePlayhead(A), 1e-9)
        h.engine.outputLatencyProvider = { 0.1 }
        assertEquals(t - 0.1, h.engine.audiblePlayhead(A), 1e-9)
        h.engine.pause(A)
        assertEquals("a paused deck reports its cue, not a latency-shifted one", h.engine.position(A), h.engine.audiblePlayhead(A), 1e-9)
    }

    // ---------------------------------------------------------------- whole board

    @Test fun syncSetControlsDrivesTheBoardToExactlyTheSessionsAndResetsTheRest() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        h.engine.setVolume(1.5, A); h.engine.setEqGain(EQBand.LOW, -3.0, A); h.engine.setPitch(2.0, A)
        h.engine.setSlot(0, true, A)
        h.engine.setCued(true, A)
        val taps = mutableListOf<Gesture>()
        h.engine.gestureTap = { taps += it }
        val logged = h.recorder.events.size
        h.engine.syncSetControls(A, listOf(ev(MixSyncKind.TEMPO, value = 1.1), ev("eq", param = "mid", value = 2.0), ev("effectToggle", flag = true, slot = 2)))
        val s = h.engine.deckState(A)
        assertEquals(1.1, s.rate, 0.0); assertEquals(2.0, s.eqMid, 0.0)
        assertEquals("unlisted controls went back to default", 1.0, s.volume, 0.0)
        assertEquals(0.0, s.eqLow, 0.0); assertEquals(0.0, s.pitch, 0.0)
        assertFalse(s.slots[0].enabled); assertTrue(s.slots[2].enabled)
        assertTrue("cue / PFL stays this device's", s.cued)
        assertTrue(taps.isEmpty())
        assertEquals(logged, h.recorder.events.size)
    }

    @Test fun anInSyncBoardIsNotTouchedAgain() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        var slotsChanged = 0
        h.engine.onSlotsChanged = { _, _ -> slotsChanged++ }
        val board = listOf(ev(MixSyncKind.TEMPO, value = 1.1), ev("effectToggle", flag = true, slot = 1))
        h.engine.syncSetControls(A, board)
        assertEquals(1, slotsChanged)
        h.engine.syncSetControls(A, board)
        assertEquals("an in-sync deck hears nothing", 1, slotsChanged)
    }

    @Test fun theLeadRoleFollowsTheBoard() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        h.engine.syncSetControls(A, listOf(ev(MixSyncKind.LEAD, flag = true)))
        assertTrue(h.engine.isLead(A))
        h.engine.syncSetControls(A, emptyList())
        assertFalse(h.engine.isLead(A))
    }

    @Test fun aSeededBoardReproducesTheDeckOnAnotherDevice() {
        val h1 = EngineHarness()
        h1.engine.load(h1.addSong("a", 40.0, gridBpm = 124.0), A)
        h1.engine.setRate(1.15, A); h1.engine.setPitch(-2.0, A); h1.engine.setVolume(1.4, A)
        h1.engine.setEqGain(EQBand.LOW, -3.0, A); h1.engine.setEqGain(EQBand.HIGH, 4.5, A)
        h1.engine.setSlotEffect(Effect.FILTER, 0, A); h1.engine.setSlotVariant(EffectVariant.HIGH_PASS, 0, A)
        h1.engine.setSlot(0, true, A); h1.engine.setSlotStrength(0, 0.8, A)
        h1.engine.setSlotMod(SlotMod.of(ModSource.LFO, ModRate.BAR, -0.4, ModShape.TRIANGLE), 0, A)
        h1.engine.setSlot(3, true, A)
        h1.engine.setLead(A)
        val seed = h1.engine.syncSeedEvents(A)
        assertEquals(MixSyncKind.LOAD, seed.first().kind)
        assertEquals("a", seed.first().songId); assertEquals(A.label, seed.first().deck)
        assertTrue(seed.any { it.kind == "effectMod" && it.param == "lfo:bar:triangle" && it.slot == 0 })

        val h2 = EngineHarness()
        h2.engine.load(h2.addSong("a", 40.0, gridBpm = 124.0), A)
        h2.engine.syncSetControls(A, seed.filter { it.kind != MixSyncKind.LOAD })
        val a = h1.engine.deckState(A); val b = h2.engine.deckState(A)
        assertEquals(a.rate, b.rate, 0.0); assertEquals(a.pitch, b.pitch, 0.0); assertEquals(a.volume, b.volume, 0.0)
        assertEquals(a.eqLow, b.eqLow, 0.0); assertEquals(a.eqHigh, b.eqHigh, 0.0)
        assertEquals(a.slots, b.slots)
        assertTrue(h2.engine.isLead(A))
    }

    @Test fun anEmptyDeckSeedsNothing() {
        assertTrue(EngineHarness().engine.syncSeedEvents(A).isEmpty())
    }

    @Test fun seedEventsRoundTripThroughTheWireJsonAndIosShapedJsonWithoutTheNewFieldsDecodes() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        h.engine.setSlot(1, true, A)
        val seed = h.engine.syncSeedEvents(A)
        val json = PdjJson.lenient.encodeToString(seed)
        val back = PdjJson.lenient.decodeFromString<List<MixSyncEvent>>(json)
        assertEquals(seed, back)
        val old = PdjJson.lenient.decodeFromString<MixSyncEvent>("""{"kind":"loop","deck":"A","value":2,"flag":true}""")
        assertNull(old.loopStartMs); assertNull(old.loopEndMs)
        assertEquals(MixSyncKind.LOOP, old.kind)
    }

    @Test fun aSeededLoopCarriesItsExactWindow() {
        val r = StemRig()
        r.load()
        r.loops.setLoop(A, true)
        val loop = r.engine.syncSeedEvents(A).single { it.kind == MixSyncKind.LOOP }
        assertEquals(true, loop.flag); assertEquals(0, loop.loopStartMs); assertEquals(2_000, loop.loopEndMs)
        assertEquals(2.0, loop.value!!, 0.0)
    }

    @Test fun deckReadyNeedsTheSongLoadedAndNotWaitingOnBytes() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        assertTrue(h.engine.deckReady(A, "a"))
        assertFalse(h.engine.deckReady(A, "other"))
        assertFalse(h.engine.deckReady(B, "a"))
        h.engine.streamHeldProvider = { true }
        assertFalse(h.engine.deckReady(A, "a"))
    }

    // ---------------------------------------------------------------- Auto-DJ block + controller silence

    @Test fun theAutoBlockEndsAutoAndTheUsersAutoSettingComesBackWhenItLifts() {
        val r = AutoRig()
        MixTogetherBlock.onChanged = { r.dj.onAutoBlocked() }
        r.dj.setAutoEnabled(true)
        assertTrue(r.dj.enabled)
        r.e.setAutoDjBlocked(MixTogetherBlock.REASON)
        assertFalse(r.dj.enabled)
        assertEquals(MixTogetherBlock.REASON, r.dj.blockedReason)
        r.dj.setAutoEnabled(true)
        assertFalse("refused while blocked", r.dj.enabled)
        r.e.setAutoDjBlocked(null)
        assertTrue("restored exactly as the user had it", r.dj.enabled)
        assertNull(r.dj.blockedReason)
    }

    @Test fun anAutoSettingThatWasOffStaysOffAfterTheBlockLifts() {
        val r = AutoRig()
        MixTogetherBlock.onChanged = { r.dj.onAutoBlocked() }
        r.e.setAutoDjBlocked(MixTogetherBlock.REASON)
        r.e.setAutoDjBlocked(null)
        assertFalse(r.dj.enabled)
    }

    @Test fun aRunningAutoMixEndedByTheBlockIsNotRestartedAndTheDecksKeepPlaying() {
        val r = AutoRig()
        MixTogetherBlock.onChanged = { r.dj.onAutoBlocked() }
        r.start()
        assertTrue(r.dj.isMixing)
        r.e.setAutoDjBlocked(MixTogetherBlock.REASON)
        assertFalse(r.dj.isMixing)
        assertTrue(r.e.isPlaying(A))
        r.e.setAutoDjBlocked(null)
        assertFalse("not restarted", r.dj.isMixing)
    }

    @Test fun silencingForAControllerStopsTheSoundingDecksAsASystemCause() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A); h.engine.load(h.addSong("b"), B)
        h.engine.play(A)
        val taps = mutableListOf<Gesture>()
        h.engine.gestureTap = { taps += it }
        h.engine.silenceForRemoteController()
        assertFalse(h.engine.isPlaying(A)); assertFalse(h.engine.isPlaying(B))
        assertEquals(listOf("pause"), taps.map { it.kind })
        assertEquals(Gesture.Cause.SYSTEM, taps[0].cause)
        taps.clear()
        h.engine.silenceForRemoteController()
        assertTrue("idempotent: nothing left to stop", taps.isEmpty())
    }

    @Test fun silencingForAControllerSuspendsARunningAutoMixInsteadOfEndingIt() {
        val r = AutoRig()
        r.start()
        assertTrue(r.dj.isMixing)
        r.e.silenceForRemoteController()
        assertTrue("the user's mix resumes after the session", r.dj.isMixing)
        assertTrue(r.dj.isPaused)
        assertFalse(r.e.isPlaying(A))
    }

    // ---------------------------------------------------------------- durable session ownership

    private class SessionRig {
        val clock = TestClock()
        val sched = ManualScheduler(clock)
        val file = tempFile("decks.json")
        val store = MixDeckSessionStore(file, VersionedJsonWriter(file), clock::read, sched)
        val h = EngineHarness(store)
        fun savedA(): String? { store.awaitWrites(); return store.load()?.deckA?.track?.songId }
        init {
            h.engine.load(h.addSong("own"), Deck.A)
            h.engine.setVolume(1.3, Deck.A)
            h.engine.persist(); store.flush(); store.awaitWrites()
        }
    }

    @Test fun whileASessionIsActiveNothingOverwritesTheUsersSavedMix() {
        val r = SessionRig()
        assertEquals("own", r.savedA())
        r.h.engine.syncSessionActive(true)
        assertTrue(r.store.isSuspended); assertTrue(r.h.engine.multiplayerSessionActive)
        r.h.engine.applyingRemote {
            r.h.engine.clearDeck(A)
            r.h.engine.load(r.h.addSong("theirs"), A)
            r.h.engine.load(r.h.addSong("theirs2"), B)
        }
        r.h.engine.setVolume(0.5, A)
        r.h.engine.play(A)
        r.h.tick(6_000)
        assertEquals("the file is exactly what it was before the session", "own", r.savedA())
    }

    @Test fun whenTheSessionEndsWithNothingPlayingTheUsersOwnMixIsGivenBack() {
        val r = SessionRig()
        r.h.engine.syncSessionActive(true)
        r.h.engine.applyingRemote {
            r.h.engine.clearDeck(A)
            r.h.engine.load(r.h.addSong("theirs"), A)
        }
        r.h.engine.syncSessionActive(false)
        assertFalse(r.store.isSuspended)
        assertNull("the session's decks are cleared", r.h.engine.loaded(A))
        assertTrue("the user's mix is parked like a launch restore", r.h.engine.hasParkedRestore)
        r.h.engine.materializePendingRestoreIfNeeded()
        assertEquals("own", r.h.engine.loaded(A)?.songId)
        assertEquals(1.3, r.h.engine.volume(A), 0.0)
        assertEquals("own", r.savedA())
    }

    @Test fun aSessionEndedWhilePlayingKeepsTheDecksButProtectsTheSavedMixUntilTheUsersOwnLoad() {
        val r = SessionRig()
        r.h.engine.syncSessionActive(true)
        r.h.engine.applyingRemote {
            r.h.engine.clearDeck(A)
            r.h.engine.load(r.h.addSong("theirs"), A)
            r.h.engine.play(A)
        }
        r.h.engine.syncSessionActive(false)
        assertTrue("the music never dies with the session", r.h.engine.isPlaying(A))
        assertEquals("theirs", r.h.engine.loaded(A)?.songId)
        assertTrue(r.h.engine.postSessionPersistHold)
        assertTrue(r.store.isSuspended)
        r.h.engine.setVolume(0.6, A)
        assertEquals("still the user's own", "own", r.savedA())
        // the user's own load takes the decks: persistence is theirs again
        r.h.engine.load(r.h.addSong("mine2"), B)
        assertFalse(r.h.engine.postSessionPersistHold)
        assertFalse(r.store.isSuspended)
        r.h.engine.persist(); r.store.flush()
        assertEquals("theirs", r.savedA())
    }

    @Test fun emptyingTheDecksAfterAPlayingSessionBringsTheSavedMixBack() {
        val r = SessionRig()
        r.h.engine.syncSessionActive(true)
        r.h.engine.applyingRemote {
            r.h.engine.clearDeck(A)
            r.h.engine.load(r.h.addSong("theirs"), A)
            r.h.engine.play(A)
        }
        r.h.engine.syncSessionActive(false)
        r.h.engine.pause(A)
        r.h.engine.clearDeck(A)
        assertTrue(r.h.engine.hasParkedRestore)
        r.h.engine.materializePendingRestoreIfNeeded()
        assertEquals("own", r.h.engine.loaded(A)?.songId)
        assertEquals("own", r.savedA())
    }

    @Test fun aParkedLaunchRestoreIsRefusedWhileASessionOwnsTheDecks() {
        val r = SessionRig()
        val s2 = MixDeckSessionStore(r.file, VersionedJsonWriter(r.file), r.clock::read, r.sched)
        val h2 = EngineHarness(s2, songs = r.h.songs, sources = r.h.sources)
        h2.engine.syncSessionActive(true)
        h2.engine.restorePersistedMixIfIdle()
        assertFalse(h2.engine.hasParkedRestore)
        h2.engine.materializePendingRestoreIfNeeded()
        assertNull(h2.engine.loaded(A))
        h2.engine.syncSessionActive(false)
        // the Mix tab already asked while the session ran, so the user's mix (still on disk) lands on the decks at the end
        assertEquals("own", h2.engine.loaded(A)?.songId)
    }

    @Test fun theStoreIgnoresEveryWriteWhileSuspendedAndLandsAPendingDebounceFirst() {
        val clock = TestClock(); val file = tempFile("decks.json"); val sched = ManualScheduler(clock)
        val store = MixDeckSessionStore(file, VersionedJsonWriter(file), clock::read, sched)
        val h = EngineHarness(store)
        h.engine.load(h.addSong("a"), A)
        h.engine.setVolume(1.7, A)            // a debounced control write is pending
        store.suspendWrites(true)             // lands it before going quiet
        store.awaitWrites()
        assertEquals(1.7, store.load()!!.deckA!!.volume, 0.0)
        val snap = h.engine.mixDeckSnapshot()!!
        h.engine.setVolume(0.2, A)
        h.engine.clearDeck(A)
        store.clear(); store.save(snap.copy(crossfader = 0.9))
        store.awaitWrites()
        assertEquals("nothing moved the file", 1.7, store.load()!!.deckA!!.volume, 0.0)
        store.suspendWrites(false)
        assertFalse(store.isSuspended)
    }

    @Test fun theTapNeverFiresForASessionLogOnlyGestureWhenNobodyListens() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        h.engine.setVolume(0.8, A)   // gestureTap is null: must be a cheap no-op, the log still sees it
        assertEquals(MixEventKind.Volume.raw, h.recorder.kinds().last())
        assertEquals(1, h.recorder.of(MixEventKind.Volume).size)
    }
}

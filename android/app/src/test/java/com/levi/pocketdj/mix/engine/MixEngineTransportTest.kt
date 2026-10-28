package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.audio.core.Voice
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FilterMode
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.tempFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixEngineTransportTest {
    private val A = Deck.A
    private val B = Deck.B

    // ---------------------------------------------------------------- load window math

    @Test fun analogLoadSchedulesExactlyTheSongWindow() {
        val h = EngineHarness()
        var src: SyntheticPcmSource? = null
        val item = h.addSong("an", isCut = false, startMs = 2_000, source = {
            SyntheticPcmSource.counter(h.sr * 10L).also { src = it }
        }).copy(lengthMs = 3_000)
        h.engine.load(item, A)
        val c = h.engine.controller(A)
        assertEquals(88_200L, c.startFrame)
        assertEquals(88_200L + 132_300L, c.endFrame)
        assertEquals(3.0, h.engine.duration(A), 1e-9)
        assertEquals(2_000, h.engine.deckState(A).startMs)

        h.engine.play(A)
        h.render(h.seconds(3.6))
        // the decoder stopped exactly at the window end and the voice ended there: no bleed into the next song
        assertEquals(c.endFrame, src!!.position)
        assertEquals(Voice.Status.ENDED, c.voiceStatus)
        assertEquals(c.endFrame, c.voice!!.playerFrame)
    }

    @Test fun cutPlaysWholeFileFromZeroIgnoringStartAndLength() {
        val h = EngineHarness()
        val item = h.addSong("cut", seconds = 6.0, isCut = true, startMs = 2_000).copy(lengthMs = 1_000)
        h.engine.load(item, A)
        assertEquals(0L, h.engine.controller(A).startFrame)
        assertEquals(6.0, h.engine.duration(A), 1e-9)
        assertNull(h.engine.deckState(A).startMs)
    }

    @Test fun overLengthStartMsKeepsTheCurrentTrack() {
        val h = EngineHarness()
        h.engine.load(h.addSong("one", 5.0), A)
        val bad = h.addSong("two", seconds = 5.0, isCut = false, startMs = 999_000)
        h.engine.load(bad, A)
        assertEquals("one", h.engine.loaded(A)!!.songId)
        assertEquals(5.0, h.engine.duration(A), 1e-9)
        assertEquals(1, h.recorder.of(MixEventKind.Load).size)
    }

    @Test fun emptyFileKeepsTheCurrentTrackAndAnUnresolvableSongIsANoOp() {
        val h = EngineHarness()
        h.engine.load(h.addSong("one", 5.0), A)
        h.engine.load(h.addSong("empty", source = { SyntheticPcmSource.counter(0) }), A)
        assertEquals("one", h.engine.loaded(A)!!.songId)
        h.engine.load(com.levi.pocketdj.mix.model.MixLoadable("ghost", "x", "y"), A)
        assertEquals("one", h.engine.loaded(A)!!.songId)
    }

    @Test fun streamHookRunsOnlyForSongsNotOnDisk() {
        val h = EngineHarness()
        val seen = mutableListOf<String>()
        h.engine.streamLoad = { item, _ -> seen += item.songId; true }
        h.engine.load(h.addSong("here", 5.0), A)
        h.engine.load(com.levi.pocketdj.mix.model.MixLoadable("remote", "x", "y"), B)
        assertEquals(listOf("remote"), seen)
        assertNull(h.engine.loaded(B))
    }

    @Test fun loadResetsRatePitchLeadStemsLoopAndRecordsOneLoad() {
        val h = EngineHarness()
        val a = h.addSong("a", 10.0, gridBpm = 120.0)
        h.engine.load(a, A)
        h.engine.setRate(1.3, A); h.engine.setPitch(4.0, A); h.engine.setLead(A)
        h.engine.updateDeck(A) { it.copy(stemMode = true, stemMuted = setOf("drums"), stemVol = mapOf("bass" to 0.2), loopOn = true) }
        h.recorder.events.clear()
        var invalidated = 0
        h.engine.onLoopInvalidated = { invalidated++ }

        h.engine.load(h.addSong("b", 8.0), A)

        val s = h.engine.deckState(A)
        assertEquals("b", s.loaded!!.songId)
        assertEquals(1.0, s.rate, 0.0); assertEquals(0.0, s.pitch, 0.0)
        assertFalse(s.stemMode); assertTrue(s.stemMuted.isEmpty()); assertTrue(s.stemVol.isEmpty()); assertFalse(s.loopOn)
        assertNull(h.engine.leadDeck)
        assertEquals(1, invalidated)
        val loads = h.recorder.of(MixEventKind.Load)
        assertEquals(1, loads.size)
        assertEquals("8A", loads[0].camelot)
        assertEquals(listOf("load"), h.recorder.kinds())   // tempo/pitch reset is implied by .load
        assertEquals(1.0, h.engine.params.inputs(A).speed, 0.0)
    }

    // ---------------------------------------------------------------- transport funnel

    @Test fun loadThenPlayRecordsOnePlayAndMarksPlayedOnce() {
        val h = EngineHarness()
        val plays = mutableListOf<Pair<String, Deck>>()
        h.engine.onSongPlayed = { id, d -> plays += id to d }
        h.engine.load(h.addSong("a"), A)
        h.engine.play(A)
        assertEquals(1, h.recorder.of(MixEventKind.Play).size)
        assertEquals(listOf("a"), h.recorder.played)
        assertEquals(listOf("a" to A), plays)
        // idempotent re-issue: nothing new
        h.engine.play(A)
        assertEquals(1, h.recorder.of(MixEventKind.Play).size)
        assertEquals(1, h.recorder.played.size)
        // pause -> play is a second .play event but the SAME listen
        h.engine.pause(A); h.engine.play(A)
        assertEquals(2, h.recorder.of(MixEventKind.Play).size)
        assertEquals(1, h.recorder.of(MixEventKind.Pause).size)
        assertEquals(1, plays.size)
        // a new load is a new listen
        h.engine.load(h.addSong("b"), A); h.engine.play(A)
        assertEquals(2, plays.size)
    }

    @Test fun trackEndReportsOnceWithHighWaterAndReason() {
        val h = EngineHarness()
        val ended = mutableListOf<Triple<String, Double, MixTrackEndReason>>()
        h.engine.onDeckTrackEnded = { id, played, _, reason, _ -> ended += Triple(id, played, reason) }
        h.engine.load(h.addSong("a", 100.0), A)
        h.engine.reportTrackEnded(A, MixTrackEndReason.SKIP)
        assertTrue("never played -> no report", ended.isEmpty())
        h.engine.play(A)
        h.engine.setPosition(A, 60.0)
        h.engine.seek(A, 1.0)            // rewind before the load is replaced
        h.engine.load(h.addSong("b", 100.0), A)
        assertEquals(1, ended.size)
        assertEquals("a", ended[0].first)
        assertEquals(60.0, ended[0].second, 1e-9)   // high-water, not the live playhead
        assertEquals(MixTrackEndReason.REPLACED, ended[0].third)
        h.engine.reportTrackEnded(A, MixTrackEndReason.SKIP)
        assertEquals("first reason wins", 1, ended.size)
    }

    @Test fun masterTransportAndSticky() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A); h.engine.load(h.addSong("b"), B)
        h.engine.playBoth()
        assertTrue(h.engine.isRunning)
        assertTrue(h.engine.deckState(A).isPlaying && h.engine.deckState(B).isPlaying)
        h.engine.pauseBoth()
        assertFalse(h.engine.isRunning)
        h.engine.resumeMasterPaused()      // lock-screen play: both were playing
        assertTrue(h.engine.deckState(A).isPlaying && h.engine.deckState(B).isPlaying)
        h.engine.pause(A)
        h.engine.toggleAll()               // running -> pauseBoth
        assertFalse(h.engine.isRunning)
        h.engine.resumeMasterPaused()      // only B was playing when paused
        assertFalse(h.engine.deckState(A).isPlaying)
        assertTrue(h.engine.deckState(B).isPlaying)
    }

    @Test fun manualPauseEndsARunningAutoButNotAPausedOne() {
        val h = EngineHarness()
        val auto = FakeAutoDj().also { h.engine.autoDj = it; it.isMixing = true }
        h.engine.load(h.addSong("a"), A); h.engine.play(A)
        h.engine.pause(A)
        assertEquals(1, auto.ended)
        auto.isMixing = true; auto.isPaused = true
        h.engine.play(A); h.engine.pause(A)
        assertEquals(1, auto.ended)
    }

    @Test fun gestureGenerationBumpsOnLoadAndPlayAndDisarmsExhaustedPickup() {
        val h = EngineHarness()
        h.engine.autoEndedExhausted = true
        val g0 = h.engine.deckGestureGeneration
        h.engine.load(h.addSong("a"), A)
        assertFalse(h.engine.autoEndedExhausted)
        h.engine.play(A); h.engine.playBoth()
        assertEquals(g0 + 3, h.engine.deckGestureGeneration)
    }

    // ---------------------------------------------------------------- seek

    @Test fun seekClampsToTheWindowAndPastItEndsTheDeck() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 4.0), A)
        h.engine.seek(A, 999.0)
        assertEquals(4.0, h.engine.position(A), 0.0)
        h.engine.seek(A, -3.0)
        assertEquals(0.0, h.engine.position(A), 0.0)
        assertEquals(listOf(999.0 to 4.0, -3.0 to 0.0).map { it.second }, h.recorder.of(MixEventKind.Seek).map { it.value })
        // seek past the window while playing: the voice ends, the tick retires the deck
        h.engine.play(A)
        h.engine.seek(A, 999.0)
        h.render(h.seconds(0.5))
        assertEquals(h.engine.controller(A).endFrame, h.engine.controller(A).voice!!.playerFrame)
        assertFalse(h.tick(100))
        assertFalse(h.engine.deckState(A).isPlaying)
    }

    @Test fun seekNotifiesAutoAndDoesNotChangeTransport() {
        val h = EngineHarness()
        val auto = FakeAutoDj().also { h.engine.autoDj = it }
        h.engine.load(h.addSong("a", 30.0), A)
        h.engine.seek(A, 12.5)
        assertEquals(listOf(A), auto.seeks)
        assertFalse(h.engine.deckState(A).isPlaying)
        assertEquals(12.5, h.engine.position(A), 0.0)
    }

    @Test fun truePlayheadReadsTheVoiceClockAndHonorsSeekOffset() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 120.0), A)
        assertNull("not rendering yet", h.engine.truePlayhead(A))
        h.engine.play(A)
        h.render(h.seconds(1.0))
        val t0 = h.engine.truePlayhead(A)!!
        assertTrue("played ~1 s (was $t0)", t0 in 0.9..1.1)
        h.engine.seek(A, 30.0)
        h.render(h.seconds(1.0))
        val t1 = h.engine.truePlayhead(A)!!
        assertTrue("seek offset honored (was $t1)", t1 in 30.9..31.1)
        h.engine.pause(A)
        assertNull(h.engine.truePlayhead(A))
    }

    // ---------------------------------------------------------------- reset / clear

    @Test fun resetDeckKeepsTrackAndRackLayoutZeroesParamsAndRewinds() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 30.0), A)
        h.engine.setRate(1.4, A); h.engine.setPitch(3.0, A); h.engine.setVolume(1.6, A)
        h.engine.setEqGain(EQBand.HIGH, 6.0, A)
        h.engine.setSlotEffect(Effect.FILTER, 0, A)
        h.engine.setSlot(0, true, A); h.engine.setSlotStrength(0, 0.9, A)
        h.engine.setCued(true, A); h.engine.setCueVolume(0.4, A); h.engine.setLead(A)
        h.engine.seek(A, 12.0)
        h.recorder.events.clear()

        h.engine.resetDeck(A)

        val s = h.engine.deckState(A)
        assertEquals("a", s.loaded!!.songId)
        assertEquals(1.0, s.rate, 0.0); assertEquals(0.0, s.pitch, 0.0); assertEquals(1.0, s.volume, 0.0)
        assertEquals(0.0, s.eqHigh, 0.0)
        assertEquals(Effect.FILTER, s.slots[0].effect)        // layout kept
        assertTrue(s.slots.none { it.enabled }); assertTrue(s.slots.all { it.strength == 0.5 })
        assertTrue("cue survives a reset", s.cued); assertEquals(0.4, s.cueVol, 0.0)
        assertEquals(A, h.engine.leadDeck)
        assertEquals(0.0, h.engine.position(A), 0.0)
        assertEquals(0f, h.engine.params.current.a.trimDb, 0f)
        assertEquals(1.0f, h.engine.params.current.a.speed, 0f)
        assertEquals(listOf("resetDeck"), h.recorder.kinds())
    }

    @Test fun clearDeckEjectsDropsLeadAndCueAndPersists() {
        val store = com.levi.pocketdj.mix.store.MixDeckSessionStore(tempFile("decks.json"))
        val h = EngineHarness(store)
        h.engine.load(h.addSong("a", 30.0), A); h.engine.load(h.addSong("b", 30.0), B)
        h.engine.setLead(A); h.engine.setCued(true, A); h.engine.setVolume(1.5, A)
        h.engine.play(A)
        h.recorder.events.clear()

        h.engine.clearDeck(A)

        assertNull(h.engine.loaded(A))
        assertEquals(DeckState(), h.engine.deckState(A))
        assertNull(h.engine.leadDeck)
        assertFalse(h.engine.anyCued)
        assertFalse(h.engine.controller(A).isOpen)
        assertEquals(0.0, h.engine.params.current.house.housePan.toDouble(), 0.0)
        assertEquals(listOf("pause", "resetDeck"), h.recorder.kinds())   // the transport stop is part of an eject
        assertEquals(1, h.recorder.of(MixEventKind.ResetDeck).size)
        val saved = store.load()!!
        assertNull(saved.deckA); assertNotNull(saved.deckB)
        h.engine.clearDeck(B)
        assertNull("both empty -> the session file is cleared", store.load())
    }

    // ---------------------------------------------------------------- now playing

    @Test fun nowPlayingRule() {
        // only-playing -> that deck
        assertEquals(B, NowPlayingRule.pick(true, true, false, true, null))
        assertEquals(A, NowPlayingRule.pick(true, true, true, false, B))
        // zero or both playing -> A
        assertEquals(A, NowPlayingRule.pick(true, true, false, false, null))
        assertEquals(A, NowPlayingRule.pick(true, true, true, true, null))
        // only B loaded -> B; none -> null
        assertEquals(B, NowPlayingRule.pick(false, true, false, false, null))
        assertNull(NowPlayingRule.pick(false, false, false, false, null))
        // sticky last subject survives ambiguity while it still has a track
        assertEquals(B, NowPlayingRule.pick(true, true, false, false, B))
        assertEquals(A, NowPlayingRule.pick(true, false, false, false, B))
    }

    @Test fun nowPlayingDeckIsStickyAcrossPause() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        assertEquals(A, h.engine.nowPlayingDeck)
        h.engine.load(h.addSong("b"), B)
        h.engine.play(B)
        assertEquals(B, h.engine.nowPlayingDeck)
        h.engine.pause(B)
        assertEquals("pausing must not flip the card to A", B, h.engine.nowPlayingDeck)
        assertEquals("b", h.engine.nowPlaying!!.songId)
    }

    // ---------------------------------------------------------------- tick

    @Test fun tickClampsDtAdvancesAtRateAndStopsWhenIdle() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 100.0), A)
        h.engine.setRate(2.0, A)
        h.engine.play(A)
        assertTrue(h.engine.isTicking)
        assertTrue(h.tick(5_000))                               // a 5 s stall: dt clamps to 0.5 s
        assertEquals(1.0, h.engine.position(A), 1e-9)           // 0.5 s x rate 2
        assertTrue(h.tick(100))
        assertEquals(1.2, h.engine.position(A), 1e-9)
        h.engine.pause(A)
        assertFalse(h.tick(100))                                // idle: the tick stops itself
        assertFalse(h.engine.isTicking)
        h.engine.play(A)
        assertTrue("restarts on the next transport", h.engine.isTicking)
    }

    @Test fun deckReachingItsEndRetiresThroughTheFunnelUnlessAutoRuns() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 1.0), A)
        h.engine.play(A)
        h.recorder.events.clear()
        assertTrue(h.tick(500))
        assertEquals(0.5, h.engine.position(A), 1e-9)
        assertFalse("reached the end with nothing else playing -> tick stops", h.tick(500))
        assertEquals(1.0, h.engine.position(A), 1e-9)
        assertFalse(h.engine.deckState(A).isPlaying)
        assertFalse(h.engine.controller(A).isVoicePlaying)
        assertEquals(listOf("pause"), h.recorder.kinds())

        // a RUNNING auto mix owns the end: the deck is not retired by the tick
        val auto = FakeAutoDj().also { h.engine.autoDj = it; it.isMixing = true }
        h.engine.restart(A); h.engine.play(A)
        repeat(4) { h.tick(500) }
        assertTrue(h.engine.deckState(A).isPlaying)
        assertEquals(1.0, h.engine.position(A), 1e-9)
        // …but a SUSPENDED one does not
        auto.isPaused = true
        h.tick(500)
        assertFalse(h.engine.deckState(A).isPlaying)
    }

    @Test fun watchdogRestartsADeadSinkOnlyWhileTheMixWantsAudio() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 100.0), A)
        h.engine.play(A)
        h.render(h.seconds(0.2))
        h.renderer.stop()                                      // the system stopped the sink under a live mix
        assertFalse(h.engine.isRendering)
        h.tick(1_000)
        assertTrue(h.engine.isRendering)
        assertTrue(h.diags.any { it.contains("watchdog") })
        assertEquals("a parked tick must not advance playheads", 0.0, h.engine.position(A), 0.0)
        // nothing wants audio -> no restart
        h.engine.pause(A)
        h.renderer.stop()
        h.tick(1_000)
        assertFalse(h.engine.isRendering)
    }

    @Test fun heartbeatLineReportsLivenessOncePerSecond() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 100.0), A)
        h.engine.play(A)
        h.render(h.seconds(0.5))
        h.tick(100); h.tick(100)
        val hb = h.diags.filter { it.startsWith("hb ") }
        assertEquals(1, hb.size)
        assertTrue(hb[0], hb[0].contains("render=1") && hb[0].contains("A=(1,1,") && hb[0].contains("B=(0,0,"))
    }

    // ---------------------------------------------------------------- recorder: one event per setter

    @Test fun everySetterEmitsExactlyOneEvent() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 100.0, gridBpm = 120.0), A)
        h.engine.load(h.addSong("b", 100.0, gridBpm = 100.0), B)
        h.recorder.events.clear()
        fun once(expected: MixEventKind, body: () -> Unit): MixEventKindRec {
            val n = h.recorder.events.size
            body()
            assertEquals("events for $expected", n + 1, h.recorder.events.size)
            val e = h.recorder.events.last()
            assertEquals(expected, e.kind)
            return MixEventKindRec(e)
        }
        once(MixEventKind.Tempo) { h.engine.setRate(1.2, A) }.also { assertEquals(1.2, it.e.value!!, 0.0) }
        once(MixEventKind.Pitch) { h.engine.setPitch(-2.0, A) }.also { assertEquals(-2.0, it.e.value!!, 0.0) }
        once(MixEventKind.Volume) { h.engine.setVolume(1.4, A) }
        once(MixEventKind.Eq) { h.engine.setEqGain(EQBand.LOW, 3.0, A) }.also { assertEquals("low", it.e.param) }
        once(MixEventKind.Eq) { h.engine.setEqGain(EQBand.MID, -3.0, A) }.also { assertEquals("mid", it.e.param) }
        once(MixEventKind.Crossfader) { h.engine.setCrossfader(0.2) }.also { assertNull(it.e.deck) }
        once(MixEventKind.Lead) { h.engine.setLead(A) }.also { assertEquals(true, it.e.flag) }
        once(MixEventKind.EffectToggle) { h.engine.setEffect(Effect.REVERB, true, A) }.also { assertEquals("reverb", it.e.param) }
        once(MixEventKind.EffectStrength) { h.engine.setEffectStrength(Effect.REVERB, 0.8, A) }
        once(MixEventKind.EffectToggle) { h.engine.setSlot(0, true, A) }.also { assertEquals(0, it.e.slot) }
        once(MixEventKind.EffectStrength) { h.engine.setSlotStrength(0, 0.7, A) }
        once(MixEventKind.EffectSlot) { h.engine.setSlotEffect(Effect.FILTER, 0, A) }
        once(MixEventKind.EffectVariant) { h.engine.setSlotVariant(EffectVariant.HIGH_PASS, 0, A) }.also { assertEquals("highPass", it.e.param) }
        once(MixEventKind.EffectMod) {
            h.engine.setSlotMod(SlotMod.of(ModSource.LFO, ModRate.BAR, 0.5, ModShape.SINE, 0.0), 0, A)
        }.also { assertEquals("lfo:bar:sine", it.e.param) }
        once(MixEventKind.FilterMode) { h.engine.setFilterMode(FilterMode.LOW_PASS, A) }.also { assertEquals("lowPass", it.e.param) }
        once(MixEventKind.Seek) { h.engine.seek(A, 5.0) }
        // idempotent slot re-issues record nothing
        val n = h.recorder.events.size
        h.engine.setSlot(0, true, A)
        h.engine.setSlotEffect(Effect.FILTER, 0, A)
        h.engine.setSlotVariant(EffectVariant.LOW_PASS, 3, A)   // slot 3 is already a LOW_PASS filter
        assertEquals(n, h.recorder.events.size)
        // events carry the deck's song and playhead
        val seek = h.recorder.of(MixEventKind.Seek).single()
        assertEquals("A", seek.deck); assertEquals("a", seek.songId); assertEquals(5_000, seek.posMs)
    }

    private class MixEventKindRec(val e: FakeRecorder.Ev)

    @Test fun noRecorderIsANoOp() {
        val h = EngineHarness()
        h.engine.recorder = null
        h.engine.load(h.addSong("a"), A)
        h.engine.play(A); h.engine.setRate(1.1, A); h.engine.setCrossfader(0.3); h.engine.pause(A)
        assertTrue(h.recorder.events.isEmpty())
        assertEquals(1.1, h.engine.rate(A), 0.0)
    }

    @Test fun rangesAreClamped() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        h.engine.setRate(9.0, A); assertEquals(2.0, h.engine.rate(A), 0.0)
        h.engine.setRate(0.1, A); assertEquals(0.5, h.engine.rate(A), 0.0)
        h.engine.setPitch(40.0, A); assertEquals(12.0, h.engine.pitch(A), 0.0)
        h.engine.setVolume(5.0, A); assertEquals(2.0, h.engine.volume(A), 0.0)
        h.engine.setEqGain(EQBand.LOW, -40.0, A); assertEquals(-12.0, h.engine.eqGain(EQBand.LOW, A), 0.0)
        h.engine.setCrossfader(7.0); assertEquals(1.0, h.engine.crossfader, 0.0)
    }

    @Test fun effectKeyedShimsHitTheFirstMatchOnly() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a"), A)
        h.engine.setSlotEffect(Effect.REVERB, 0, A)            // rack: Reverb, Reverb, Flanger, Filter
        h.engine.setEffect(Effect.REVERB, true, A)
        assertTrue(h.engine.slot(0, A)!!.enabled)
        assertFalse(h.engine.slot(1, A)!!.enabled)
        assertTrue(h.engine.isEnabled(Effect.REVERB, A))
        h.engine.setEffectStrength(Effect.REVERB, 0.9, A)
        assertEquals(0.9, h.engine.slot(0, A)!!.strength, 0.0)
        assertEquals(0.5, h.engine.slot(1, A)!!.strength, 0.0)
        // the rack reaches the render snapshot
        assertNotNull(h.engine.params.current.a.slot(0))
        assertEquals(0.9, h.engine.params.current.a.slot(0)!!.strength, 0.0)
    }

    @Test fun loadedTrackKeepsGridFields() {
        val h = EngineHarness()
        h.addSong("g", 10.0, gridBpm = 123.4, firstDownbeatMs = 250)
        h.engine.load(com.levi.pocketdj.mix.model.MixLoadable("g", "G", "Art", bpm = 120.0, camelot = "9A"), A)
        val l: LoadedTrack = h.engine.loaded(A)!!
        assertEquals(123.4, l.gridBpm!!, 0.0)
        assertEquals(250, l.firstDownbeatMs)
        assertEquals(123.4, l.matchBpm!!, 0.0)
    }
}

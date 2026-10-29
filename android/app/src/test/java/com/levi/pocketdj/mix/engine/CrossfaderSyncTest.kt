package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.store.MixEventKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.log10

class CrossfaderSyncTest {
    private val A = Deck.A
    private val B = Deck.B

    private fun twoDecks(bpmA: Double? = 120.0, bpmB: Double? = 100.0, dbB: Int? = null): EngineHarness {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 200.0, gridBpm = bpmA), A)
        h.engine.load(h.addSong("b", 200.0, gridBpm = bpmB, firstDownbeatMs = dbB), B)
        h.recorder.events.clear()
        return h
    }

    // ---------------------------------------------------------------- crossfader + gain split

    @Test fun userCrossfaderRecordsOneEventAndAutoApplyRecordsNone() {
        val h = twoDecks()
        h.engine.setCrossfader(0.25)
        assertEquals(listOf("crossfader"), h.recorder.kinds())
        assertEquals(0.25, h.recorder.events[0].value!!, 0.0)
        assertNull(h.recorder.events[0].deck)
        h.recorder.events.clear()
        // a bare Auto on -> off sweeps the fader without logging a user gesture
        h.engine.applyCrossfader(0.0); h.engine.applyCrossfader(1.0); h.engine.applyCrossfader(0.5)
        assertTrue(h.recorder.events.isEmpty())
        assertEquals(0.5, h.engine.crossfader, 0.0)
    }

    @Test fun crossfaderIsEqualPowerOnTheMainGain() {
        val h = twoDecks()
        for (x in listOf(0.0, 0.25, 0.5, 0.8, 1.0)) {
            h.engine.applyCrossfader(x)
            val p = h.engine.params.current
            assertEquals(cos(PI / 2 * x).toFloat(), p.a.mainGain, 1e-6f)
            assertEquals(cos(PI / 2 * (1 - x)).toFloat(), p.b.mainGain, 1e-6f)
        }
        h.engine.applyCrossfader(0.5)
        val p = h.engine.params.current
        assertEquals(1.0, (p.a.mainGain * p.a.mainGain + p.b.mainGain * p.b.mainGain).toDouble(), 1e-5)
    }

    @Test fun volumeSplitsIntoFaderAndTrimAndCrossfaderNeverRederivesBoost() {
        val h = twoDecks()
        h.engine.setVolume(1.5, A)
        val trim = 20 * log10(1.5)
        assertEquals(trim, h.engine.params.current.a.trimDb.toDouble(), 1e-4)
        assertEquals(cos(PI / 4).toFloat(), h.engine.params.current.a.mainGain, 1e-6f)   // fader capped at unity x xfade
        val writes = h.engine.params.boostWrites
        for (x in listOf(0.1, 0.9, 0.3, 0.5)) { h.engine.setCrossfader(x); h.engine.applyCrossfader(x) }
        assertEquals("the crossfader path must never write the boost", writes, h.engine.params.boostWrites)
        assertEquals(trim, h.engine.params.current.a.trimDb.toDouble(), 1e-4)
        h.engine.setVolume(0.4, A)
        assertEquals(0f, h.engine.params.current.a.trimDb, 0f)
        assertEquals(0.4f * cos(PI * 0.25).toFloat(), h.engine.params.current.a.mainGain, 1e-6f)
    }

    // ---------------------------------------------------------------- cue

    @Test fun cueToggleVolumeAndChannel() {
        val h = twoDecks()
        h.engine.setVolume(1.5, A)
        assertFalse(h.engine.anyCued)
        assertEquals(0f, h.engine.params.current.house.housePan, 0f)
        assertEquals(0f, h.engine.params.current.a.cueGain, 0f)

        h.engine.setCueVolume(0.6, A)
        h.engine.toggleCue(A)
        assertTrue(h.engine.cued(A) && h.engine.anyCued)
        var p = h.engine.params.current
        assertEquals("boost divided back out", (0.6 / 1.5).toFloat(), p.a.cueGain, 1e-6f)
        assertEquals("house goes opposite the cue (cue right by default)", -1f, p.house.housePan, 0f)
        assertEquals(1f, p.house.cuePan, 0f)
        assertEquals(0f, p.b.cueGain, 0f)

        h.engine.setCueOnRight(false)
        p = h.engine.params.current
        assertEquals(1f, p.house.housePan, 0f); assertEquals(-1f, p.house.cuePan, 0f)

        h.engine.setCueVolume(3.0, A); assertEquals(1.0, h.engine.cueVolume(A), 0.0)
        h.engine.setCueVolume(-1.0, A); assertEquals(0.0, h.engine.cueVolume(A), 0.0)

        h.engine.toggleCue(A)
        assertFalse(h.engine.anyCued)
        assertEquals(0f, h.engine.params.current.house.housePan, 0f)
        // cue is transient monitoring state: never logged
        assertTrue(h.recorder.events.none { it.kind != MixEventKind.Volume })
    }

    // ---------------------------------------------------------------- lead / sync

    @Test fun leadIsExclusiveToggleAndClearedByALoadOnThatDeck() {
        val h = twoDecks()
        h.engine.setLead(A); assertTrue(h.engine.isLead(A))
        h.engine.setLead(B); assertTrue(h.engine.isLead(B)); assertFalse(h.engine.isLead(A))
        h.engine.setLead(B); assertNull(h.engine.leadDeck)
        assertEquals(listOf(true, true, false), h.recorder.of(MixEventKind.Lead).map { it.flag })
        h.engine.setLead(A)
        h.engine.load(h.addSong("c", 10.0), B)       // other deck: lead stays
        assertEquals(A, h.engine.leadDeck)
        h.engine.load(h.addSong("d", 10.0), A)
        assertNull(h.engine.leadDeck)
    }

    @Test fun canSyncGating() {
        val h = twoDecks(bpmA = 120.0, bpmB = null)
        assertFalse("no lead", h.engine.canSync(B))
        h.engine.setLead(A)
        assertFalse("the lead cannot sync to itself", h.engine.canSync(A))
        assertFalse("follower has no bpm", h.engine.canSync(B))
        h.engine.load(h.addSong("b2", 10.0, gridBpm = 100.0), B)
        assertTrue(h.engine.canSync(B))
    }

    @Test fun syncMatchesFollowerTempoToLeadAndRecordsTempoThenSync() {
        val h = twoDecks(bpmA = 120.0, bpmB = 100.0)
        h.engine.setLead(A)
        h.engine.setRate(1.1, A)
        h.recorder.events.clear()
        h.engine.syncToLead(B)
        assertEquals(120 * 1.1 / 100, h.engine.rate(B), 1e-9)
        assertEquals(listOf("tempo", "sync"), h.recorder.kinds())
        assertEquals(h.engine.rate(B), h.recorder.of(MixEventKind.Sync)[0].value!!, 0.0)
        assertEquals(1.1, h.engine.rate(A), 0.0)
        // the rate reaches the render snapshot
        assertEquals(1.32f, h.engine.params.current.b.speed, 1e-5f)
    }

    @Test fun syncOctaveFoldsAndPrefersTheMeasuredGridBpm() {
        val h = EngineHarness()
        h.engine.load(h.addSong("a", 50.0, gridBpm = 120.0).copy(bpm = 99.0), A)    // catalog 99, measured 120
        h.engine.load(h.addSong("b", 50.0, gridBpm = 50.0), B)
        h.engine.setLead(A)
        h.engine.syncToLead(B)
        assertEquals("120/50 = 2.4 folds to 1.2", 1.2, h.engine.rate(B), 1e-9)
    }

    @Test fun syncIsANoOpWithoutALeadForTheLeadItselfOrUnknownBpm() {
        val h = twoDecks(bpmA = 120.0, bpmB = null)
        h.engine.syncToLead(B)                      // no lead
        h.engine.setLead(A); h.recorder.events.clear()
        h.engine.syncToLead(A)                      // is the lead
        h.engine.syncToLead(B)                      // follower bpm unknown
        assertTrue(h.recorder.events.isEmpty())
        assertEquals(1.0, h.engine.rate(B), 0.0)
    }

    @Test fun phaseAlignSeeksFollowerOntoTheLeadsDownbeatPhase() {
        val h = twoDecks(bpmA = 120.0, bpmB = 100.0, dbB = 100)
        h.engine.play(A); h.engine.play(B)
        h.engine.seek(A, 10.0)                      // lead beat = 0.5 s, phase 0
        h.engine.seek(B, 20.35)                     // follower beat = 0.6 s, db 0.1 s -> phase of (20.25/0.6)
        h.engine.setLead(A)
        h.recorder.events.clear()

        h.engine.syncToLead(B)

        assertEquals(listOf("tempo", "seek", "sync"), h.recorder.kinds())
        val leadPhase = (h.engine.position(A) - 0.0) / 0.5 % 1.0
        val folPhase = (h.engine.position(B) - 0.1) / 0.6 % 1.0
        val d = ((leadPhase - folPhase) % 1.0 + 1.5) % 1.0 - 0.5     // wrapped to [-0.5, 0.5)
        assertEquals("downbeats coincide after sync", 0.0, d, 1e-6)
        assertTrue("moved by at most half a beat", kotlin.math.abs(h.engine.position(B) - 20.35) <= 0.3 + 1e-9)
    }

    @Test fun phaseAlignIsSkippedWhenADeckIsNotPlaying() {
        val h = twoDecks(bpmA = 120.0, bpmB = 100.0)
        h.engine.play(A)                            // follower paused
        h.engine.setLead(A); h.recorder.events.clear()
        h.engine.syncToLead(B)
        assertEquals(listOf("tempo", "sync"), h.recorder.kinds())
    }

    // ---------------------------------------------------------------- engine survives navigation

    @Test fun meterSourceIsPerDeckStateAndDefaultsToPost() {
        val h = twoDecks()
        assertEquals(com.levi.pocketdj.mix.model.MeterSource.POST, h.engine.meterSource(A))
        h.engine.setMeterSource(com.levi.pocketdj.mix.model.MeterSource.PRE, B)
        assertEquals(com.levi.pocketdj.mix.model.MeterSource.PRE, h.engine.meterSource(B))
        assertEquals(com.levi.pocketdj.mix.model.MeterSource.POST, h.engine.meterSource(A))
        assertEquals(com.levi.pocketdj.mix.model.MeterSource.PRE, h.engine.ui.value.meterSourceB)
        assertTrue(h.engine.levels(A) === h.engine.graph.levelsOf(A))
    }

    @Test fun uiFlowEmitsOnStateChangeButNotOnPositionTicks() {
        val h = twoDecks()
        h.engine.play(A)
        val before = h.engine.ui.value
        h.tick(100); h.tick(100); h.tick(100)
        assertTrue("position ticks live outside the StateFlow", before === h.engine.ui.value)
        assertTrue(h.engine.position(A) > 0.25)
        h.engine.setRate(1.5, A)
        assertEquals(1.5, h.engine.ui.value.a.rate, 0.0)
    }

    @Test fun mixLoadableCarriesAnalogLengthIntoThePersistedWindow() {
        val h = EngineHarness()
        val item: MixLoadable = h.addSong("an", 100.0, isCut = false, startMs = 10_000).copy(lengthMs = 20_000)
        h.engine.load(item, A)
        assertEquals(20_000, h.engine.mixDeckSnapshot()!!.deckA!!.track.lengthMs)
    }

    // ---------------------------------------------------------------- latency compensation (ANS-MIX-2)

    @Test fun audiblePhaseSubtractsTheStretcherLag() {
        // 120 bpm: a 0.5 s beat. A position exactly on a downbeat but 100 ms ahead of what is heard sounds 0.8 beat in.
        assertEquals(0.0, PhaseAlignMath.audiblePhase(10.0, 0.0, 0.0, 0.5), 1e-9)
        assertEquals(0.8, PhaseAlignMath.audiblePhase(10.0, 0.1, 0.0, 0.5), 1e-9)
        assertEquals(0.5, PhaseAlignMath.audiblePhase(10.0, 0.0, 0.25, 0.5), 1e-9)
    }

    @Test fun targetCorrectsOnlyTheAudibleOffsetWhenDecksLagDifferently() {
        // Both on the grid in raw positions, but the follower runs at +30 % tempo so its lag (source s) is larger.
        val t = PhaseAlignMath.target(
            leadPos = 10.0, leadLag = 0.120, leadDb = 0.0, leadBeat = 0.5,
            folPos = 20.0, folLag = 0.356, folDb = 0.0, folBeat = 0.6,
        )
        // lead heard at phase 1-0.24 = 0.76; follower heard at phase 1-0.26=0.74 -> follower is 0.02 beats behind
        assertEquals(0.02 * 0.6, t.seekSec - 20.0, 1e-9)
        assertEquals(12.0, t.errorMs, 1e-6)
        // the lag changes the answer: uncompensated raw positions would have moved the follower elsewhere
        val raw = PhaseAlignMath.target(10.0, 0.0, 0.0, 0.5, 20.0, 0.0, 0.0, 0.6)
        assertTrue(kotlin.math.abs(raw.seekSec - t.seekSec) > 0.05)
    }

    @Test fun syncToLeadAlignsAudibleBeatsNotRawPositions() {
        val h = twoDecks(bpmA = 120.0, bpmB = 100.0, dbB = 100)
        val lag = mapOf(A to 0.150, B to 0.210)             // follower is slower to emerge (e.g. tempo +30 %)
        h.engine.lagSecondsOverride = { lag.getValue(it) }
        h.engine.play(A); h.engine.play(B)
        h.engine.seek(A, 10.0)
        h.engine.seek(B, 20.35)
        h.engine.setLead(A)
        h.engine.syncToLead(B)

        val lp = PhaseAlignMath.audiblePhase(h.engine.position(A), 0.150, 0.0, 0.5)
        val fp = PhaseAlignMath.audiblePhase(h.engine.position(B), 0.210, 0.1, 0.6)
        val d = ((lp - fp) % 1.0 + 1.5) % 1.0 - 0.5
        assertEquals("audible downbeats coincide (< 5 ms)", 0.0, d * 0.6 * 1000, 5.0)
    }
}

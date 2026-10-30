package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.EQBand
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import com.levi.pocketdj.mix.model.SlotMod
import com.levi.pocketdj.mix.store.AutoRow
import com.levi.pocketdj.mix.store.AutoSnapshot
import com.levi.pocketdj.mix.store.ManualScheduler
import com.levi.pocketdj.mix.store.MixDeckSessionStore
import com.levi.pocketdj.mix.store.MixEventKind
import com.levi.pocketdj.mix.store.TestClock
import com.levi.pocketdj.mix.store.TrackRef
import com.levi.pocketdj.mix.store.tempFile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixEnginePersistenceTest {
    private val A = Deck.A
    private val B = Deck.B

    private class Rig {
        val clock = TestClock()
        val sched = ManualScheduler(clock)
        val file = tempFile("decks.json")
        val writer = VersionedJsonWriter(file)
        val store = MixDeckSessionStore(file, writer, clock::read, sched)
        val h = EngineHarness(store)
        /** A fresh process: same file + same songs, a new engine and a new store. */
        fun relaunch(): EngineHarness {
            val s = MixDeckSessionStore(file, VersionedJsonWriter(file), clock::read, sched)
            return EngineHarness(s, songs = h.songs, sources = h.sources)
        }
    }

    private fun populated(r: Rig) {
        val h = r.h
        h.engine.load(h.addSong("a", 120.0, gridBpm = 124.0).copy(bpm = 123.0), A)
        h.engine.load(h.addSong("b", 90.0, gridBpm = 100.0), B)
        h.engine.setVolume(1.4, A); h.engine.setRate(1.2, A); h.engine.setPitch(2.0, A)
        h.engine.setEqGain(EQBand.LOW, -3.0, A); h.engine.setEqGain(EQBand.HIGH, 4.5, A)
        h.engine.setSlotEffect(Effect.FILTER, 0, A)
        h.engine.setSlotVariant(EffectVariant.HIGH_PASS, 0, A)
        h.engine.setSlot(0, true, A); h.engine.setSlotStrength(0, 0.8, A)
        h.engine.setSlotMod(SlotMod.of(ModSource.LFO, ModRate.BAR, -0.4, ModShape.TRIANGLE, 0.25), 0, A)
        h.engine.setCrossfader(0.3)
        h.engine.setLead(B)
        h.engine.seek(A, 42.5); h.engine.seek(B, 10.0)
        h.engine.setCued(true, A)          // transient: must NOT persist
        h.engine.persist()
    }

    // ---------------------------------------------------------------- round trip

    @Test fun snapshotBuildRestoreRoundTripWithNothingPlayingAndTheRecorderDetached() {
        val r = Rig(); populated(r)
        val original = r.h.engine.mixDeckSnapshot()!!
        r.store.flush()

        val h2 = r.relaunch()
        h2.engine.restorePersistedMixIfIdle()
        assertTrue("parked at launch", h2.engine.hasParkedRestore)
        assertNull(h2.engine.loaded(A)); assertNull(h2.engine.loaded(B))
        assertEquals("a", h2.engine.parkedRestoreSummary!!.let { "a" })
        assertFalse("no sink while parked", h2.renderer.isRendering)

        h2.engine.materializePendingRestoreIfNeeded()

        assertFalse(h2.engine.hasParkedRestore)
        assertFalse("restore claims no audio: the sink stays inert", h2.renderer.isRendering)
        assertFalse(h2.engine.isRunning)
        assertFalse(h2.engine.deckState(A).isPlaying || h2.engine.deckState(B).isPlaying)
        assertTrue("recorder detached while materializing", h2.recorder.events.isEmpty())
        assertTrue(h2.recorder.played.isEmpty())
        val a = h2.engine.deckState(A)
        assertEquals("a", a.loaded!!.songId)
        assertEquals(1.4, a.volume, 0.0); assertEquals(1.2, a.rate, 0.0); assertEquals(2.0, a.pitch, 0.0)
        assertEquals(-3.0, a.eqLow, 0.0); assertEquals(4.5, a.eqHigh, 0.0)
        assertEquals(Effect.FILTER, a.slots[0].effect)
        assertEquals(EffectVariant.HIGH_PASS, a.slots[0].variant)
        assertTrue(a.slots[0].enabled); assertEquals(0.8, a.slots[0].strength, 0.0)
        assertEquals(ModSource.LFO, a.slots[0].mod.source); assertEquals(-0.4, a.slots[0].mod.depth, 1e-9)
        assertEquals(42.5, h2.engine.position(A), 1e-9)
        assertEquals(10.0, h2.engine.position(B), 1e-9)
        assertEquals(0.3, h2.engine.crossfader, 0.0)
        assertEquals(B, h2.engine.leadDeck)
        assertFalse("cue/PFL is transient and never restored", a.cued)
        // the restored deck reaches the render snapshot
        assertEquals(1.2f, h2.engine.params.current.a.speed, 1e-6f)
        assertEquals(0.8, h2.engine.params.current.a.slot(0)!!.strength, 0.0)
        // and re-snapshotting reproduces the original
        val again = h2.engine.mixDeckSnapshot()!!
        assertEquals(original.copy(updatedAt = 0.0), again.copy(updatedAt = 0.0))
        // after materialize the recorder is live again
        h2.engine.setRate(1.3, A)
        assertEquals(1, h2.recorder.of(MixEventKind.Tempo).size)
    }

    @Test fun materializeIsNotAWrite() {
        val r = Rig(); populated(r); r.store.flush()
        val before = r.file.readText()
        val h2 = r.relaunch()
        h2.engine.restorePersistedMixIfIdle()
        h2.engine.materializePendingRestoreIfNeeded()
        assertEquals(before, r.file.readText())
        assertEquals(0, h2.engine.deckState(A).let { if (it.isPlaying) 1 else 0 })
    }

    @Test fun anIdleEngineNeverClobbersAParkedSnapshot() {
        val r = Rig(); populated(r); r.store.flush()
        val before = r.file.readText()
        val h2 = r.relaunch()
        h2.engine.restorePersistedMixIfIdle()
        h2.engine.setCrossfader(0.9)            // a gesture before materialization
        h2.engine.persist(); h2.engine.persistPositions()
        r.sched.advance(10_000)
        assertEquals("the on-disk file IS the pending state", before, r.file.readText())
    }

    @Test fun aRealLoadDropsTheParkedRestore() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.restorePersistedMixIfIdle()
        h2.engine.load(h2.addSong("fresh", 30.0), A)
        assertFalse(h2.engine.hasParkedRestore)
        h2.engine.materializePendingRestoreIfNeeded()
        assertEquals("fresh", h2.engine.loaded(A)!!.songId)
        assertNull("the old deck B never rehydrates on top", h2.engine.loaded(B))
    }

    @Test fun aVanishedFileLeavesThatDeckEmpty() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.removeSong("b")
        h2.engine.restorePersistedMixIfIdle()
        h2.engine.materializePendingRestoreIfNeeded()
        assertEquals("a", h2.engine.loaded(A)!!.songId)
        assertNull(h2.engine.loaded(B))
        assertEquals("a restored deck still has its state", 1.2, h2.engine.rate(A), 0.0)
    }

    @Test fun aDeckPersistedAtItsEndIsRecuedAndMarkedExhausted() {
        val r = Rig()
        val h = r.h
        h.engine.load(h.addSong("a", 60.0), A); h.engine.load(h.addSong("b", 60.0), B)
        h.engine.seek(A, 60.0)               // parked at end-of-file
        h.engine.seek(B, 20.0)
        h.engine.persist(); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.restorePersistedMixIfIdle(); h2.engine.materializePendingRestoreIfNeeded()
        assertEquals(0.0, h2.engine.position(A), 0.0)
        assertTrue(h2.engine.deckExhaustedFromRestore(A))
        assertFalse(h2.engine.deckExhaustedFromRestore(B))
        assertEquals(20.0, h2.engine.position(B), 1e-9)
        // lock-screen play must not resume the finished deck
        h2.engine.resumeMasterPaused()
        assertFalse(h2.engine.deckState(A).isPlaying)
        // an explicit play replays it from 0:00 and clears the mark
        h2.engine.play(A)
        assertFalse(h2.engine.deckExhaustedFromRestore(A))
        assertTrue(h2.engine.deckState(A).isPlaying)
    }

    @Test fun aFullyFinishedMixDoesNotRestoreAtAll() {
        val r = Rig()
        val h = r.h
        h.engine.load(h.addSong("a", 60.0), A)
        h.engine.seek(A, 60.0)
        h.engine.persist(); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.restorePersistedMixIfIdle()
        assertFalse(h2.engine.hasParkedRestore)
    }

    @Test fun restoreIsNotAGestureAndStartsNoAudioOwner() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        var claimed = 0
        h2.engine.onAudioStarted = { claimed++ }
        val extras = mutableListOf<Deck>()
        h2.engine.onRestoreDeckExtras = { d, _ -> extras += d }
        h2.engine.restorePersistedMixIfIdle(); h2.engine.materializePendingRestoreIfNeeded()
        assertEquals(0, claimed)
        assertFalse(h2.engine.hasSoundedThisProcess)
        assertEquals(listOf(A, B), extras)
        h2.engine.play(A)
        assertEquals(1, claimed)
        assertTrue(h2.engine.hasSoundedThisProcess)
        assertTrue("the first real transport starts the sink", h2.renderer.isRendering)
    }

    @Test fun materializeWaitsForALiveSetlistThenFinishesOnTheNextRequest() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.setlistIsLive = { true }
        h2.engine.materializePendingRestoreIfNeeded()    // the Mix tab asked first (nothing parked yet)
        h2.engine.restorePersistedMixIfIdle()            // launch task lands: a set list is live
        assertTrue(h2.engine.hasParkedRestore)
        assertNull(h2.engine.loaded(A))
        h2.engine.setlistIsLive = { false }
        h2.engine.materializePendingRestoreIfNeeded()
        assertEquals("a", h2.engine.loaded(A)!!.songId)
    }

    @Test fun aLaterMixTabRequestMaterializesEvenBehindAHeldSetlist() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.setlistIsLive = { true }               // a held (durable) set list run stays live
        h2.engine.restorePersistedMixIfIdle()            // launch read parks; nothing wanted yet
        h2.engine.materializePendingRestoreIfNeeded()    // the user opens the Mix tab (iOS: always materializes)
        assertEquals("a", h2.engine.loaded(A)!!.songId)
    }

    @Test fun materializeRightAwayWhenTheTabAskedBeforeTheLaunchRead() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.materializePendingRestoreIfNeeded()   // parks from the store itself, then materializes
        assertEquals("a", h2.engine.loaded(A)!!.songId)
        h2.engine.restorePersistedMixIfIdle()           // a late launch task is a harmless no-op
        assertEquals("a", h2.engine.loaded(A)!!.songId)
    }

    @Test fun restoreIsSkippedWhenTheEngineIsAlreadyInUse() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.load(h2.addSong("intent", 10.0), A)
        h2.engine.restorePersistedMixIfIdle()
        assertFalse(h2.engine.hasParkedRestore)
    }

    @Test fun autoQueueRidesTheSnapshotAndRestoresSuspendedThroughTheHook() {
        val r = Rig(); val h = r.h
        val auto = FakeAutoDj()
        h.engine.autoDj = auto
        val ref = TrackRef("q1", "Q1", "Art", 110.0)
        auto.snap = AutoSnapshot(
            queue = listOf(AutoRow(ref, 200_000, "Crate")), livePos = 0, nextToLoad = 1, liveDeck = "A",
            sourceLabel = "Crate", leadSeconds = 15.0, fadeSeconds = 3.0, fxGlide = false, mixGlide = true,
        )
        h.engine.load(h.addSong("a", 60.0), A)
        h.engine.persist(); r.store.flush()

        val h2 = r.relaunch()
        val auto2 = FakeAutoDj(); h2.engine.autoDj = auto2
        h2.engine.restorePersistedMixIfIdle(); h2.engine.materializePendingRestoreIfNeeded()
        assertEquals(auto.snap, auto2.restored)
        // an auto-only mix (both decks empty) still snapshots
        h.engine.clearDeck(A)
        assertNotNull(h.engine.mixDeckSnapshot())
        assertNull(h.engine.mixDeckSnapshot()!!.deckA)
    }

    @Test fun ejectAllDropsParkedRestoreEmptiesDecksAndClearsTheFile() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.restorePersistedMixIfIdle()
        h2.engine.ejectAll()
        assertFalse(h2.engine.hasParkedRestore)
        h2.engine.materializePendingRestoreIfNeeded()
        assertNull(h2.engine.loaded(A))
        assertNull(r.store.load())
    }

    // ---------------------------------------------------------------- write cadence

    @Test fun structuralChangesWriteImmediatelyAndSlidersAreDebounced() {
        val r = Rig(); val h = r.h
        h.engine.load(h.addSong("a", 100.0), A)
        val w0 = r.writer.writeCount
        assertTrue("a load persists immediately", w0 >= 1)

        h.engine.setRate(1.1, A); h.engine.setRate(1.2, A); h.engine.setVolume(0.9, A); h.engine.seek(A, 5.0)
        assertEquals("slider surfaces coalesce", w0, r.writer.writeCount)
        r.sched.advance(999)
        assertEquals(w0, r.writer.writeCount)
        r.sched.advance(1)
        assertEquals("ONE trailing write for the burst", w0 + 1, r.writer.writeCount)
        assertEquals(1.2, r.store.load()!!.deckA!!.rate, 0.0)       // the drag's final value persisted
        assertEquals(0.9, r.store.load()!!.deckA!!.volume, 0.0)

        h.engine.setEffect(Effect.REVERB, true, A)                   // discrete tap: immediate
        assertEquals(w0 + 2, r.writer.writeCount)
        h.engine.setLead(A)
        assertEquals(w0 + 3, r.writer.writeCount)
        assertEquals("A", r.store.load()!!.leadDeck)
    }

    @Test fun positionsAreThrottledWhileRunningAndImmediateOnTransitions() {
        val r = Rig(); val h = r.h
        h.engine.load(h.addSong("a", 600.0), A)
        val w0 = r.writer.writeCount
        h.engine.play(A)
        assertEquals("run transition writes immediately", w0 + 1, r.writer.writeCount)
        assertTrue(r.store.load()!!.wasRunning)
        repeat(10) { h.tick(100) }
        assertEquals("within the 5 s throttle", w0 + 1, r.writer.writeCount)
        r.clock.now += 5_000
        h.tick(100)
        assertEquals(w0 + 2, r.writer.writeCount)
        assertTrue(r.store.load()!!.deckA!!.positionMs > 900)
        h.engine.pause(A)
        assertEquals("pause transition writes immediately", w0 + 3, r.writer.writeCount)
        assertFalse(r.store.load()!!.wasRunning)
        h.tick(100)
        assertEquals("steady paused writes nothing", w0 + 3, r.writer.writeCount)
    }

    @Test fun noStoreIsANoOp() {
        val h = EngineHarness(null)
        h.engine.load(h.addSong("a", 10.0), A)
        h.engine.play(A); h.engine.setRate(1.2, A); h.engine.pause(A)
        h.engine.restorePersistedMixIfIdle()
        assertFalse(h.engine.hasParkedRestore)
    }

    @Test fun freshEngineMaterializesStraightFromTheStoreWithoutALaunchPark() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.materializePendingRestoreIfNeeded()   // NO restorePersistedMixIfIdle call
        assertEquals("a", h2.engine.loaded(A)!!.songId)
        assertEquals("b", h2.engine.loaded(B)!!.songId)
    }

    @Test fun anUnrestoredEmptyEngineSetterNeverDeletesTheSavedMix() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.setCrossfader(0.9)          // nothing parked yet
        h2.engine.persist()
        r.sched.advance(10_000)
        val h3 = r.relaunch()
        h3.engine.materializePendingRestoreIfNeeded()
        assertEquals("a", h3.engine.loaded(A)!!.songId)
    }

    @Test fun offMainLoadCommitsLaterAndAStaleResolveCannotClobberANewerLoad() {
        val h = EngineHarness()
        val pending = ArrayList<Pair<() -> MixEngine.PreparedLoad?, (MixEngine.PreparedLoad?) -> Unit>>()
        h.engine.loadOffload = { w, c -> pending += w to c }
        h.engine.load(h.addSong("old", 20.0), A)
        h.engine.load(h.addSong("new", 20.0), A)
        assertNull(h.engine.loaded(A))                       // nothing committed on the caller thread
        // resolves finish out of order: new first, then the stale one
        val (w2, c2) = pending[1]; c2(w2())
        val (w1, c1) = pending[0]; c1(w1())
        assertEquals("new", h.engine.loaded(A)!!.songId)
    }

    // ---------------------------------------------------------------- ANS-MIX-3: launch park from file + atomic restore

    @Test fun launchParkFromFileShowsTheParkedCardAndMaterializesCued() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        assertNull("nothing parked before the launch read", h2.engine.parkedCard())
        var cardRefreshes = 0
        h2.engine.onNowPlayingChanged = { cardRefreshes++ }
        // The launch read happens off Main (MixGraph.launchRestore); the engine only receives the snapshot.
        val snap = MixDeckSessionStore(r.file, VersionedJsonWriter(r.file), r.clock::read, r.sched).load()
        assertNotNull(snap)
        h2.engine.parkRestore(snap)
        assertTrue(h2.engine.hasParkedRestore)
        assertTrue("the lock-screen / Auto card refreshes on park", cardRefreshes >= 1)
        val card = h2.engine.parkedCard()!!
        assertEquals("the lead deck (B) is the parked subject", "b", card.songId)
        assertEquals(10_000, card.positionMs)
        assertNull("decks stay unloaded while parked", h2.engine.loaded(A))
        h2.engine.materializePendingRestoreIfNeeded("autoRow")
        assertEquals("a", h2.engine.loaded(A)!!.songId)
        assertEquals("b", h2.engine.loaded(B)!!.songId)
        assertNull("materialized: nothing parked any more", h2.engine.parkedCard())
    }

    @Test fun mixTabBeforeTheLaunchReadLandsWaitsForItAndNeverReadsDiskOnMain() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        var inFlight = true
        h2.engine.launchReadInFlight = { inFlight }
        var after = 0
        h2.engine.materializePendingRestoreIfNeeded("mixTab") { after++ }   // cold launch straight onto Mix
        // the old path did a synchronous store.load() here and cued the decks on the caller (Main)
        assertNull(h2.engine.loaded(A)); assertFalse(h2.engine.hasParkedRestore); assertEquals(0, after)
        inFlight = false
        h2.engine.launchReadFinished(r.store.load())                          // the IO read lands: the park completes the job
        assertEquals("a", h2.engine.loaded(A)!!.songId)
        assertEquals("b", h2.engine.loaded(B)!!.songId)
        assertEquals(1, after)
    }

    @Test fun aLaunchReadThatFindsNothingStillFinishesAWaitingMixTabRequest() {
        val h = EngineHarness()
        h.engine.launchReadInFlight = { true }
        var after = 0
        h.engine.materializePendingRestoreIfNeeded("mixTab") { after++ }
        assertEquals(0, after)
        h.engine.launchReadFinished(null)
        assertEquals(1, after)
    }

    @Test fun aLateLaunchSnapshotNeverDuplicatesOrResurrects() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        val snap = r.store.load()
        var work: (() -> MixEngine.RestorePrep)? = null
        var commit: ((MixEngine.RestorePrep) -> Unit)? = null
        h2.engine.restoreOffload = { w, c -> work = w; commit = c }
        h2.engine.parkRestore(snap)
        h2.engine.materializePendingRestoreIfNeeded()          // prep in flight (materializing)
        h2.engine.parkRestore(snap)                            // a second park must not re-park / re-prep
        assertFalse(h2.engine.hasParkedRestore)
        commit!!(work!!())
        assertEquals("a", h2.engine.loaded(A)!!.songId)
        // user ejects, then a stale snapshot arrives
        val h3 = r.relaunch()
        h3.engine.ejectAll()
        h3.engine.parkRestore(snap)
        assertFalse("eject before the read landed: the old snapshot must stay dead", h3.engine.hasParkedRestore)
    }

    @Test fun parkRestoreIsIgnoredOnceTheEngineIsInUse() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        h2.engine.load(h2.addSong("fresh", 30.0), A)
        h2.engine.parkRestore(r.store.load())
        assertFalse(h2.engine.hasParkedRestore)
        assertNull(h2.engine.loaded(B))
    }

    @Test fun restorePreparesBothDecksOffMainThenCommitsAtomically() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        var work: (() -> MixEngine.RestorePrep)? = null
        var commit: ((MixEngine.RestorePrep) -> Unit)? = null
        h2.engine.restoreOffload = { w, c -> work = w; commit = c }
        h2.engine.parkRestore(r.store.load())
        var after = 0
        h2.engine.materializePendingRestoreIfNeeded("mixTab") { after++ }
        assertNotNull("the disk half was handed off, not run inline", work)
        assertNull(h2.engine.loaded(A)); assertNull(h2.engine.loaded(B))
        assertEquals("completion callbacks wait for the commit", 0, after)
        val prep = work!!()                      // IO thread
        assertNull("still nothing on the decks between prepare and commit", h2.engine.loaded(A))
        commit!!(prep)                           // Main
        assertEquals("a", h2.engine.loaded(A)!!.songId)
        assertEquals("b", h2.engine.loaded(B)!!.songId)
        assertEquals(42.5, h2.engine.position(A), 1e-9)
        assertEquals(1, after)
    }

    @Test fun aRealLoadWhileTheRestoreIsPreparingDiscardsThePreparedDecks() {
        val r = Rig(); populated(r); r.store.flush()
        val h2 = r.relaunch()
        var work: (() -> MixEngine.RestorePrep)? = null
        var commit: ((MixEngine.RestorePrep) -> Unit)? = null
        h2.engine.restoreOffload = { w, c -> work = w; commit = c }
        h2.engine.parkRestore(r.store.load())
        h2.engine.materializePendingRestoreIfNeeded()
        val prep = work!!()
        h2.engine.load(h2.addSong("fresh", 30.0), A)   // user loads a song while the disk read was in flight
        commit!!(prep)
        assertEquals("fresh", h2.engine.loaded(A)!!.songId)
        assertNull("the stale restore must not land on the other deck", h2.engine.loaded(B))
    }
}

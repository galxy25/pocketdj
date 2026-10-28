package com.levi.pocketdj.mix.store

import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.mix.model.Effect
import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.ModRate
import com.levi.pocketdj.mix.model.ModShape
import com.levi.pocketdj.mix.model.ModSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixDeckSessionStoreTest {
    private val clock = TestClock()
    private val sched = ManualScheduler(clock)

    private fun track(id: String = "s1", len: Int? = 200_000) =
        TrackRef(id, "T $id", "Artist", bpm = 120.0, lengthMs = len)

    private fun deck(id: String = "s1", pos: Int = 1_000, len: Int? = 200_000) = DeckSnapshot(
        track = track(id, len), positionMs = pos, volume = 1.0, rate = 1.0, pitch = 0.0,
        compressor = true, reverb = false, flanger = true, filter = true,
        compStrength = 0.4, reverbStrength = 0.5, flangerStrength = 0.6, filterStrength = 0.7,
        stemMode = false, stemMuted = emptyList(), stemVol = emptyMap(),
    )

    private fun snap(a: DeckSnapshot? = deck(), b: DeckSnapshot? = null, running: Boolean = false, xf: Double = 0.5) =
        MixDeckSnapshot(deckA = a, deckB = b, crossfader = xf, wasRunning = running, updatedAt = 0.0)

    private fun store(file: java.io.File = tempFile("decks.json"), writer: VersionedJsonWriter = VersionedJsonWriter(file)) =
        MixDeckSessionStore(file, writer, clock::read, sched)

    @Test fun roundTrip() {
        val s = store()
        s.save(snap(b = deck("s2", 5)), clock.now)
        val loaded = s.load()!!
        assertEquals("s1", loaded.deckA!!.track.songId)
        assertEquals(5, loaded.deckB!!.positionMs)
        assertEquals(clock.now.toDouble(), loaded.updatedAt, 0.0)
        assertEquals(1, loaded.schemaVersion)
    }

    @Test fun iosFixtureDecodes() {
        val f = tempFile("decks.json").also { it.writeText(fixtureText("ios-mix-decks-v1.json")) }
        val loaded = store(f).load()!!
        val a = loaded.deckA!!
        assertEquals("Elevator to the Moon", a.track.title)
        assertEquals(122.6, a.track.bpm!!, 0.0)
        assertEquals(83_000, a.positionMs)
        assertEquals(-2.5, a.eqMid!!, 0.0)
        assertEquals(0.42, loaded.crossfader, 0.0)
        assertEquals("A", loaded.leadDeck)
        assertEquals(mapOf("drums" to 0.8), loaded.deckB!!.stemVol)
        assertEquals(listOf("vocals"), loaded.deckB!!.stemMuted)
        assertEquals(2, loaded.auto!!.queue.size)
        assertEquals("Friday Night Warmup", loaded.auto!!.queue[0].sourceLabel)
        assertNull(loaded.auto!!.queue[1].sourceLabel)
        assertTrue(loaded.auto!!.fxGlide)
    }

    @Test fun fixtureRackResolvesLosslesslyAndUnknownModDegradesToOff() {
        val f = tempFile("decks.json").also { it.writeText(fixtureText("ios-mix-decks-v1.json")) }
        val slots = store(f).load()!!.deckA!!.resolvedSlots
        assertEquals(listOf("glue", "plate", "echo", "highPass"), slots.map { it.variant })
        val lfo = slots[1].resolvedMod
        assertEquals(ModSource.LFO, lfo.source)
        assertEquals(ModRate.EIGHTH, lfo.rate)
        assertEquals(ModShape.TRIANGLE, lfo.shape)
        assertEquals(-0.7, lfo.depth, 1e-9)
        assertEquals(0.25, lfo.phase, 1e-9)
        val garbage = slots[2].resolvedMod
        assertEquals(ModSource.OFF, garbage.source)
        assertEquals(ModRate.BAR, garbage.rate)
        assertEquals(ModShape.SINE, garbage.shape)
        assertEquals(0.5, garbage.depth, 0.0)
        val live = slots[1].toSlot()
        assertEquals(Effect.REVERB, live.effect)
        assertEquals(EffectVariant.PLATE, live.variant)
        assertTrue(live.enabled)
    }

    @Test fun legacyFlatFieldsMigrateToDefaultLayoutWhenFxSlotsAbsent() {
        val f = tempFile("decks.json").also { it.writeText(fixtureText("ios-mix-decks-v1.json")) }
        val b = store(f).load()!!.deckB!!
        assertNull(b.fxSlots)
        val d = deck().copy(filterMode = "highPass")
        val slots = d.resolvedSlots
        assertEquals(listOf("compressor", "reverb", "flanger", "filter"), slots.map { it.effect })
        assertEquals(listOf("punch", "hall", "flange", "highPass"), slots.map { it.variant })
        assertEquals(listOf(true, false, true, true), slots.map { it.on })
        assertEquals(listOf(0.4, 0.5, 0.6, 0.7), slots.map { it.strength })
        assertEquals("lowPass", deck().resolvedSlots[3].variant)
        assertEquals(4, b.resolvedSlots.size)
    }

    @Test fun malformedRackFallsBackToFlatFields() {
        val good = FXSlotSnapshot("reverb", "hall", true, 0.9)
        val wrongCount = deck().copy(fxSlots = listOf(good))
        assertEquals("punch", wrongCount.resolvedSlots[0].variant)
        // variant from the wrong family
        val crossFamily = deck().copy(fxSlots = List(4) { FXSlotSnapshot("reverb", "punch", true, 0.9) })
        assertEquals("compressor", crossFamily.resolvedSlots[0].effect)
        val unknown = deck().copy(fxSlots = List(4) { FXSlotSnapshot("wobble", "x", true, 0.9) })
        assertEquals(0.4, unknown.resolvedSlots[0].strength, 0.0)
        val ok = deck().copy(fxSlots = List(4) { FXSlotSnapshot("reverb", "room", true, 0.9) })
        assertEquals("room", ok.resolvedSlots[2].variant)
    }

    @Test fun writesFlatFieldsAlongsideOptionalFxSlotsWithIosKeyNames() {
        val f = tempFile("decks.json")
        val slots = List(4) { FXSlotSnapshot.from(com.levi.pocketdj.mix.model.FXSlot(Effect.FILTER)) }
        store(f).save(snap(deck().copy(fxSlots = slots, loopOn = true)), clock.now)
        val text = f.readText()
        for (k in listOf("\"schemaVersion\":1", "\"deckA\"", "\"positionMs\"", "\"compStrength\"",
            "\"stemMuted\"", "\"fxSlots\"", "\"modSource\"", "\"loopOn\":true", "\"wasRunning\"", "\"updatedAt\"")) {
            assertTrue("missing $k in $text", text.contains(k))
        }
        assertFalse("nil optionals must be omitted", text.contains("\"deckB\""))
        assertFalse(text.contains("null"))
    }

    @Test fun schemaMismatchAndGarbageLoadNull() {
        val f = tempFile("decks.json")
        val s = store(f)
        assertNull(s.load())   // no file
        val base = fixtureText("ios-mix-decks-v1.json")
        f.writeText(base.replaceFirst("\"schemaVersion\":1", "\"schemaVersion\":2"))
        assertNull(s.load())
        f.writeText(base.replaceFirst("\"schemaVersion\":1,", ""))
        assertNull(s.load())
        f.writeText("{not json")
        assertNull(s.load())
        f.writeText(base.replace("\"crossfader\":0.42,", ""))   // required key missing
        assertNull(s.load())
        f.writeText(base)
        assertNotNull(s.load())
    }

    @Test fun emptySnapshotRejected() {
        val s = store()
        s.save(snap(a = null, b = null), clock.now)
        assertNull(s.load())
        val emptyAuto = snap(a = null).copy(auto = autoSnap(queue = emptyList()))
        s.save(emptyAuto, clock.now)
        assertNull(s.load())
        s.save(snap(a = null).copy(auto = autoSnap(queue = listOf(AutoRow(track(), 1_000)))), clock.now)
        assertNotNull(s.load())
    }

    private fun autoSnap(queue: List<AutoRow>, next: Int = 0, repeat: String? = null, live: String = "A") = AutoSnapshot(
        queue = queue, livePos = 0, nextToLoad = next, liveDeck = live, leadSeconds = 15.0,
        fadeSeconds = 8.0, fxGlide = false, mixGlide = false, repeatMode = repeat,
    )

    @Test fun exhaustedMixesRejected() {
        val s = store()
        val atEnd = deck("a", pos = 199_800, len = 200_000)
        // live deck at end, nothing follows
        s.save(snap(a = atEnd), clock.now); assertNull(s.load())
        // standby still has audio
        s.save(snap(a = atEnd, b = deck("b", pos = 0)), clock.now); assertNotNull(s.load())
        // standby also finished
        s.save(snap(a = atEnd, b = deck("b", pos = 199_900)), clock.now); assertNull(s.load())
        // live not at end
        s.save(snap(a = deck("a", pos = 100)), clock.now); assertNotNull(s.load())
        val row = AutoRow(track(), 200_000)
        // auto cursor can advance
        s.save(snap(a = atEnd).copy(auto = autoSnap(listOf(row, row), next = 1)), clock.now); assertNotNull(s.load())
        // cursor drained, repeat off
        s.save(snap(a = atEnd).copy(auto = autoSnap(listOf(row, row), next = 2, repeat = "off")), clock.now); assertNull(s.load())
        s.save(snap(a = atEnd).copy(auto = autoSnap(listOf(row, row), next = 2)), clock.now); assertNull(s.load())
        // drained but repeat all
        s.save(snap(a = atEnd).copy(auto = autoSnap(listOf(row, row), next = 2, repeat = "all")), clock.now); assertNotNull(s.load())
        // live deck is B per auto.liveDeck
        s.save(snap(a = deck("a", pos = 0), b = atEnd).copy(auto = autoSnap(listOf(row), next = 1, live = "B")), clock.now)
        assertNotNull(s.load())   // standby A is not at end
        // unknown length is never "at end"
        s.save(snap(a = deck("a", pos = 999_999, len = null)), clock.now); assertNotNull(s.load())
    }

    @Test fun saveDebouncedLandsExactlyOneWriteAfterBurst() {
        val file = tempFile("decks.json")
        val w = VersionedJsonWriter(file)
        val s = store(file, w)
        s.save(snap(xf = 0.0), clock.now)
        val base = w.writeCount
        for (i in 1..60) {
            s.saveDebounced(snap(xf = i / 100.0), clock.now)
            sched.advance(10)   // 60 Hz-ish drag, always inside the 1 s window
        }
        assertEquals(base, w.writeCount)
        sched.advance(300)                 // 900 ms after the first call: timer (armed once) not due
        assertEquals(base, w.writeCount)
        sched.advance(100)
        assertEquals(base + 1, w.writeCount)
        assertEquals(0.6, s.load()!!.crossfader, 1e-9)   // final value landed
        sched.advance(5_000)
        assertEquals(base + 1, w.writeCount)
        assertEquals(0, sched.pending)
    }

    @Test fun structuralSaveSupersedesPendingDebounce() {
        val file = tempFile("decks.json")
        val w = VersionedJsonWriter(file)
        val s = store(file, w)
        s.saveDebounced(snap(xf = 0.1), clock.now)
        s.save(snap(xf = 0.9), clock.now)
        assertEquals(1, w.writeCount)
        sched.advance(5_000)
        assertEquals(1, w.writeCount)
        assertEquals(0.9, s.load()!!.crossfader, 0.0)
    }

    @Test fun updatePositionThrottlesWhileRunningAndWritesOnTransitions() {
        val file = tempFile("decks.json")
        val w = VersionedJsonWriter(file)
        val s = store(file, w)
        s.updatePosition(1, 2, true, clock.now)          // no mix active
        assertEquals(0, w.writeCount)
        s.save(snap(b = deck("b", 0), running = false), clock.now)
        assertEquals(1, w.writeCount)
        clock.now += 1_000; s.updatePosition(10, 20, false, clock.now)   // steady paused
        assertEquals(1, w.writeCount)
        clock.now += 1_000; s.updatePosition(30, 40, true, clock.now)    // pause -> run transition
        assertEquals(2, w.writeCount)
        assertEquals(30, s.load()!!.deckA!!.positionMs)
        clock.now += 4_900; s.updatePosition(50, 60, true, clock.now)    // < 5 s
        assertEquals(2, w.writeCount)
        clock.now += 100; s.updatePosition(70, 80, true, clock.now)      // >= 5 s since last write
        assertEquals(3, w.writeCount)
        assertEquals(80, s.load()!!.deckB!!.positionMs)
        clock.now += 100; s.updatePosition(null, null, false, clock.now) // run -> pause transition
        assertEquals(4, w.writeCount)
        val l = s.load()!!
        assertFalse(l.wasRunning)
        assertEquals(70, l.deckA!!.positionMs)   // null leaves the position
    }

    @Test fun updatePositionDoesNotInventAMissingDeck() {
        val s = store()
        s.save(snap(a = deck(), b = null, running = false), clock.now)
        s.updatePosition(5, 99, true, clock.now)
        assertNull(s.load()!!.deckB)
    }

    @Test fun clearDeletesFileAndForgetsMix() {
        val file = tempFile("decks.json")
        val s = store(file)
        s.save(snap(), clock.now)
        assertTrue(file.exists())
        s.clear()
        assertFalse(file.exists())
        s.updatePosition(1, 1, true, clock.now)   // current == null -> no resurrection
        assertFalse(file.exists())
        s.saveDebounced(snap(), clock.now); s.clear(); sched.advance(5_000)
        assertFalse("clear cancels the pending debounce", file.exists())
    }

    @Test fun staleWriteNeverClobbersNewerOne() {
        val file = tempFile("decks.json")
        val q = QueueExecutor()
        val s = store(file, VersionedJsonWriter(file, q))
        s.save(snap(xf = 0.1), clock.now)     // queued v1
        s.save(snap(xf = 0.2), clock.now)     // queued v2
        s.flush(clock.now + 1)                // inline v3 supersedes the stragglers
        assertEquals(0.2, s.load()!!.crossfader, 0.0)
        q.drain()                              // stragglers execute late
        assertEquals(0.2, s.load()!!.crossfader, 0.0)
    }

    @Test fun clearOrderedAgainstQueuedWrites() {
        val file = tempFile("decks.json")
        val q = QueueExecutor()
        val s = store(file, VersionedJsonWriter(file, q))
        s.save(snap(), clock.now)
        s.clear()
        q.drain()                              // write v1 then delete v2, in order
        assertFalse(file.exists())
        // and a write queued AFTER a flush can't be dropped as stale
        s.save(snap(xf = 0.3), clock.now)
        s.flush(clock.now)
        s.save(snap(xf = 0.4), clock.now)
        q.drain()
        assertEquals(0.4, s.load()!!.crossfader, 0.0)
    }

    @Test fun flushIsSynchronousAndNoOpWithoutMix() {
        val file = tempFile("decks.json")
        val q = QueueExecutor()
        val s = store(file, VersionedJsonWriter(file, q))
        s.flush(clock.now)
        assertFalse(file.exists())
        s.saveDebounced(snap(xf = 0.77), clock.now)
        s.flush(clock.now)
        assertEquals(0.77, s.load()!!.crossfader, 0.0)   // no drain needed
        sched.advance(5_000)
        q.drain()
        assertEquals(0.77, s.load()!!.crossfader, 0.0)
    }

    @Test fun fxSlotSnapshotRoundTripsLiveSlot() {
        val slot = com.levi.pocketdj.mix.model.FXSlot(
            Effect.FLANGER, EffectVariant.CHORUS, true, 0.8,
            com.levi.pocketdj.mix.model.SlotMod.of(ModSource.ENVELOPE, ModRate.HALF, -0.3, ModShape.SAW, 1.25),
        )
        val back = FXSlotSnapshot.from(slot).toSlot()
        assertEquals(slot, back)
    }
}

package com.levi.pocketdj.mix.store

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixSessionStoreTest {
    private val clock = TestClock()
    private val sched = ManualScheduler(clock)
    private var idSeq = 0

    private fun store(file: File = tempFile("sessions.json"), writer: VersionedJsonWriter = VersionedJsonWriter(file)) =
        MixSessionStore(file, writer, clock::read, sched) { "id${++idSeq}".padEnd(12, '0') }

    private fun MixSessionStore.log(
        kind: MixEventKind, deck: String? = "A", param: String? = null, value: Double? = null,
        slot: Int? = null, pos: Int? = null,
    ) = logEvent(kind, deck, null, null, null, null, null, param, value, null, pos, slot)

    private fun diskDoc(f: File) = PdjJson.lenient.decodeFromString<MixSessionsDocument>(f.readText())

    // MixEventKind

    @Test fun knownKindsRoundTripAndUnknownCarriesRaw() {
        for ((raw, kind) in MixEventKind.known) {
            assertEquals(raw, kind.raw)
            assertFalse(kind.isUnknown)
        }
        assertEquals(24, MixEventKind.known.size)
        val future = PdjJson.lenient.decodeFromString<MixSessionEvent>("""{"id":"e1","tMs":5,"kind":"hyperdrive"}""")
        assertEquals(MixEventKind.Unknown("hyperdrive"), future.kind)
        assertTrue(future.kind.isUnknown)
        assertFalse(future.kind.isContinuous)
        assertTrue(PdjJson.lenient.encodeToString(future).contains("\"kind\":\"hyperdrive\""))
    }

    @Test fun continuousKindsAreExactlyTheSliderOnes() {
        val cont = MixEventKind.known.values.filter { it.isContinuous }.map { it.raw }.toSet()
        assertEquals(setOf("tempo", "pitch", "volume", "crossfader", "effectStrength", "stemVolume", "eq"), cont)
    }

    // Coalescing

    @Test fun continuousRunCoalescesIntoOneEventPerBucketKeepingStartTAndFinalValue() {
        val s = store()
        s.log(MixEventKind.Load)               // anchors t0 at now
        clock.now += 1_000
        s.log(MixEventKind.Volume, value = 0.1, pos = 10)
        clock.now += 40; s.log(MixEventKind.Volume, value = 0.2, pos = 20)
        clock.now += 40; s.log(MixEventKind.Volume, value = 0.3, pos = 30)
        val ev = s.events(s.currentId)
        assertEquals(2, ev.size)
        assertEquals(1_000, ev[1].tMs)         // bucket-start tMs
        assertEquals(0.3, ev[1].value!!, 0.0)  // final value
        assertEquals(30, ev[1].posMs)
        clock.now += 40                         // 120 ms after bucket start: new bucket
        s.log(MixEventKind.Volume, value = 0.4)
        val ev2 = s.events(s.currentId)
        assertEquals(3, ev2.size)
        assertEquals(1_120, ev2[2].tMs)
        assertEquals(listOf("e1", "e2", "e3"), ev2.map { it.id })
    }

    @Test fun discreteEventBreaksTheRunAndDifferentKeysDontMerge() {
        val s = store()
        s.log(MixEventKind.Volume, "A", value = 0.1)
        s.log(MixEventKind.Play)
        s.log(MixEventKind.Volume, "A", value = 0.2)            // run broken by the discrete play
        s.log(MixEventKind.Volume, "B", value = 0.3)            // different deck
        s.log(MixEventKind.EffectStrength, "B", "reverb", 0.3, slot = 0)
        s.log(MixEventKind.EffectStrength, "B", "reverb", 0.4, slot = 1)   // different slot
        s.log(MixEventKind.EffectStrength, "B", "filter", 0.4, slot = 1)   // different param
        s.log(MixEventKind.EffectStrength, "B", "filter", 0.5, slot = 1)   // merges
        s.log(MixEventKind.Pause); s.log(MixEventKind.Pause)               // discrete never merge
        val ev = s.events(s.currentId)
        assertEquals(9, ev.size)
        assertEquals(0.5, ev[6].value!!, 0.0)
        assertEquals(0.4, ev[5].value!!, 0.0)
    }

    @Test fun glideRecordsFromToAndRate() {
        val s = store()
        s.logGlide("A", "tempo", "s1", "T", "Ar", 1.0, 1.06, 0.02, 500, slot = null)
        val g = s.events(s.currentId).single()
        assertEquals(MixEventKind.Glide, g.kind)
        assertEquals(1.0, g.fromValue!!, 0.0); assertEquals(1.06, g.value!!, 0.0); assertEquals(0.02, g.rate!!, 0.0)
        assertNull(g.bpm)
    }

    // Persistence timing

    @Test fun discreteSavesImmediatelyContinuousRidesTheDebounce() {
        val f = tempFile("sessions.json"); val w = VersionedJsonWriter(f)
        val s = store(f, w)
        s.log(MixEventKind.Volume, value = 0.1)
        assertEquals(0, w.writeCount)
        for (i in 1..10) { clock.now += 10; s.log(MixEventKind.Volume, value = i / 10.0) }
        assertEquals(0, w.writeCount)
        sched.advance(599); assertEquals(0, w.writeCount)
        sched.advance(1);   assertEquals(1, w.writeCount)
        assertEquals(1.0, diskDoc(f).sessions.single().events.single().value!!, 0.0)
        s.log(MixEventKind.Play)
        assertEquals(2, w.writeCount)
        assertEquals(2, diskDoc(f).sessions.single().events.size)
    }

    @Test fun discreteSaveCancelsPendingDebounce() {
        val f = tempFile("sessions.json"); val w = VersionedJsonWriter(f)
        val s = store(f, w)
        s.log(MixEventKind.Volume, value = 0.1)
        s.log(MixEventKind.Load)
        assertEquals(1, w.writeCount)
        sched.advance(5_000)
        assertEquals(1, w.writeCount)
    }

    // Lifecycle

    @Test fun freshStoreHasSession1AndNoFile() {
        val f = tempFile("sessions.json")
        val s = store(f)
        assertEquals("Session 1", s.currentName)
        assertEquals(1, s.sessions.value.size)
        assertTrue(s.currentId.startsWith("mses_"))
        s.flush()
        assertFalse("virgin flush must not materialize the synced doc", f.exists())
    }

    @Test fun resetOnEmptySessionIsNoOp() {
        val f = tempFile("sessions.json"); val w = VersionedJsonWriter(f)
        val s = store(f, w)
        val id = s.currentId
        s.reset(); s.reset()
        assertEquals(id, s.currentId)
        assertEquals(1, s.sessions.value.size)
        assertEquals(0, w.writeCount)
    }

    @Test fun resetFinalizesAndStartsNextWithMonotonicCounter() {
        val s = store()
        val first = s.currentId
        s.log(MixEventKind.Play)
        clock.now += 2_000
        s.reset()
        assertEquals("Session 2", s.currentName)
        val old = s.session(first)!!
        assertEquals(clock.now.toDouble(), old.endedAt!!, 0.0)
        assertEquals(1, old.events.size)
        s.rename(first, "Warmup")
        s.rename(s.currentId, "  ")                  // blank ignored
        assertEquals("Session 2", s.currentName)
        s.log(MixEventKind.Play); s.reset()
        assertEquals("Session 3", s.currentName)
        s.delete(first)                               // delete a finalized one
        s.log(MixEventKind.Play); s.reset()
        assertEquals("Session 4", s.currentName)      // counter never reuses
        assertNull(s.session(first))
    }

    @Test fun renameCurrentUpdatesNameFlowAndPersists() {
        val f = tempFile("sessions.json")
        val s = store(f)
        s.rename(s.currentId, "  Saturday  ")
        assertEquals("Saturday", s.currentNameFlow.value)
        assertEquals("Saturday", diskDoc(f).sessions.single().name)
        s.rename("nope", "x")
        assertEquals("Saturday", s.currentName)
    }

    @Test fun deletingCurrentReestablishesACurrentSession() {
        val s = store()
        val id = s.currentId
        s.log(MixEventKind.Play)
        s.delete(id)
        assertNotEquals(id, s.currentId)
        assertEquals("Session 2", s.currentName)
        assertEquals(1, s.sessions.value.size)
        s.log(MixEventKind.Pause)                      // recording keeps working
        assertEquals(1, s.events(s.currentId).size)
        assertEquals(0, s.events(s.currentId).first().tMs)
    }

    // Played set

    @Test fun playedSetIsUniqueOrderedAndBumpsRevision() {
        val s = store()
        val r0 = s.playedRevision
        s.notePlayed("")
        assertEquals(r0, s.playedRevision)
        s.notePlayed("a"); s.notePlayed("b"); s.notePlayed("a")
        assertEquals(r0 + 2, s.playedRevision)
        assertEquals(listOf("a", "b"), s.playedSongIds(s.currentId))
        assertTrue(s.hasPlayed("a")); assertFalse(s.hasPlayed("z"))
        s.log(MixEventKind.Play); s.reset()
        assertFalse(s.hasPlayed("a"))                  // new session starts empty
    }

    // Resume / re-anchor

    @Test fun relaunchResumesCurrentSessionAndReanchorsT0() {
        val f = tempFile("sessions.json")
        val a = store(f)
        a.log(MixEventKind.Load)
        clock.now += 5_000
        a.log(MixEventKind.Play)
        a.notePlayed("s1")
        a.flush()
        val id = a.currentId

        clock.now += 3 * 86_400_000L                    // app closed for three days
        val b = store(f)
        assertEquals(id, b.currentId)
        assertEquals("Session 1", b.currentName)
        assertEquals(2, b.events(id).size)
        assertTrue(b.hasPlayed("s1"))
        b.log(MixEventKind.Pause)
        val ev = b.events(id)
        assertEquals(3, ev.size)
        assertEquals("e3", ev[2].id)
        assertEquals(5_000 + MixSessionStore.COALESCE_WINDOW_MS, ev[2].tMs)   // no offline gap embedded
        clock.now += 1_000
        b.log(MixEventKind.Play)
        assertEquals(5_000 + MixSessionStore.COALESCE_WINDOW_MS + 1_000, b.events(id)[3].tMs)
    }

    @Test fun resumedContinuousGestureDoesNotMergeIntoPreRelaunchEvent() {
        val f = tempFile("sessions.json")
        val a = store(f)
        a.log(MixEventKind.Volume, value = 0.5)
        a.flush()
        val b = store(f)
        b.log(MixEventKind.Volume, value = 0.9)
        assertEquals(2, b.events(b.currentId).size)
    }

    @Test fun resumedEmptySessionAnchorsOnFirstActivityLikeAFreshOne() {
        val f = tempFile("sessions.json")
        val a = store(f)
        a.notePlayed("x"); a.flush()   // no events, only played set
        clock.now += 10_000
        val b = store(f)
        b.log(MixEventKind.Play)
        assertEquals(0, b.events(b.currentId).single().tMs)
    }

    // iOS fixture

    @Test fun iosFixtureLoadsAndResumesCurrent() {
        val f = tempFile("sessions.json").also { it.writeText(fixtureText("ios-mix-sessions-v2.json")) }
        val s = store(f)
        assertEquals("mses_AAAA1111BBBB", s.currentId)
        assertEquals("Session 3", s.currentName)
        assertEquals(2, s.sessions.value.size)
        val old = s.session("mses_OLD000000001")!!
        assertEquals("Friday set", old.name)
        assertEquals(3_600_000, old.durationMs)
        assertEquals("rec1", old.recordingsList.single().id)
        assertNull(s.session("mses_AAAA1111BBBB")!!.recordings)
        val cur = s.events(s.currentId)
        assertEquals(4, cur.size)
        assertEquals(MixEventKind.Unknown("warpDrive"), cur[1].kind)
        val glide = cur[2]
        assertEquals(1.0, glide.fromValue!!, 0.0); assertEquals(0.01, glide.rate!!, 0.0); assertNull(glide.slot)
        assertEquals(1, cur[3].slot)
        assertEquals(listOf("sng_18"), s.playedSongIds(s.currentId))
        // counter continues from the document
        s.log(MixEventKind.Play); s.reset()
        assertEquals("Session 4", s.currentName)
    }

    @Test fun futureKindSurvivesLoadAndResave() {
        val f = tempFile("sessions.json").also { it.writeText(fixtureText("ios-mix-sessions-v2.json")) }
        val s = store(f)
        s.log(MixEventKind.Pause)       // forces a save of the whole doc
        val text = f.readText()
        assertTrue(text.contains("\"kind\":\"warpDrive\""))
        assertEquals(MixEventKind.Unknown("warpDrive"), diskDoc(f).sessions.last().events[1].kind)
        assertTrue(text.contains("\"schemaVersion\":2"))
        assertTrue(text.contains("\"wasUserFolder\":false"))
    }

    @Test fun persistenceRoundTripKeepsEveryField() {
        val f = tempFile("sessions.json")
        val s = store(f)
        s.logEvent(MixEventKind.Load, "A", "s1", "Title", "Artist", 123.4, "8A", "p", 1.5, true, 777, 2)
        s.flush()
        val e = diskDoc(f).sessions.single().events.single()
        assertEquals(MixSessionEvent("e1", 0, MixEventKind.Load, "A", "s1", "Title", "Artist", 123.4, "8A", "p", 1.5, true, 777, null, null, 2), e)
    }

    @Test fun corruptFileStartsFreshWithoutThrowing() {
        val f = tempFile("sessions.json").also { it.writeText("{{{") }
        val s = store(f)
        assertEquals("Session 1", s.currentName)
    }

    // Recordings

    @Test fun recordingsAttachRecoverAndRemove() {
        val s = store()
        val id = s.currentId
        assertNull(s.addRecording("missing", "x.m4a", 1.0, 5))
        assertEquals("rec1", s.addRecording(id, "recording-1.m4a", 1.0, 5_000))
        assertEquals("rec2", s.addRecording(id, "recording-2.m4a", 2.0, 6_000))
        assertEquals(listOf("recording-1.m4a", "recording-2.m4a"), s.recordings(id).map { it.fileName })
        assertTrue(s.removeRecording(id, "rec1"))
        assertFalse(s.removeRecording(id, "rec1"))
        s.delete(id)
        s.recoverRecording(id, "Recovered", "recording-2.m4a", 2.0, 6_000)
        val revived = s.session(id)!!
        assertEquals("Recovered", revived.name)
        assertEquals(6_002.0, revived.endedAt!!, 0.0)
        assertEquals(1, revived.recordingsList.size)
        s.recoverRecording(id, "Again", "b.m4a", 3.0, 1)   // existing: just attaches
        assertEquals(2, s.session(id)!!.recordingsList.size)
        assertEquals("Recovered", s.session(id)!!.name)
    }

    // Writer ordering

    @Test fun flushBeatsQueuedStragglersAndClearDeletes() {
        val f = tempFile("sessions.json")
        val q = QueueExecutor()
        val s = store(f, VersionedJsonWriter(f, q))
        s.log(MixEventKind.Play)                        // queued v1
        s.log(MixEventKind.Pause)                       // queued v2
        s.flush()                                       // inline v3
        assertEquals(2, diskDoc(f).sessions.single().events.size)
        q.drain()
        assertEquals(2, diskDoc(f).sessions.single().events.size)
        s.clear()
        q.drain()
        assertFalse(f.exists())
        assertEquals("Session 1", s.currentName)        // counter reset, fresh current
        assertEquals(1, s.sessions.value.size)
        assertTrue(s.events(s.currentId).isEmpty())
    }

    @Test fun reloadFromDiskAdoptsPulledDocUnlessMidTake() {
        val f = tempFile("sessions.json")
        val s = store(f)
        f.writeText(fixtureText("ios-mix-sessions-v2.json"))
        s.reloadFromDisk()
        assertEquals("mses_AAAA1111BBBB", s.currentId)
        // actively recording (has events): a later pull does not clobber
        s.log(MixEventKind.Play)
        val before = s.events(s.currentId).size
        f.writeText("""{"schemaVersion":2,"sessions":[],"counter":0}""")
        s.reloadFromDisk()
        assertEquals(before, s.events(s.currentId).size)
    }

    @Test fun durationAndStartedAtReadFromTheHotBufferForCurrent() {
        val s = store()
        s.log(MixEventKind.Play)
        clock.now += 4_000
        s.log(MixEventKind.Pause)
        assertEquals(4_000, s.durationMs(s.currentId))
        assertEquals(1_800_000_000_000.0, s.startedAt(s.currentId), 0.0)
        assertEquals(s.currentId, s.sessionsNewestFirst.first().id)
    }
}

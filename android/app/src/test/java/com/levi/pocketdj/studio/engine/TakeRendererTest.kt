package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.StudioAudio
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.model.InstrumentKey
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioTake
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class TakeRendererTest {
    @get:Rule val tmp = TemporaryFolder()
    private val sr = 44_100

    private fun ev(on: Int, off: Int, n: Int = 60, v: Int = 90) = StudioNoteEvent(on, off, n, v)

    /** Records what was "encoded"; writes a marker file so the atomic move is observable. */
    private class FakeCodec : StudioCodec {
        val written = ArrayList<PcmBuffer>()
        override fun decode(path: String): PcmBuffer? = null
        override fun decodeNativeRate(path: String): PcmBuffer? = null
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { written.add(pcm); file.writeBytes(ByteArray(8)) }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeBytes(ByteArray(8)) }
    }

    // ---- TakeScore (pure)

    @Test fun actionsPutOffsBeforeOnsAtTheSameInstant() {
        val a = TakeScore.actions(listOf(ev(0, 300), ev(300, 600)))
        assertEquals(listOf(NoteAction(0, true, 60, 90), NoteAction(300, false, 60, 90), NoteAction(300, true, 60, 90), NoteAction(600, false, 60, 90)), a)
    }

    @Test fun actionsClampNegativeOnsetsAndInvertedOffs() {
        val a = TakeScore.actions(listOf(StudioNoteEvent(-50, -10, 62, 80)))
        assertEquals(listOf(NoteAction(0, true, 62, 80), NoteAction(1, false, 62, 80)), a)   // a zero-length note still gets on THEN off
    }

    @Test fun seekChasesNotesAlreadySoundingAndDropsFinishedOnes() {
        val events = listOf(ev(0, 1_000, 60), ev(0, 400, 62), ev(1_200, 1_500, 64))
        val a = TakeScore.actions(events, from = 500)
        assertEquals(listOf(NoteAction(500, true, 60, 90), NoteAction(1_000, false, 60, 90), NoteAction(1_200, true, 64, 90), NoteAction(1_500, false, 64, 90)), a)
        assertEquals(TakeScore.actions(events), TakeScore.actions(events, from = 0))
    }

    @Test fun tempoRescaleScalesEveryNoteMs() {
        val r = TakeScore.rescaled(listOf(ev(100, 200), ev(1_001, 2_003)), oldBpm = 100.0, newBpm = 200.0)
        assertEquals(listOf(ev(50, 100), ev(501, 1_002)), r)                   // twice as fast => half the ms
        assertEquals(listOf(ev(200, 400)), TakeScore.rescaled(listOf(ev(100, 200)), 200.0, 100.0))
        assertEquals(listOf(ev(100, 200)), TakeScore.rescaled(listOf(ev(100, 200)), 0.0, 100.0))   // bad tempo => untouched
        assertEquals(1_002, TakeScore.endMs(listOf(ev(501, 1_002), ev(0, 5))))
    }

    // ---- pump (frame-exact, tail)

    @Test fun pumpFiresEachNoteAtItsExactFrameAndFrameZeroIsMusicalZero() {
        val synth = FakeSynth()
        val pcm = TakeRenderer.pump(synth, TakeScore.actions(listOf(ev(0, 500, 60), ev(250, 1_000, 64))), sr)
        assertEquals(listOf(0L, 11_025L, 22_050L, 44_100L), synth.hits.map { it.frame })
        assertEquals(listOf(60 to true, 64 to true, 60 to false, 64 to false), synth.hits.map { it.note to it.on })
        assertEquals(0.5f, pcm.samples[0], 1e-6f)                              // sounding from frame 0, no head latency
    }

    @Test fun pumpDrainsTheReleaseTailThenStopsAtTheFloor() {
        val synth = FakeSynth()
        val pcm = TakeRenderer.pump(synth, TakeScore.actions(listOf(ev(0, 1_000))), sr)
        val musical = 44_100
        assertTrue("tail rings past the last note-off", pcm.frames > musical)
        assertTrue("but ends at the -60 dB floor, well under the 3 s cap", pcm.frames < musical + 3 * sr)
        val last = pcm.samples.copyOfRange((pcm.frames - 512) * 2, pcm.frames * 2)
        assertTrue(StudioAudio.isBelowFloor(last, 0, last.size))
        assertEquals(2, pcm.channels); assertEquals(sr, pcm.sampleRate)
    }

    @Test fun pumpTailIsCappedAtThreeSecondsForAnEndlessVoice() {
        val endless = object : SynthVoice by FakeSynth() {
            override fun render(out: FloatArray, frames: Int, mix: Boolean) { for (i in 0 until frames * 2) out[i] = 0.5f }
        }
        val pcm = TakeRenderer.pump(endless, TakeScore.actions(listOf(ev(0, 100))), sr)
        assertEquals(Math.round(0.1 * sr).toInt() + 3 * sr, pcm.frames)
    }

    @Test fun clickIsNotPartOfTheRenderGraph() {
        // The renderer only ever touches the synth: with a click-free fake the output is exactly the synth's output.
        val synth = FakeSynth()
        val pcm = TakeRenderer.pump(synth, TakeScore.actions(listOf(ev(0, 200))), sr)
        assertTrue(pcm.samples.all { it in 0f..0.5f })                         // DC-held synth only; a 1.6 kHz sine tick would swing negative
    }

    // ---- render to the store

    private fun env() = TestEnv(tmp.newFolder("studio"))

    @Test fun renderFilesTheCacheAtTheCurrentRevisionAndHonoursEditedEvents() = runBlocking {
        val env = env(); val store = env.store(); val codec = FakeCodec()
        val synths = ArrayList<FakeSynth>()
        val r = TakeRenderer(env.roots, store, { FakeSynth().also { synths.add(it) } }, codec, Dispatchers.Unconfined)
        store.addTake(StudioTake("tk_a", "Riff", fileName = "take-tk_a.m4a", bpm = 120.0, events = listOf(ev(0, 100)), durationMs = 100))
        store.setTakeEvents("tk_a", listOf(ev(0, 1_000)))                       // an edit bumps renderRevision
        val take = store.take("tk_a")!!
        val bank = File("/bank.sf2")
        val file = r.render(take) { bank }
        assertNotNull(file)
        assertEquals(StudioFolders.renderedTakeFileName("tk_a", take.renderRevision), file!!.name)
        assertTrue(file.isFile)
        val saved = store.take("tk_a")!!
        assertTrue(saved.isRenderFresh)
        assertEquals(file.name, saved.renderedFileName)
        assertEquals(1_000 / 1000.0, codec.written.single().frames.toDouble() / sr, 0.5)    // rendered the EDITED score (1 s), not the raw 0.1 s
        assertTrue(synths.all { it.closed })
        assertEquals(0, synths.single().program)                                // piano GM program
    }

    @Test fun tempoChangeInvalidatesTheRenderAndRerendersWithRescaledNotes() = runBlocking {
        val env = env(); val store = env.store(); val codec = FakeCodec()
        val r = TakeRenderer(env.roots, store, { FakeSynth() }, codec, Dispatchers.Unconfined)
        store.addTake(StudioTake("tk_a", "Riff", fileName = "f", bpm = 100.0, events = listOf(ev(0, 2_000)), durationMs = 2_000))
        val f1 = r.render(store.take("tk_a")!!) { File("/b.sf2") }!!
        assertTrue(store.take("tk_a")!!.isRenderFresh)
        store.setTakeTempo("tk_a", 200.0)                                       // twice as fast
        val after = store.take("tk_a")!!
        assertFalse(after.isRenderFresh)
        assertNull(after.renderedFileName)
        assertFalse("old cache file removed", f1.exists())
        assertEquals(1_000, after.events.single().offMs)
        val f2 = r.render(after) { File("/b.sf2") }!!
        assertTrue(f2.name != f1.name)
        assertTrue(store.take("tk_a")!!.isRenderFresh)
        val dur = codec.written.last().frames.toDouble() / sr
        assertTrue("re-rendered at the new tempo (about 1 s + tail), was $dur", dur in 0.9..1.0 + 3.0)
        assertTrue(codec.written.first().frames > codec.written.last().frames)
    }

    @Test fun multiStaffTakeIsMixedSummedAndClamped() = runBlocking {
        val env = env(); val store = env.store(); val codec = FakeCodec()
        val programs = ArrayList<Int>()
        val r = TakeRenderer(env.roots, store, {
            val inner = FakeSynth()
            object : SynthVoice by inner {
                override fun setPreset(bank: Int, program: Int): Boolean { programs.add(program); return inner.setPreset(bank, program) }
            }
        }, codec, Dispatchers.Unconfined)
        store.addTake(StudioTake("tk_a", "Duo", fileName = "f", instrument = InstrumentKey.PIANO, events = listOf(ev(0, 300))))
        store.addOverdubStaff("tk_a", InstrumentKey.VIOLIN, listOf(ev(0, 300)))
        val banks = mutableListOf<InstrumentKey>()
        r.render(store.take("tk_a")!!) { banks.add(it); File("/b.sf2") }
        assertEquals(listOf(InstrumentKey.PIANO, InstrumentKey.VIOLIN), banks)  // each staff voiced from ITS instrument's bank
        assertEquals(listOf(0, 40), programs)
        val out = codec.written.single()
        assertEquals(1.0f, out.samples[0], 1e-6f)                               // 0.5 + 0.5, within the clamp
        assertTrue(out.samples.all { it in -1f..1f })
    }

    @Test fun missingBankAndEmptyTakeFailCleanlyWithoutAFile() = runBlocking {
        val env = env(); val store = env.store()
        val r = TakeRenderer(env.roots, store, { FakeSynth() }, FakeCodec(), Dispatchers.Unconfined)
        store.addTake(StudioTake("tk_a", "T", fileName = "f", events = listOf(ev(0, 10))))
        try { r.render(store.take("tk_a")!!) { null }; fail() } catch (e: TakeRenderException.BankMissing) { assertEquals(InstrumentKey.PIANO, e.instrument) }
        store.addTake(StudioTake("tk_b", "E", fileName = "f"))
        try { r.render(store.take("tk_b")!!) { File("/b.sf2") }; fail() } catch (e: TakeRenderException.EmptyTake) { }
        val bad = TakeRenderer(env.roots, store, { FakeSynth(loadOk = false) }, FakeCodec(), Dispatchers.Unconfined)
        try { bad.renderStaffPcm(listOf(ev(0, 10)), File("/b.sf2"), 0); fail() } catch (e: TakeRenderException.BankLoadFailed) { }
        assertTrue(env.roots.appDir(StudioFamily.TAKES).list().isEmpty())
    }

    @Test fun staleRenderIsDroppedWhenAnEditLandsMidRender() = runBlocking {
        val env = env(); val store = env.store()
        lateinit var r: TakeRenderer
        val codec = object : StudioCodec by FakeCodec() {
            override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeBytes(ByteArray(8)); store.setTakeEvents("tk_a", listOf(ev(0, 50))) }   // edit during encode
        }
        r = TakeRenderer(env.roots, store, { FakeSynth() }, codec, Dispatchers.Unconfined)
        store.addTake(StudioTake("tk_a", "T", fileName = "f", events = listOf(ev(0, 1_000))))
        assertNull(r.render(store.take("tk_a")!!) { File("/b.sf2") })
        assertFalse(store.take("tk_a")!!.isRenderFresh)
        assertTrue("stale file deleted", env.roots.appDir(StudioFamily.TAKES).list().isEmpty())
    }

    @Test fun renderRawWritesTheTakeFileAndReportsDuration() = runBlocking {
        val env = env(); val store = env.store(); val codec = FakeCodec()
        val r = TakeRenderer(env.roots, store, { FakeSynth() }, codec, Dispatchers.Unconfined)
        val ms = r.renderRaw("tk_z", listOf(ev(0, 500)), InstrumentKey.HARP, File("/b.sf2"), "take-tk_z.m4a")
        assertTrue(ms >= 500)
        assertTrue(File(File(tmp.root, "studio/app/takes"), "take-tk_z.m4a").isFile)
    }
}

package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSlice
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SliceMathTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun sl(slot: Int, start: Int) = StudioSlice("slc_$slot", "smp_a", slot, start)

    @Test fun padWindowEndsAtTheNextStartByTimeNotBySlot() {
        // slot 0 starts LATER than slot 1: ordering is by time
        val s = listOf(sl(0, 3000), sl(1, 1000), sl(2, 5000))
        assertEquals(3000 to 5000, SliceMath.window(s, 0, 8000))
        assertEquals(1000 to 3000, SliceMath.window(s, 1, 8000))
        assertEquals(5000 to 8000, SliceMath.window(s, 2, 8000))   // last pad runs to the sample's end
        assertNull(SliceMath.window(s, 5, 8000))                    // missing pad
    }

    @Test fun emptyWindowIsNull() {
        assertNull(SliceMath.window(listOf(sl(0, 9000)), 0, 8000))  // marker dragged past the end
        assertNull(SliceMath.window(listOf(sl(0, 8000)), 0, 8000))
    }

    @Test fun evenChopOfEightOnAFourBeatGridMergesCoincidentSnaps() {
        // 120 BPM, 2 s = 4 beats (0, 500, 1000, 1500); eight even targets 0,250,...,1750 snap onto 4 beats
        val starts = SliceMath.autoStarts(8, StudioGrid(120.0), 2000)
        assertEquals(listOf(0, 500, 1000, 1500), starts)
    }

    @Test fun evenChopWithoutAGridIsATimeChopAndCapsAtEight() {
        assertEquals(listOf(0, 1000, 2000, 3000), SliceMath.autoStarts(4, null, 4000))
        assertEquals(8, SliceMath.autoStarts(20, null, 8000).size)
        assertEquals(listOf(0), SliceMath.autoStarts(4, null, 0))
    }

    @Test fun chopSnapsToMeasuredBeats() {
        val g = StudioGrid(120.0, 0, listOf(0, 520, 990, 1530))
        assertEquals(listOf(0, 990), SliceMath.autoStarts(2, g, 2000))
    }

    @Test fun markerDragClampsToTheSample() {
        assertEquals(0, SliceMath.msAt(-0.5f, 4000))
        assertEquals(4000, SliceMath.msAt(2f, 4000))
        assertEquals(1000, SliceMath.msAt(0.25f, 4000))
    }

    @Test fun addedPadLandsProportionallyToItsSlot() {
        assertEquals(0, SliceMath.defaultAddStart(8000, 0))
        assertEquals(3000, SliceMath.defaultAddStart(8000, 3))
        assertEquals(0, SliceMath.defaultAddStart(-5, 4))
    }

    @Test fun labelsColorsAndRows() {
        assertEquals("Pad 3", SliceMath.padLabel(sl(2, 0)))
        assertEquals("Snare", SliceMath.padLabel(StudioSlice("x", "s", 2, 0, "Snare")))
        assertEquals("Kick · pad 2", SliceMath.bakedName("Kick", 1))
        assertEquals("Kick slices", SliceMath.patternName("Kick"))
        assertEquals(SliceMath.slotColor(0), SliceMath.slotColor(8))
        assertEquals(8, SliceMath.SLOT_COLORS.toSet().size)
        assertEquals(listOf(1000, 3000, 5000), SliceMath.timeOrdered(listOf(sl(0, 3000), sl(1, 1000), sl(2, 5000))).map { it.startMs })
        val rows = SliceMath.rowsFor(listOf("smp_1", "smp_2"))
        assertEquals(listOf("smp_1", "smp_2"), rows.map { it.targetId })
        assertEquals(16, rows[0].steps.size)
    }

    @Test fun padGridKeepsPhaseRelativeToThePadStart() {
        val g = SliceMath.padGrid(StudioGrid(120.0, 0, listOf(0, 500, 1000, 1500)), 500, 1000)!!
        assertEquals(listOf(0, 500), g.beatsMs)
        assertNull(SliceMath.padGrid(null, 500, 1000))
    }

    // ---- SliceBaker ----

    private class Codec(val src: PcmBuffer) : StudioCodec {
        val carves = mutableListOf<Int>()
        override fun decode(path: String) = src
        override fun decodeNativeRate(path: String) = src
        override fun decodeRange(path: String, startMs: Int, lenMs: Int): PcmBuffer {
            carves.add(startMs)
            return PcmBuffer(44_100, 2, FloatArray((lenMs * 44.1).toInt() * 2) { 0.1f })
        }
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText("m4a") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    @Test fun bakingPadsNeverTouchesTheTrimWindowAndSendsOnePattern() = runBlocking {
        val env = TestEnv(tmp.newFolder())
        val store = env.store()
        val codec = Codec(PcmBuffer(44_100, 2, FloatArray(44_100 * 2)))
        val render = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined) { }
        val file = env.write(StudioFamily.SAMPLES, "smp_a")
        val original = store.addSample(StudioSample("smp_a", "Kick", file, durationMs = 4000, grid = StudioGrid(120.0)))
        val edit = original.edit.copy(trimStartMs = 100, trimEndMs = 3000)
        store.updateSampleEdit("smp_a", edit)
        store.setSlices("smp_a", listOf(0, 1000, 2500))
        val baker = SliceBaker(env.roots, store, render, { env.appFile(StudioFamily.SAMPLES, it.fileName) }, now = { 7.0 })

        val id = baker.bakePad("smp_a", 1)
        assertNotNull(id)
        val baked = store.sample(id!!)!!
        assertEquals("Kick · pad 2", baked.name)
        assertEquals(1500, baked.durationMs)                // [1000, 2500)
        assertTrue(baked.edit.isNeutral)
        assertEquals(edit.trimStartMs, store.sample("smp_a")!!.edit.trimStartMs)   // parent edit untouched
        assertEquals(edit.trimEndMs, store.sample("smp_a")!!.edit.trimEndMs)

        val res = baker.sendToSequencer("smp_a")!!
        assertEquals(3, res.baked)
        val p = store.pattern(res.patternId)!!
        assertEquals("Kick slices", p.name)
        assertEquals(3, p.rows.size)
        assertEquals(120.0, p.bpm, 0.0)
        assertTrue(p.rows.all { store.sample(it.targetId) != null })

        assertNull(baker.bakePad("smp_a", 6))               // missing pad
        assertNull(baker.sendToSequencer("smp_none"))
    }
}

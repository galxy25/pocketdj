package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.demux.BeatDetect
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioTrack
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class ArrangerGridAnalyzerTest {
    @Volatile private var arr = StudioArrangement(
        "A", "A", listOf(
            StudioTrack("t1", "t1", listOf(StudioClip("c1", "c1", "f1"), StudioClip("c2", "c2", "f2"))),
            StudioTrack("t2", "t2", listOf(StudioClip("c3", "c3", "f3", grid = StudioGrid(100.0)))),
        ),
    )
    private val writes = ArrayList<Triple<String, String, StudioGrid>>()

    @Synchronized private fun setGrid(a: String, t: String, c: String, g: StudioGrid) {
        writes += Triple(t, c, g)
        arr = arr.copy(tracks = arr.tracks.map { tr -> if (tr.id != t) tr else tr.copy(clips = tr.clips.map { if (it.id == c) it.copy(grid = g) else it }) })
    }

    private fun analyzer(decode: suspend (String) -> PcmBuffer?, detect: (PcmBuffer) -> StudioGrid?) =
        ArrangerGridAnalyzer({ arr.takeIf { _ -> true } }, ::setGrid, decode, detect, Dispatchers.Unconfined)

    private val pcm = PcmBuffer(44_100, 2, FloatArray(8))

    @Test fun onlyUnanalyzedClipsAreAnalyzedAndGridsAreCached() = runBlocking {
        val decoded = ArrayList<String>()
        val a = analyzer({ decoded += it; pcm }, { StudioGrid(128.0, 40) })
        assertFalse(arr.beatGridReady)
        assertEquals(2, a.ensureGrids("A"))
        assertEquals(listOf("f1", "f2"), decoded)               // c3 already had a grid
        assertTrue(arr.beatGridReady)
        assertEquals(128.0, arr.tracks[0].clips[0].grid!!.bpm, 0.0)
        assertEquals(0, a.ensureGrids("A"))                      // idempotent
        assertEquals(2, decoded.size)
    }

    @Test fun failedDetectionAndUnresolvableFilesStoreTheZeroBpmSentinelSoTheGateOpens() = runBlocking {
        val a = analyzer({ if (it == "f2") null else pcm }, { null })
        a.ensureGrids("A")
        assertTrue(arr.beatGridReady)
        assertEquals(0.0, arr.tracks[0].clips[0].grid!!.bpm, 0.0)   // detection failed -> sentinel
        assertEquals(0.0, arr.tracks[0].clips[1].grid!!.bpm, 0.0)   // unresolvable file -> sentinel
        assertEquals(100.0, arr.tracks[1].clips[0].grid!!.bpm, 0.0) // c3's real grid is untouched
    }

    @Test fun sentinelNeverWarpsButARealGridDoes() {
        assertFalse(ArrangerGridAnalyzer.isUsable(ArrangerGridAnalyzer.UNANALYZABLE))
        assertTrue(ArrangerGridAnalyzer.isUsable(StudioGrid(90.0)))
        assertEquals(1.0, ArrangerBeatMatch.rate(ArrangerGridAnalyzer.UNANALYZABLE.bpm, 120.0, 1.0, true), 0.0)
    }

    @Test fun aClipDeletedMidAnalysisIsNeverResurrected() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val a = ArrangerGridAnalyzer({ arr }, ::setGrid, { gate.await(); pcm }, { StudioGrid(120.0) }, Dispatchers.Unconfined)
        val job = async(Dispatchers.Default) { a.ensureGrids("A") }
        while (!gate.isActive) Thread.sleep(1)
        // c1 and c2 are deleted while c1 is being analyzed (a scissor commit / track delete).
        arr = arr.copy(tracks = arr.tracks.map { t -> t.copy(clips = t.clips.filter { it.id == "c3" }) })
        gate.complete(Unit)
        assertEquals(0, job.await())
        assertTrue(writes.isEmpty())
    }

    @Test fun overlappingRunsAnalyzeEachClipOnce() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val detects = AtomicInteger(0)
        val a = ArrangerGridAnalyzer({ arr }, ::setGrid, { gate.await(); pcm }, { detects.incrementAndGet(); StudioGrid(120.0) }, Dispatchers.Unconfined)
        val r1 = async(Dispatchers.Default) { a.ensureGrids("A") }
        val r2 = async(Dispatchers.Default) { a.ensureGrids("A") }
        Thread.sleep(50)
        gate.complete(Unit)
        r1.await(); r2.await()
        assertEquals(2, detects.get())
        assertEquals(2, writes.size)
    }

    @Test fun missingArrangementIsANoOp() = runBlocking {
        val a = ArrangerGridAnalyzer({ null }, ::setGrid, { pcm }, { null })
        assertEquals(0, a.ensureGrids("nope"))
    }

    @Test fun underConstructionMessageOnlyWhileSomeClipLacksAGrid() {
        assertNotNull(ArrangerGridAnalyzer.underConstructionMessage(arr))
        val ready = arr.copy(tracks = arr.tracks.map { t -> t.copy(clips = t.clips.map { it.copy(grid = StudioGrid(120.0)) }) })
        assertNull(ArrangerGridAnalyzer.underConstructionMessage(ready))
        assertNull(ArrangerGridAnalyzer.underConstructionMessage(StudioArrangement("E", "E")))
    }

    @Test fun detectsARealPulseTrainAtItsTempo() {
        // 120 bpm click train, 12 s: the production BeatDetect must find ~120 so the gate produces a usable grid.
        val sr = 44_100; val n = sr * 12
        val s = FloatArray(n * 2)
        var t = 0.0
        while (t < 12.0) {
            val i0 = (t * sr).toInt()
            for (k in 0 until 600) if (i0 + k < n) { val v = (Math.exp(-k / 120.0) * Math.sin(k * 0.35)).toFloat(); s[2 * (i0 + k)] = v; s[2 * (i0 + k) + 1] = v }
            t += 0.5
        }
        val g = BeatDetect.detectGrid(PcmBuffer(sr, 2, s))
        assertNotNull(g)
        assertTrue("bpm ${g!!.bpm}", Math.abs(g.bpm - 120.0) < 3.0)
    }
}

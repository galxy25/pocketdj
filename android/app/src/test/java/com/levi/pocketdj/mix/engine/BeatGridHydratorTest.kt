package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.data.burns.BeatGridSidecar
import com.levi.pocketdj.mix.model.Deck
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BeatGridHydratorTest {
    private val A = Deck.A

    private class Rig(local: Map<String, BeatGridSidecar> = emptyMap(), gate: CompletableDeferred<BeatGridSidecar?>? = null) {
        val h = EngineHarness()
        var downloads = 0
        val remote = HashMap<String, BeatGridSidecar>()
        var gate: CompletableDeferred<BeatGridSidecar?>? = gate
        val fake = FakeStems(h.sr)
        val extras = MixDeckExtras(
            h.engine, fake, { v -> h.voices += v; AutoCloseable { h.voices -= v } },
            CoroutineScope(Dispatchers.Unconfined),
            localGrid = { local[it] },
            downloadGrid = { id -> downloads++; this.gate?.await() ?: remote[id] },
        )
        val A = Deck.A
        val hydrator get() = extras.hydrator
        fun load(id: String, bpm: Double? = 120.0) { h.engine.load(h.addSong(id, 20.0, gridBpm = bpm, firstDownbeatMs = 0), A) }
        val beats get() = h.engine.deckState(A).loaded?.beatsMs
    }

    private fun sidecar(offsetMs: Int = 0, n: Int = 40) = BeatGridSidecar(
        beatGridBpm = 120.0, firstDownbeatMs = offsetMs, steady = true,
        beatsMs = (0 until n).map { offsetMs + it * 500 }, downbeatsMs = (0 until n step 4).map { offsetMs + it * 500 },
    )

    @Test fun aBurnedLocalSidecarAttachesOnLoadWithoutTheNetworkAndWithThePulseOff() {
        val r = Rig(local = mapOf("s" to sidecar(100)))
        assertFalse(r.hydrator.beatPulseEnabled)
        r.load("s")
        assertEquals((0 until 40).map { 100 + it * 500 }, r.beats)
        assertEquals((0 until 40 step 4).map { 100 + it * 500 }, r.h.engine.deckState(A).loaded!!.downbeatsMs)
        assertEquals(0, r.downloads)
        assertTrue(r.h.diags.any { it.contains("beatgrid hydrate") && it.contains("local") })
    }

    @Test fun noSidecarAndThePulseOffNeverDownloads() {
        val r = Rig()
        r.remote["s"] = sidecar()
        r.load("s")
        r.hydrator.hydrate(A, "s")
        assertEquals(0, r.downloads)
        assertNull(r.beats)
    }

    @Test fun enablingThePulseHydratesWhatIsAlreadyLoadedAndPatchesOnce() {
        val r = Rig(); r.remote["s"] = sidecar(250)
        r.load("s")
        var hydrated = 0
        r.hydrator.onHydrated = { hydrated++ }
        r.hydrator.setBeatPulseEnabled(true)
        assertEquals(1, r.downloads)
        assertEquals(250, r.beats!!.first())
        assertEquals(1, hydrated)
        // already hydrated: a second request is a no-op
        r.hydrator.hydrate(A, "s")
        r.hydrator.setBeatPulseEnabled(true)
        assertEquals(1, r.downloads)
    }

    @Test fun aLoadWithThePulseOnDownloadsInTheBackground() {
        val gate = CompletableDeferred<BeatGridSidecar?>()
        val r = Rig(gate = gate)
        r.hydrator.setBeatPulseEnabled(true)
        r.load("s")
        assertEquals(1, r.downloads)
        assertNull("not patched until the download lands", r.beats)
        gate.complete(sidecar(0))
        assertEquals(40, r.beats!!.size)
    }

    @Test fun aDeckThatMovedOnWhileTheDownloadRanIsLeftAlone() {
        val gate = CompletableDeferred<BeatGridSidecar?>()
        val r = Rig(gate = gate)
        r.hydrator.setBeatPulseEnabled(true)
        r.h.engine.onStemsReset = { r.extras.stems.reset(it) }   // no job cancel: only the songId guard protects the new track
        r.load("one")
        r.load("two")
        gate.complete(sidecar(777))
        assertEquals("two", r.h.engine.deckState(A).loaded!!.songId)
        assertNull("the late grid for the previous track must not patch the new one", r.beats)
    }

    @Test fun anEmptyOrMissingDownloadPatchesNothing() {
        val r = Rig()
        r.hydrator.setBeatPulseEnabled(true)
        r.load("s")
        assertEquals(1, r.downloads)
        assertNull(r.beats)
        r.remote["s"] = BeatGridSidecar(beatsMs = emptyList())
        r.hydrator.hydrate(A, "s")
        assertNull(r.beats)
    }

    @Test fun engagingALoopForcesTheGridEvenWithThePulseOff() {
        val r = Rig(); r.remote["s"] = sidecar(0)
        r.load("s")
        r.h.engine.seek(A, 3.3)
        r.extras.loops.setLoop(A, true)
        assertEquals("beats are needed NOW, whether or not the pulse visual is on", 1, r.downloads)
        assertNotNull(r.beats)
    }

    @Test fun anAsyncGridReResolvesALoopArmedOnSynthesizedBeats() {
        val gate = CompletableDeferred<BeatGridSidecar?>()
        val r = Rig(gate = gate)
        r.load("s", bpm = 120.0)
        r.h.engine.seek(A, 3.3)
        r.extras.loops.setLoop(A, true)   // armed on the synthesized 0.5 s lattice
        assertEquals(3.0 to 4.0, r.extras.loops.loopWindow(A))
        // the real grid sits 130 ms late: the loop snaps onto it, keeping the playhead in place
        gate.complete(sidecar(130))
        val w = r.extras.loops.loopWindow(A)!!
        assertEquals(3.13, w.first, 1e-9); assertEquals(4.13, w.second, 1e-9)
        assertEquals(3.3, r.h.engine.position(A), 1e-9)
    }

    @Test fun cancellingADeckDropsItsPendingDownload() {
        val gate = CompletableDeferred<BeatGridSidecar?>()
        val r = Rig(gate = gate)
        r.hydrator.setBeatPulseEnabled(true)
        r.load("s")
        r.hydrator.cancel(A)
        gate.complete(sidecar(0))
        assertNull(r.beats)
    }
}

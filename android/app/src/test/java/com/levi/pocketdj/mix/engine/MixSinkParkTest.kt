package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.audio.core.AudioDiag
import com.levi.pocketdj.audio.core.BlockRenderer
import com.levi.pocketdj.audio.core.OboeBackend
import com.levi.pocketdj.audio.core.OboeSink
import com.levi.pocketdj.studio.audio.StudioOutputs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Final review: the Mix sink must be parkable (pauseEngineIfIdle) and restartable on the next play. */
class MixSinkParkTest {
    private fun rig(): EngineHarness {
        val h = EngineHarness()
        h.engine.load(h.addSong("s", isCut = true, source = { SyntheticPcmSource.counter(44_100L * 10) }), Deck.A)
        h.engine.play(Deck.A)
        return h
    }

    @Test fun idleParksSinkAndNextPlayRestartsIt() {
        val h = rig()
        assertTrue(h.renderer.isRendering)
        h.engine.pauseBoth()
        h.engine.pauseEngineIfIdle()
        assertFalse(h.renderer.isRendering)
        h.engine.play(Deck.A)
        assertTrue(h.renderer.isRendering)
    }

    @Test fun neverParksWhileAudioWantedOrRecording() {
        val h = rig()
        h.engine.pauseEngineIfIdle()
        assertTrue("playing deck keeps the sink", h.renderer.isRendering)
        h.engine.pauseBoth()
        h.engine.keepEngineAlive = { true }
        h.engine.pauseEngineIfIdle()
        assertTrue("an open take keeps the sink", h.renderer.isRendering)
    }

    private class FakeOboe(val failOpen: Boolean = false, val gate: java.util.concurrent.CountDownLatch? = null) : OboeBackend {
        @Volatile var gone = false
        @Volatile var opens = 0
        @Volatile var written = 0
        @Volatile var closed = 0
        @Volatile var released = 0
        override fun open(): Boolean {
            opens++
            if (opens > 1) gate?.await()
            if (failOpen) return false
            gone = false; return true
        }
        override fun close() { closed++ }
        override fun release() { released++ }
        override fun write(buf: FloatArray, frames: Int): Int { written += frames; return frames }
        override fun freeFrames() = 4096
        override fun bufferedFrames() = 0
        override fun underruns() = 0L
        override fun disconnected() = gone
        override fun streamLatencyFrames() = 100
    }

    private fun waitFor(cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + 3000
        while (System.currentTimeMillis() < end) { if (cond()) return true; Thread.sleep(2) }
        return cond()
    }

    /** Park while a failed rebuild left wasDisconnected + a backoff pending; the NEXT life must behave as fresh. */
    @Test fun oboeSinkParkedWhileDisconnectedRestartsClean() {
        AudioDiag.emit = { }
        val backends = mutableListOf<FakeOboe>()
        var n = 0
        val sink = OboeSink(44_100, 512, spawnFeeder = false) {
            // Backend 0 opens fine at start but its rebuild FAILS (stale backoff); later ones are healthy.
            val b = if (n++ == 0) FakeOboe(failOpen = false) else FakeOboe()
            backends += b; b
        }
        val events = mutableListOf<Boolean>()
        sink.onRoutingChanged = { events += it }
        val r = BlockRenderer { _, _ -> }
        sink.start(r)
        // make backend 0's rebuild fail: swap its open result by marking gone and failing via a failing wrapper
        val b0 = backends[0]
        b0.gone = true
        val failing = object : OboeBackend by b0 { override fun open() = false; override fun disconnected() = true }
        sink.attachForTest(failing, r)
        sink.pumpOnce(1000)                      // disconnect seen, rebuild fails -> wasDisconnected + nextRebuildAt=1020
        assertEquals(listOf(false), events)
        sink.stop()                              // engine parks the idle sink
        assertFalse(sink.isRendering)
        sink.start(r)                            // next play
        assertEquals(2, backends.size)
        assertTrue(sink.isRendering)
        val b1 = backends[1]
        b1.gone = true                           // a second route change, inside the stale 20 ms backoff window
        sink.pumpOnce(1001)
        assertEquals("second disconnect must be reported", listOf(false, false, true), events)
        assertEquals("rebuild attempted immediately (no stale backoff)", 2, b1.opens)
        sink.stop()
    }

    /** stop() runs on main: it must not wait out a feeder blocked in a native open(), and must not free its handle under it. */
    @Test fun stopIsBoundedAndDefersCloseWhileFeederBlockedInOpen() {
        AudioDiag.emit = { }
        val gate = java.util.concurrent.CountDownLatch(1)
        val b = FakeOboe(gate = gate)
        val sink = OboeSink(44_100, 512) { b }
        sink.start(BlockRenderer { _, _ -> })
        assertTrue(waitFor { b.written > 0 })
        b.gone = true                            // feeder enters open() #2 and blocks on the gate
        assertTrue(waitFor { b.opens == 2 })
        val t0 = System.nanoTime()
        sink.stop()
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("stop took ${ms}ms", ms < 1500)
        assertEquals("handle must not be freed while the feeder is inside open()", 0, b.closed)
        gate.countDown()
        assertTrue("feeder frees the handle on exit", waitFor { b.closed >= 1 && b.released >= 1 })
    }

    @Test fun mixSinkChoiceIsOboeOnDeviceAudioTrackOnEmulator() {
        assertEquals(StudioOutputs.Backend.OBOE, StudioOutputs.chooseBackend(nativeAvailable = true, isEmulator = false))
        assertEquals(StudioOutputs.Backend.AUDIO_TRACK, StudioOutputs.chooseBackend(nativeAvailable = true, isEmulator = true))
        assertEquals(StudioOutputs.Backend.AUDIO_TRACK, StudioOutputs.chooseBackend(nativeAvailable = false, isEmulator = false))
    }
}

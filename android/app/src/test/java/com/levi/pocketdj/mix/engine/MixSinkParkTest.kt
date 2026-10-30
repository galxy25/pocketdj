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

    private class FakeOboe : OboeBackend {
        @Volatile var gone = false
        @Volatile var opens = 0
        @Volatile var written = 0
        override fun open(): Boolean { opens++; gone = false; return true }
        override fun close() {}
        override fun release() {}
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

    @Test fun oboeSinkParkedWhileDisconnectedRestartsClean() {
        AudioDiag.emit = { }
        val backends = mutableListOf<FakeOboe>()
        val sink = OboeSink(44_100, 512) { FakeOboe().also { backends += it } }
        val r = BlockRenderer { _, _ -> }
        try {
            sink.start(r)
            assertTrue(waitFor { sink.isRendering && backends[0].written > 0 })
            backends[0].gone = true   // route change, then the engine parks the idle sink before the rebuild lands
            sink.stop()
            assertFalse(sink.isRendering)
            sink.start(r)             // next play after the park
            assertEquals(2, backends.size)
            assertTrue("fresh stream renders, no stale disconnect state", sink.isRendering)
            assertTrue(waitFor { backends[1].written > 0 })
        } finally { sink.stop() }
    }

    @Test fun mixSinkChoiceIsOboeOnDeviceAudioTrackOnEmulator() {
        assertEquals(StudioOutputs.Backend.OBOE, StudioOutputs.chooseBackend(nativeAvailable = true, isEmulator = false))
        assertEquals(StudioOutputs.Backend.AUDIO_TRACK, StudioOutputs.chooseBackend(nativeAvailable = true, isEmulator = true))
        assertEquals(StudioOutputs.Backend.AUDIO_TRACK, StudioOutputs.chooseBackend(nativeAvailable = false, isEmulator = false))
    }
}

package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.mix.model.Deck
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
}

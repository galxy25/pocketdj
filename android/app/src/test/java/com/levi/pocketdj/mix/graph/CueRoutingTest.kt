package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.audio.core.SyntheticPcmSource
import com.levi.pocketdj.mix.graph.GraphHarness.Companion.rms
import com.levi.pocketdj.mix.model.Deck
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of MixEngineTests.testCueRoutingIsPreFaderPFLAndPansToTheCueChannel + the rendered behaviour. */
class CueRoutingTest {
    @Test fun routingSnapshotIsPreFaderPflAndPansToTheCueChannel() {
        val c = ParamsComposer()
        c.setCueOnRight(true)
        c.setCrossfader(0f) // full A on main, B's main send ~0

        var a = c.current.routing(Deck.A); var b = c.current.routing(Deck.B)
        assertEquals(0f, a.cueVol, 1e-6f); assertEquals(0f, b.cueVol, 1e-6f)
        assertEquals(0f, a.mainPan, 1e-6f); assertEquals(0f, b.mainPan, 1e-6f)
        assertEquals(1f, a.mainVol, 1e-5f); assertEquals(0f, b.mainVol, 1e-5f)

        c.setCued(Deck.B, true)
        b = c.current.routing(Deck.B); a = c.current.routing(Deck.A)
        assertEquals("cue is pre-fader: full despite the crossfader on A", 1f, b.cueVol, 1e-6f)
        assertEquals(1f, b.cuePan, 1e-6f)
        assertEquals("house goes to the opposite side", -1f, b.mainPan, 1e-6f)
        assertEquals(-1f, a.mainPan, 1e-6f)
        assertEquals("cue did NOT push B onto main", 0f, b.mainVol, 1e-5f)

        c.setCueVolume(Deck.B, 0.5)
        assertEquals(0.5f, c.current.routing(Deck.B).cueVol, 1e-6f)

        c.setVolume(Deck.B, 2.0) // boost is divided back out of the send: monitor stays at cueVol
        assertEquals(0.25f, c.current.routing(Deck.B).cueVol, 1e-6f)
        c.setVolume(Deck.B, 1.0)
        assertEquals(0.5f, c.current.routing(Deck.B).cueVol, 1e-6f)

        c.setCueOnRight(false)
        b = c.current.routing(Deck.B)
        assertEquals(-1f, b.cuePan, 1e-6f); assertEquals(1f, b.mainPan, 1e-6f)

        c.setCued(Deck.B, false)
        b = c.current.routing(Deck.B)
        assertEquals(0f, b.cueVol, 1e-6f); assertEquals(0f, b.mainPan, 1e-6f)
    }

    private fun twoDecks(): GraphHarness {
        val h = GraphHarness()
        h.playMain(Deck.A, h.toneVoice(441.0, 0.3f))
        h.playMain(Deck.B, h.toneVoice(882.0, 0.5f))
        h.composer.setCueOnRight(true)
        h.composer.setCrossfader(0f) // only A on the house
        return h
    }

    @Test fun cuedDeckMonitorsOnTheCueSideWhileTheHouseGoesToTheOtherSide() {
        val h = twoDecks()
        h.composer.setCued(Deck.B, true) // crossfader sits on A: B must still be heard in the cue
        h.render(8192)
        val out = h.render(8820)
        val left = rms(out, 0, 8820, 0); val right = rms(out, 0, 8820, 1)
        assertEquals("left = house (A, centered fold keeps its level)", 0.3 / Math.sqrt(2.0), left, 0.01)
        assertEquals("right = cue B at cueVol 1", 0.5 / Math.sqrt(2.0), right, 0.01)
    }

    @Test fun cueSideFlipMovesBothBuses() {
        val h = twoDecks()
        h.composer.setCued(Deck.B, true)
        h.composer.setCueOnRight(false)
        h.render(8192)
        val out = h.render(8820)
        assertEquals(0.5 / Math.sqrt(2.0), rms(out, 0, 8820, 0), 0.01) // cue now left
        assertEquals(0.3 / Math.sqrt(2.0), rms(out, 0, 8820, 1), 0.01)
    }

    @Test fun cueIsIndependentOfTheMainFaderAndCrossfader() {
        val h = twoDecks()
        h.composer.setCued(Deck.B, true)
        h.render(8192)
        val ref = rms(h.render(8820), 0, 8820, 1)
        h.composer.setVolume(Deck.B, 0.2)  // main fader down: <1 changes the send? no: divide only above 1
        h.composer.setCrossfader(1f)       // crossfader fully on B then away
        h.composer.setCrossfader(0f)
        h.render(4096)
        val after = rms(h.render(8820), 0, 8820, 1)
        assertEquals(ref, after, 0.01)
    }

    @Test fun nothingCuedRendersBitIdenticalToAGraphThatNeverHadACue() {
        fun run(touchCue: Boolean): FloatArray {
            val h = twoDecks()
            if (touchCue) { h.composer.setCueVolume(Deck.B, 0.4); h.composer.setCueOnRight(false) } // armed but not cued
            return h.render(16384)
        }
        assertArrayEquals(run(false), run(true), 0f)
    }

    @Test fun recordingTapGetsTheCleanHouseEvenWhileADeckIsCued() {
        fun capture(cue: Boolean): FloatArray {
            val h = twoDecks()
            h.composer.setCrossfader(0.5f)
            val acc = ArrayList<Float>()
            h.graph.tapSink = object : TapSink {
                override val isCapturing = true
                override fun onHouse(buf: FloatArray, frames: Int) { for (i in 0 until frames * 2) acc.add(buf[i]) }
            }
            h.composer.setCued(Deck.B, cue)
            h.render(8192)
            return acc.toFloatArray()
        }
        val cued = capture(true)
        val clean = capture(false)
        assertTrue(cued.isNotEmpty())
        assertArrayEquals("tap sees normal stereo house, pre-pan, pre-cue", clean, cued, 0f)
        // and it is genuinely stereo (both channels carry signal)
        var l = 0f; var r = 0f
        for (i in 8192 until cued.size step 2) { l = maxOf(l, kotlin.math.abs(cued[i])); r = maxOf(r, kotlin.math.abs(cued[i + 1])) }
        assertTrue(l > 0.1f && r > 0.1f)
    }
}

package com.levi.pocketdj.mix.graph

import com.levi.pocketdj.mix.graph.GraphHarness.Companion.maxStep
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.MixMath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class RenderParamsSnapshotTest {
    @Test fun composeMatchesTheGainSplitForAMatrixOfInputs() {
        for (v in listOf(0.0, 0.3, 1.0, 1.7, 2.0)) for (x in listOf(0f, 0.25f, 0.5f, 1f)) for (cued in listOf(false, true)) {
            val c = ParamsComposer()
            c.setVolume(Deck.A, v); c.setCrossfader(x); c.setCued(Deck.A, cued); c.setCueVolume(Deck.A, 0.6)
            val a = c.current.a
            assertEquals(minOf(v, 1.0).toFloat() * MixMath.crossfadeFactor(Deck.A, x), a.mainGain, 1e-6f)
            assertEquals(Routing.trimDb(v), a.trimDb, 1e-6f)
            assertEquals(if (cued) (0.6 / maxOf(v, 1.0)).toFloat() else 0f, a.cueGain, 1e-6f)
            assertEquals(if (cued) -1f else 0f, c.current.house.housePan, 0f) // cueOnRight default
        }
    }

    @Test fun crossfaderNeverTouchesTheBoost() {
        val c = ParamsComposer()
        c.setVolume(Deck.A, 1.8)
        c.setVolume(Deck.B, 1.2)
        val writes = c.boostWrites
        val trimA = c.current.a.trimDb; val trimB = c.current.b.trimDb
        for (x in 0..20) c.setCrossfader(x / 20f)
        c.setCued(Deck.A, true); c.setCueVolume(Deck.A, 0.3); c.setCueOnRight(false)
        assertEquals("applyBoost path not entered", writes, c.boostWrites)
        assertEquals(trimA, c.current.a.trimDb, 0f)
        assertEquals(trimB, c.current.b.trimDb, 0f)
        c.setVolume(Deck.A, 1.0)
        assertEquals(writes + 1, c.boostWrites)
        assertEquals(0f, c.current.a.trimDb, 0f)
    }

    @Test fun snapshotsAreImmutableAndPublishedByReference() {
        val bal = floatArrayOf(1f, 0.5f, 0f, 1f)
        val c = ParamsComposer()
        c.setStemBalance(Deck.A, bal)
        val p1 = c.current
        bal[1] = 0.9f // caller mutates its array afterwards
        assertEquals(0.5f, p1.a.stemBalance(1), 0f)
        c.setCrossfader(0.1f)
        assertNotSame(p1, c.current)
        assertEquals(0.5f, c.current.a.stemBalance(1), 0f)
        val g = MixGraph(); g.setParams(c.current)
        assertSame(c.current, g.params)
    }

    @Test fun gainChangesRampAcrossOneBlockWithoutAStep() {
        val h = GraphHarness(512)
        h.playMain(Deck.A, h.toneVoice(441.0, 0.5f))
        h.composer.setCrossfader(0f)
        h.render(4096)
        h.composer.setVolume(Deck.A, 0.0) // 1.0 -> 0 in one swap
        val out = h.render(2048)
        // no click: the largest per-sample step stays near the tone's own slope (0.5*2pi*441/44100 = 0.031)
        assertTrue("step ${maxStep(out, 0, 2048)}", maxStep(out, 0, 2048) < 0.06f)
        // and it did reach silence by the end of the ramp block (plus limiter latency)
        assertEquals(0f, GraphHarness.peak(out, 1200, 2048), 2e-3f)
    }

    @Test fun paramsSwappedFromAnotherThreadAreSeenByTheRenderLoop() {
        val h = GraphHarness(256)
        h.playMain(Deck.A, h.toneVoice(441.0, 0.5f))
        h.composer.setCrossfader(0f)
        h.render(2048)
        val t = Thread { h.composer.setVolume(Deck.A, 0.0) }
        t.start(); t.join()
        h.render(2048)
        assertEquals(0f, GraphHarness.peak(h.render(1024), 0), 1e-3f)
    }

    @Test fun speedAndPitchReachTheTimePitchStage() {
        val h = GraphHarness(512)
        h.playMain(Deck.A, h.toneVoice(441.0, 0.5f))
        h.composer.setTempoPitch(Deck.A, 1.25, 0.0)
        h.render(4096)
        assertEquals(1.25f, h.graph.a.timePitch.speed, 0f)
        h.composer.setTempoPitch(Deck.A, 1.0, 0.0)
        h.render(4096)
        assertEquals(1f, h.graph.a.timePitch.speed, 0f)
    }

    @Test fun stretchedPlaybackConsumesTheSourceFasterAndStillFillsEveryBlock() {
        val h = GraphHarness(512)
        val v = h.toneVoice(441.0, 0.5f)
        h.playMain(Deck.A, v)
        h.composer.setCrossfader(0f)
        h.composer.setTempoPitch(Deck.A, 1.5, 0.0)
        h.render(8192)
        val before = v.playerFrame
        val out = h.render(44100)
        val consumed = v.playerFrame - before
        // loop wrap makes the absolute value ambiguous; consumed is mod loop length (441000)
        val c = ((consumed % 441000) + 441000) % 441000
        assertEquals(1.5 * 44100, c.toDouble(), 44100 * 0.05)
        assertTrue("no dropout", GraphHarness.longestSilence(out, 4096, 44100) < 200)
    }
}

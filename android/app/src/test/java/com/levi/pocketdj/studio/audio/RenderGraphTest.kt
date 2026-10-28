package com.levi.pocketdj.studio.audio

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.dsp.MasterFxParams
import com.levi.pocketdj.studio.dsp.TrackFxParams
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class RenderGraphTest {
    private fun const(frames: Int, v: Float) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { v })
    private fun ramp(frames: Int) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { (it / 2) / 10_000f })

    @Test fun clipSourceLoopsSeamlesslyAndOneShotEnds() {
        val src = PcmClipSource(ramp(10), loop = true)
        val out = FloatArray(25 * 2)
        assertEquals(25, src.pull(out, 25))
        assertEquals(0f, out[20], 0f)          // frame 10 wrapped to frame 0
        assertEquals(4e-4f, out[2 * 24], 1e-9f) // frame 24 == source frame 4
        val once = PcmClipSource(ramp(10), loop = false)
        assertEquals(10, once.pull(FloatArray(40), 20))
        assertTrue(once.finished)
        assertEquals(0, once.pull(FloatArray(40), 20))
        once.seek(5)
        assertEquals(5, once.pull(FloatArray(40), 20))
    }

    @Test fun tracksSumWithGainAndCentrePanIsUnity() {
        val g = RenderGraph()
        g.addTrack("a", PcmClipSource(const(100, 0.25f), true)).gain = 1f
        g.addTrack("b", PcmClipSource(const(100, 0.25f), true)).gain = 0.5f
        val out = FloatArray(64 * 2)
        g.render(out, 64)
        assertEquals(0.375f, out[10], 1e-6f)
        assertEquals(1f, g.panGainL(0f), 1e-6f)
        assertEquals(1f, g.panGainR(0f), 1e-6f)
    }

    @Test fun hardPanSilencesTheFarSide() {
        val g = RenderGraph()
        g.addTrack("a", PcmClipSource(const(100, 0.3f), true)).pan = -1f
        val out = FloatArray(16 * 2)
        g.render(out, 16)
        assertTrue(out[0] > 0.3f)           // left boosted (equal-power +3 dB at the edge)
        assertEquals(0f, out[1], 1e-6f)
    }

    @Test fun muteAndSoloGateTracks() {
        val g = RenderGraph()
        val a = g.addTrack("a", PcmClipSource(const(100, 0.2f), true))
        val b = g.addTrack("b", PcmClipSource(const(100, 0.4f), true))
        val out = FloatArray(8 * 2)
        a.mute = true; g.render(out, 8)
        assertEquals(0.4f, out[0], 1e-6f)
        a.mute = false; a.solo = true; g.render(out, 8)
        assertEquals(0.2f, out[0], 1e-6f)
        b.solo = true; g.render(out, 8)
        assertEquals(0.6f, out[0], 1e-6f)
    }

    @Test fun outputIsHardLimitedAtUnity() {
        val g = RenderGraph()
        g.addTrack("a", PcmClipSource(const(100, 0.9f), true))
        g.addTrack("b", PcmClipSource(const(100, 0.9f), true))
        val out = FloatArray(8 * 2)
        g.render(out, 8)
        assertEquals(1f, out[0], 0f)
    }

    @Test fun trackFxRunsAndRingsPastAnEndedClip() {
        val g = RenderGraph()
        val imp = PcmBuffer(44_100, 2, FloatArray(200) .also { it[0] = 1f; it[1] = 1f })
        g.addTrack("a", PcmClipSource(imp, false))
        g.setTrackFx("a", TrackFxParams(reverb = 0.8))
        val out = g.renderOffline(6000)
        var tail = 0.0
        for (i in 3000 until 6000) tail += out.samples[2 * i] * out.samples[2 * i].toDouble()
        assertTrue("reverb tail after the 100-frame clip ended: $tail", tail > 1e-9)
    }

    @Test fun masterGainAppliesToTheSum() {
        val g = RenderGraph()
        g.addTrack("a", PcmClipSource(const(100, 0.2f), true))
        g.setMasterFx(MasterFxParams(masterGain = 2.0))
        val out = FloatArray(8 * 2)
        g.render(out, 8)
        assertEquals(0.4f, out[0], 1e-6f)
    }

    @Test fun renderingIsBlockSizeIndependent() {
        fun build() = RenderGraph().also {
            it.addTrack("a", PcmClipSource(ramp(5000), true)).gain = 0.8f
            it.setTrackFx("a", TrackFxParams(eqLowDb = 4.0, chorus = 0.5))
            it.setMasterFx(MasterFxParams(brazil = true, drive = true, bpm = 140.0))
        }
        val big = build().renderOffline(9000, block = 4096)
        val small = build().renderOffline(9000, block = 37)
        var m = 0f
        for (i in big.samples.indices) m = maxOf(m, abs(big.samples[i] - small.samples[i]))
        assertTrue("diff $m", m < 1e-6f)
    }

    @Test fun positionAdvancesAndSeekMovesTheBeatPhase() {
        val g = RenderGraph()
        g.addTrack("a", PcmClipSource(const(100, 0.1f), true))
        g.render(FloatArray(512 * 2), 512)
        assertEquals(512L, g.position)
        g.seek(22_050)
        assertEquals(22_050L, g.position)
    }

    @Test fun removeTrackStopsItsContribution() {
        val g = RenderGraph()
        g.addTrack("a", PcmClipSource(const(100, 0.2f), true))
        g.removeTrack("a")
        val out = FloatArray(8 * 2) { 9f }
        g.render(out, 8)
        assertEquals(0f, out[0], 0f)
    }
}

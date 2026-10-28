package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.PcmBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

class BeatDetectTest {
    /** Mono click track: a decaying 1.5 kHz burst on every beat, first beat at [offsetMs]. */
    private fun clicks(bpm: Double, seconds: Double, offsetMs: Int = 0, accentEvery: Int = 4): PcmBuffer {
        val sr = 44100
        val out = FloatArray((seconds * sr).toInt())
        val step = 60.0 / bpm * sr
        var beat = 0
        var pos = offsetMs / 1000.0 * sr
        while (pos < out.size) {
            val amp = if (beat % accentEvery == 0) 1.0 else 0.55
            val p = pos.toInt()
            for (i in 0 until 600) {
                if (p + i >= out.size) break
                out[p + i] += (amp * sin(2 * PI * 1500 * i / sr) * exp(-i / 90.0)).toFloat()
            }
            pos += step; beat++
        }
        return PcmBuffer(sr, 1, out)
    }

    @Test fun detects90Bpm() {
        val g = BeatDetect.detectGrid(clicks(90.0, 16.0))
        assertNotNull(g)
        assertEquals(90.0, g!!.bpm, 1.0)
    }

    @Test fun detects150Bpm() {
        val g = BeatDetect.detectGrid(clicks(150.0, 16.0))
        assertNotNull(g)
        assertEquals(150.0, g!!.bpm, 1.0)
    }

    @Test fun sub70FundamentalFoldsIntoReportWindow() {
        // 60 BPM is below the 70 report floor but inside the 55 search floor: found, then folded to 120.
        val g = BeatDetect.detectGrid(clicks(60.0, 20.0))
        assertNotNull(g)
        assertEquals(120.0, g!!.bpm, 2.0)
        assertTrue(g.bpm >= BeatDetect.BPM_LO && g.bpm <= BeatDetect.BPM_HI)
    }

    @Test fun searchRangeIsWiderThanReportWindow() {
        assertTrue(BeatDetect.SEARCH_BPM_LO < BeatDetect.BPM_LO)
        assertTrue(BeatDetect.SEARCH_BPM_HI > BeatDetect.BPM_HI)
        assertEquals(55.0, BeatDetect.SEARCH_BPM_LO, 0.0)
        assertEquals(210.0, BeatDetect.SEARCH_BPM_HI, 0.0)
        assertEquals(70.0, BeatDetect.BPM_LO, 0.0)
        assertEquals(180.0, BeatDetect.BPM_HI, 0.0)
    }

    @Test fun octaveFoldRules() {
        assertEquals(120.0, BeatDetect.octaveFold(60.0), 1e-9)
        assertEquals(100.0, BeatDetect.octaveFold(200.0), 1e-9)
        assertEquals(140.0, BeatDetect.octaveFold(70.0 * 2), 1e-9)
        assertEquals(90.0, BeatDetect.octaveFold(90.0), 1e-9)
        assertEquals(0.0, BeatDetect.octaveFold(0.0), 0.0)
        assertEquals(-5.0, BeatDetect.octaveFold(-5.0), 0.0)
        // boundaries stay put
        assertEquals(70.0, BeatDetect.octaveFold(70.0), 1e-9)
        assertEquals(180.0, BeatDetect.octaveFold(180.0), 1e-9)
    }

    @Test fun firstDownbeatLandsOnTheAccentedBeat() {
        val g = BeatDetect.detectGrid(clicks(120.0, 16.0, offsetMs = 250))!!
        // Beat 0 (accented) is at 250 ms; any bar-phase pick is a multiple of 500 ms later; within one frame tolerance.
        val rel = (g.firstDownbeatMs - 250).toDouble() / 500.0
        assertEquals(Math.round(rel).toDouble(), rel, 0.08)
    }

    @Test fun tooShortOrSilentGivesNull() {
        assertNull(BeatDetect.detectGrid(PcmBuffer(44100, 1, FloatArray(44100))))          // 1 s
        assertNull(BeatDetect.detectGrid(PcmBuffer(44100, 1, FloatArray(44100 * 10))))     // silence
    }

    @Test fun stereoIsMixedDown() {
        val m = clicks(100.0, 12.0)
        val st = FloatArray(m.samples.size * 2) { m.samples[it / 2] }
        val g = BeatDetect.detectGrid(PcmBuffer(44100, 2, st))
        assertEquals(100.0, g!!.bpm, 1.5)
    }

    @Test fun fftOfSineHasSinglePeak() {
        val n = 1024
        val re = DoubleArray(n) { sin(2 * PI * 64 * it / n) }
        val im = DoubleArray(n)
        BeatDetect.fft(re, im)
        val mags = DoubleArray(n / 2) { Math.hypot(re[it], im[it]) }
        assertEquals(64, mags.indices.maxByOrNull { mags[it] })
        assertEquals(512.0, mags[64], 1e-6)
    }
}

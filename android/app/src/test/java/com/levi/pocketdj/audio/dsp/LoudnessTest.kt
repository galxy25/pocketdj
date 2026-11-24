package com.levi.pocketdj.audio.dsp

import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sin
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class LoudnessTest {
    private fun sine(freq: Double, peakDbfs: Double, seconds: Double, sr: Int, channels: Int): FloatArray {
        val a = 10.0.pow(peakDbfs / 20)
        val n = (seconds * sr).toInt()
        val out = FloatArray(n * channels)
        for (i in 0 until n) { val v = (a * sin(2 * PI * freq * i / sr)).toFloat(); for (c in 0 until channels) out[i * channels + c] = v }
        return out
    }

    @Test fun stereo1kHzAtMinus23ReadsMinus23() {
        for (sr in listOf(44100, 48000, 96000)) {
            val l = Loudness.integratedLoudness(sine(1000.0, -23.0, 5.0, sr, 2), 2, sr.toDouble())
            assertEquals("sr=$sr", -23.0, l!!, 0.1)
        }
    }

    @Test fun monoReadsThreeDbBelowStereo() {
        val st = Loudness.integratedLoudness(sine(1000.0, -20.0, 5.0, 48000, 2), 2, 48000.0)!!
        val mo = Loudness.integratedLoudness(sine(1000.0, -20.0, 5.0, 48000, 1), 1, 48000.0)!!
        assertEquals(3.01, st - mo, 0.05)
    }

    @Test fun monoSumOfIdenticalChannelsMatchesExactStereo() {
        val s = sine(1000.0, -18.0, 5.0, 44100, 2)
        val m = Loudness.Meter(1, 44100.0); m.processMonoSum(s, s.size / 2, 2)
        val exact = Loudness.integratedLoudness(s, 2, 44100.0)!!
        assertEquals(exact, m.integratedLoudness()!!, 0.01)
    }

    @Test fun amplitudeStepsMoveLoudnessOneToOne() {
        val a = Loudness.integratedLoudness(sine(1000.0, -26.0, 4.0, 48000, 2), 2, 48000.0)!!
        val b = Loudness.integratedLoudness(sine(1000.0, -16.0, 4.0, 48000, 2), 2, 48000.0)!!
        assertEquals(10.0, b - a, 0.01)
    }

    @Test fun silenceIsGatedAndShortAudioIsNull() {
        assertNull(Loudness.integratedLoudness(FloatArray(48000 * 3), 1, 48000.0))
        assertNull(Loudness.integratedLoudness(sine(1000.0, -20.0, 0.3, 48000, 1), 1, 48000.0))
        assertNull(Loudness.integratedLoudness(FloatArray(10), 0, 48000.0))
    }

    @Test fun relativeGateIgnoresQuietTail() {
        val loud = sine(1000.0, -20.0, 4.0, 48000, 1)
        val quiet = sine(1000.0, -50.0, 4.0, 48000, 1) // > 10 LU below, above the absolute gate
        val both = Loudness.integratedLoudness(loud + quiet, 1, 48000.0)!!
        val only = Loudness.integratedLoudness(loud, 1, 48000.0)!!
        assertEquals(only, both, 0.3) // blocks straddling the step pull it down slightly; without the gate it would be ~ -3 LU
    }

    @Test fun kWeightingBoostsHighsAndCutsSubBass() {
        val ref = Loudness.integratedLoudness(sine(1000.0, -20.0, 4.0, 48000, 1), 1, 48000.0)!!
        val hi = Loudness.integratedLoudness(sine(8000.0, -20.0, 4.0, 48000, 1), 1, 48000.0)!!
        val lo = Loudness.integratedLoudness(sine(20.0, -20.0, 4.0, 48000, 1), 1, 48000.0)!!
        assertTrue("hi=${hi - ref}", hi - ref in 3.0..5.0)
        assertTrue("lo=${ref - lo}", ref - lo > 2.0)
    }

    @Test fun levelingTargetAndClamp() {
        assertEquals(0.0, LoudnessLeveling.gainDb(-14.0)!!, 1e-9)
        assertEquals(-12.0, LoudnessLeveling.gainDb(0.0)!!, 1e-9)   // would be -14
        assertEquals(6.0, LoudnessLeveling.gainDb(-30.0)!!, 1e-9)   // would be +16
        assertEquals(-3.0, LoudnessLeveling.gainDb(-11.0)!!, 1e-9)
        assertNull(LoudnessLeveling.gainDb(null)); assertNull(LoudnessLeveling.gainDb(Double.NaN))
        assertEquals(0.0, LoudnessLeveling.gainDbOrZero(null), 0.0)
        assertEquals(2.0, LoudnessLeveling.linear(6.0206), 0.001)
    }
}

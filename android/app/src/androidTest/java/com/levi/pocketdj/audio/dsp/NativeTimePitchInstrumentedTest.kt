package com.levi.pocketdj.audio.dsp

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.levi.pocketdj.studio.audio.NativeDsp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.sin

/** The real Signalsmith kernel through JNI: length and pitch within tolerance at 0.7x / 1.3x. */
@RunWith(AndroidJUnit4::class)
class NativeTimePitchInstrumentedTest {
    private val sr = 44_100

    private fun run(speed: Float, pitch: Float, hz: Double, seconds: Int): FloatArray {
        val t = NativeTimePitch(sr, 1024)
        t.setSpeed(speed); t.setPitchSemitones(pitch)
        val out = ArrayList<Float>()
        val tmp = FloatArray(4096 * 2)
        val total = seconds * sr
        var fed = 0
        while (fed < total) {
            val n = minOf(1024, total - fed)
            val b = FloatArray(n * 2) { i -> (0.6 * sin(2 * PI * hz * (fed + i / 2) / sr)).toFloat() }
            t.push(b, n)
            fed += n
            while (t.availableFrames > 0) { val g = t.pull(tmp, 4096); for (i in 0 until g * 2) out.add(tmp[i]) }
        }
        t.close()
        return out.toFloatArray()
    }

    private fun hz(a: FloatArray, from: Int, to: Int): Double {
        var c = 0
        for (i in from + 1 until to) if (a[2 * (i - 1)] < 0f && a[2 * i] >= 0f) c++
        return c * sr.toDouble() / (to - from)
    }

    @Test fun lengthFollowsTempoAt07And13() {
        assumeTrue(NativeDsp.available)
        for (s in listOf(0.7f, 1.3f)) {
            val o = run(s, 0f, 440.0, 4)
            assertEquals("speed $s", 4 * sr / s.toDouble(), (o.size / 2).toDouble(), 4 * sr / s * 0.01)
        }
    }

    @Test fun tempoKeepsPitchAndSemitonesShiftIt() {
        assumeTrue(NativeDsp.available)
        val o = run(1.3f, 0f, 440.0, 4)
        assertEquals(440.0, hz(o, 30_000, o.size / 2 - 5_000), 440 * 0.03)
        val p = run(0.7f, 12f, 440.0, 4)
        assertEquals(880.0, hz(p, 30_000, p.size / 2 - 5_000), 880 * 0.03)
    }

    @Test fun latencyIsContinuousAcrossTempoAndMatchesTheStretcherModel() {
        assumeTrue(NativeDsp.available)
        val t = NativeTimePitch(sr, 1024)
        val probe = JniRtBackend(sr, 1024, 2050)
        val inLat = probe.inputLatency; val outLat = probe.outputLatency; probe.close()
        assertTrue(inLat > 0 && outLat > 0)
        for (s in listOf(0.7f, 1.0f, 1.3f)) {
            t.setSpeed(s)
            val expected = Math.round(inLat / s.toDouble()).toInt() + outLat
            assertEquals("speed $s", expected, t.algorithmicLatencyFrames())
            // source-domain lag (frames * speed) tracks inLat + outLat * speed
            assertEquals(inLat + outLat * s.toDouble(), t.algorithmicLatencyFrames() * s.toDouble(), 2.0)
        }
        t.close()
    }
}

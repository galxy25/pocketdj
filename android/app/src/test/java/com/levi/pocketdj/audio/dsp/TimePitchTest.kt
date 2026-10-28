package com.levi.pocketdj.audio.dsp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TimePitchTest {
    private val sr = 44_100

    /** Feed [seconds] of [freq] sine in 1024-frame blocks, collect all output (incl. tail). */
    private fun runTone(tp: TimePitch, freq: Float, seconds: Float): FloatArray {
        val total = (seconds * sr).toInt()
        val out = ArrayList<Float>()
        val tmp = FloatArray(8192 * 2)
        var fed = 0
        while (fed < total) {
            val n = minOf(1024, total - fed)
            tp.push(sine(freq, n, 0.7f, fed), n)
            fed += n
            while (tp.availableFrames > 0) { val g = tp.pull(tmp, 8192); for (i in 0 until g * 2) out.add(tmp[i]) }
        }
        tp.endOfStream()
        while (tp.availableFrames > 0) { val g = tp.pull(tmp, 8192); for (i in 0 until g * 2) out.add(tmp[i]) }
        return out.toFloatArray()
    }

    private fun zeroCrossHz(a: FloatArray, fromFrame: Int, toFrame: Int): Double {
        var c = 0
        for (i in fromFrame + 1 until toFrame) if (a[2 * (i - 1)] < 0f && a[2 * i] >= 0f) c++
        return c * sr.toDouble() / (toFrame - fromFrame)
    }

    @Test fun passthroughAtUnity() {
        val tp = TimePitch(sr)
        val out = runTone(tp, 440f, 1f)
        assertEquals(sr.toDouble(), (out.size / 2).toDouble(), 2.0)
    }

    @Test fun speed15ConsumesOnePointFiveXInput() {
        val tp = TimePitch(sr).apply { setSpeed(1.5f) }
        val out = runTone(tp, 440f, 3f)
        val expected = 3 * sr / 1.5
        assertEquals(expected, (out.size / 2).toDouble(), expected * 0.02)
    }

    @Test fun speedKeepsPitch() {
        val tp = TimePitch(sr).apply { setSpeed(1.5f) }
        val out = runTone(tp, 440f, 3f)
        val f = zeroCrossHz(out, 20_000, out.size / 2 - 20_000)
        assertEquals(440.0, f, 440 * 0.03)
    }

    @Test fun pitchPlus12DoublesFrequencyAndKeepsLength() {
        val tp = TimePitch(sr).apply { setPitchSemitones(12f) }
        val out = runTone(tp, 440f, 3f)
        assertEquals(3.0 * sr, (out.size / 2).toDouble(), 3.0 * sr * 0.02)
        val f = zeroCrossHz(out, 20_000, out.size / 2 - 20_000)
        assertEquals(880.0, f, 880 * 0.03)
    }

    @Test fun speedAndPitchAreIndependent() {
        val tp = TimePitch(sr).apply { setSpeed(0.75f); setPitchSemitones(-12f) }
        val out = runTone(tp, 880f, 3f)
        val expected = 3 * sr / 0.75
        assertEquals(expected, (out.size / 2).toDouble(), expected * 0.02)
        assertEquals(440.0, zeroCrossHz(out, 20_000, out.size / 2 - 20_000), 440 * 0.03)
    }

    @Test fun speedIsClampedToRange() {
        val tp = TimePitch(sr).apply { setSpeed(5f) }
        assertEquals(2f, tp.speed, 0f)
        tp.setSpeed(0.1f)
        assertEquals(0.5f, tp.speed, 0f)
    }

    @Test fun flushClearsTails() {
        val tp = TimePitch(sr).apply { setSpeed(1.5f) }
        tp.push(sine(440f, 4096, 0.7f), 4096)
        assertTrue(tp.availableFrames > 0)
        tp.flush()
        assertEquals(0, tp.availableFrames)
        tp.endOfStream()
        assertEquals(0, tp.availableFrames)
    }

    @Test fun liveSpeedChangeKeepsInFlightAudio() {
        val tp = TimePitch(sr)
        tp.setSpeed(1.2f)
        tp.push(sine(440f, 8192, 0.7f), 8192)
        val before = tp.availableFrames
        tp.setSpeed(1.1f)
        tp.push(sine(440f, 1024, 0.7f, 8192), 1024)
        assertTrue(tp.availableFrames >= before) // nothing dropped by the parameter change
    }
}

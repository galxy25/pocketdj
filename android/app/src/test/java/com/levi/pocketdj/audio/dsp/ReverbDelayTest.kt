package com.levi.pocketdj.audio.dsp

import com.levi.pocketdj.mix.model.EffectVariant
import com.levi.pocketdj.mix.model.FxParams
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class ReverbDelayTest {
    private fun impulse(frames: Int): FloatArray = FloatArray(frames * 2).also { it[0] = 1f; it[1] = 1f }

    /** Energy in the last 100 ms of a 2.5 s impulse response. */
    private fun lateEnergy(p: FxParams.ReverbPreset): Double {
        val r = Reverb(SR).apply { loadPreset(p); setWetDryMix(100f) }
        val x = impulse(110_250); r.run(x)
        var e = 0.0
        for (i in 105_840 until 110_250) e += x[2 * i].toDouble() * x[2 * i]
        return e
    }

    @Test fun tailLengthOrdersByVariant() {
        val room = lateEnergy(FxParams.ReverbPreset.MEDIUM_ROOM)
        val plate = lateEnergy(FxParams.ReverbPreset.PLATE)
        val hall = lateEnergy(FxParams.ReverbPreset.MEDIUM_HALL)
        val cath = lateEnergy(FxParams.ReverbPreset.CATHEDRAL)
        assertTrue("room<plate", room < plate)
        assertTrue("plate<hall", plate < hall)
        assertTrue("hall<cathedral", hall < cath)
        assertTrue(cath > 0)
    }

    @Test fun reverbProducesATailAndDryAtZeroWet() {
        val r = Reverb(SR).apply { loadPreset(FxParams.ReverbPreset.MEDIUM_HALL); setWetDryMix(0f) }
        val x = impulse(4096); val y = x.copyOf(); r.run(y)
        assertArrayEquals(x, y, 1e-7f)
        r.reset(); r.setWetDryMix(50f)
        val z = impulse(8192); r.run(z)
        var tail = 0.0
        for (i in 2000 until 8192) tail += abs(z[2 * i]).toDouble()
        assertTrue(tail > 0.01)
    }

    @Test fun loadPresetClearsTail() {
        val r = Reverb(SR).apply { loadPreset(FxParams.ReverbPreset.CATHEDRAL); setWetDryMix(100f) }
        r.run(impulse(4096))
        r.loadPreset(FxParams.ReverbPreset.CATHEDRAL)
        val silent = FloatArray(4096 * 2); r.run(silent)
        for (v in silent) assertEquals(0f, v, 0f)
        assertEquals(2, r.presetLoads)
    }

    @Test fun reverbBypassBitIdentical() {
        val r = Reverb(SR).apply { setWetDryMix(100f); bypass = true }
        val x = sine(300f, 1024); val y = x.copyOf(); r.run(y)
        assertArrayEquals(x, y, 0f)
    }

    private fun firstEchoFrame(d: ModDelay, from: Int = 1): Int {
        val x = impulse(44_100); d.run(x, 256)
        for (i in from until 44_100) if (abs(x[2 * i]) > 0.3f) return i
        return -1
    }

    @Test fun delayTimeEqualsModDelayTimeOfVariant() {
        for (v in listOf(EffectVariant.FLANGE, EffectVariant.CHORUS, EffectVariant.ECHO)) {
            val s = 0.6
            val d = ModDelay(SR).apply {
                setDelayTime(FxParams.modDelayTime(v, s)); reset()
                setFeedback(0f); setWetDryMix(100f); setLowPassCutoff(21_000f)
            }
            val expected = FxParams.modDelayTime(v, s) * SR
            val got = firstEchoFrame(d)
            assertEquals("$v", expected, got.toDouble(), 3.0)
        }
    }

    @Test fun feedbackRepeatsDecay() {
        val d = ModDelay(SR).apply {
            setDelayTime(0.1); reset(); setFeedback(50f); setWetDryMix(100f); setLowPassCutoff(21_000f)
        }
        val x = impulse(44_100); d.run(x, 512)
        fun peakNear(frame: Int): Float { var m = 0f; for (i in frame - 4..frame + 4) m = maxOf(m, abs(x[2 * i])); return m }
        val p1 = peakNear(4410); val p2 = peakNear(8820)
        assertTrue(p1 > 0.3f)
        assertEquals(0.5f, p2 / p1, 0.12f)
    }

    @Test fun delayBypassBitIdentical() {
        val d = ModDelay(SR).apply { setWetDryMix(100f); bypass = true }
        val x = sine(300f, 1024); val y = x.copyOf(); d.run(y)
        assertArrayEquals(x, y, 0f)
    }
}

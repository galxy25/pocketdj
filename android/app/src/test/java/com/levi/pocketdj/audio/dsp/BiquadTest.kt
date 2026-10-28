package com.levi.pocketdj.audio.dsp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BiquadTest {
    @Test fun lowPassPassesLowCutsHigh() {
        val b = Biquad(SR).apply { set(Biquad.Type.LOW_PASS, 1_000f, 0.7071f) }
        assertEquals(0.0, gainDbAt(b, 100f), 0.3)
        assertEquals(-3.0, gainDbAt(b, 1_000f), 0.5)
        assertTrue(gainDbAt(b, 8_000f) < -30)
    }

    @Test fun highPassCutsLowPassesHigh() {
        val b = Biquad(SR).apply { set(Biquad.Type.HIGH_PASS, 1_000f, 0.7071f) }
        assertTrue(gainDbAt(b, 100f) < -30)
        assertEquals(0.0, gainDbAt(b, 10_000f), 0.3)
    }

    @Test fun bandPassPeaksAtCentre() {
        val b = Biquad(SR).apply { set(Biquad.Type.BAND_PASS, 2_000f, 2f) }
        assertEquals(0.0, gainDbAt(b, 2_000f), 0.3)
        assertTrue(gainDbAt(b, 200f) < -15)
        assertTrue(gainDbAt(b, 15_000f) < -15)
    }

    @Test fun bypassIsBitIdentical() {
        val b = Biquad(SR).apply { set(Biquad.Type.LOW_PASS, 300f, 1f); bypass = true }
        val x = sine(1_234f, 2048, 0.8f)
        val y = x.copyOf(); b.run(y)
        assertArrayEquals(x, y, 0f)
    }

    @Test fun eq3FlatIsTransparent() {
        val e = Eq3(SR)
        val x = sine(440f, 4096, 0.9f)
        val y = x.copyOf(); e.run(y)
        for (i in x.indices) assertTrue(Math.abs(x[i] - y[i]) < 1e-6f)
    }

    @Test fun eq3LowShelfLiftsBassNotTreble() {
        val e = Eq3(SR).apply { setLowDb(12f) }
        assertEquals(12.0, gainDbAt(e, 100f), 1.2)
        assertEquals(0.0, gainDbAt(e, 5_000f), 0.5)
    }

    @Test fun eq3MidAndHighBands() {
        val mid = Eq3(SR).apply { setMidDb(-12f) }
        assertEquals(-12.0, gainDbAt(mid, 1_000f), 0.5)
        assertEquals(0.0, gainDbAt(mid, 60f), 0.5)
        val hi = Eq3(SR).apply { setHighDb(12f) }
        assertEquals(12.0, gainDbAt(hi, 12_000f), 1.2)
        assertEquals(0.0, gainDbAt(hi, 100f), 0.5)
    }

    @Test fun eq3ClampsToPlusMinus12() {
        val e = Eq3(SR).apply { setLowDb(40f); setHighDb(-40f) }
        assertEquals(12f, e.lowDb, 0f)
        assertEquals(-12f, e.highDb, 0f)
    }

    @Test fun trimGainAppliesDb() {
        val t = TrimGain(SR).apply { setGainDb(6.0206f); snap() }
        val x = constant(0.25f, 256)
        t.run(x)
        assertEquals(0.5f, x[x.size - 2], 1e-4f)
    }

    @Test fun trimGainGlidesWithoutStep() {
        val t = TrimGain(SR).apply { setGainDb(-20f) }
        val x = constant(1f, 4410)
        t.run(x, 441)
        assertTrue(x[0] > 0.9f) // first sample barely moved (no zipper step)
        assertEquals(0.1f, x[x.size - 2], 0.01f)
    }
}

package com.levi.pocketdj.audio.dsp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class LimiterTest {
    @Test fun neverExceedsCeilingWhenOverdriven() {
        val lim = Limiter(SR)
        val x = sine(220f, 44_100, 2f)
        // a burst of hard, sudden peaks too
        for (i in 10_000 until 10_050) { x[2 * i] = 2f; x[2 * i + 1] = -2f }
        lim.run(x, 300)
        var peak = 0f
        for (v in x) peak = maxOf(peak, abs(v))
        assertTrue("peak $peak", peak <= 1.0f)
        assertTrue("limiter still passes signal", peak > 0.8f)
    }

    @Test fun transparentBelowCeiling() {
        val lim = Limiter(SR)
        val x = sine(330f, 8192, 0.5f)
        val y = x.copyOf(); lim.run(y, 256)
        val d = lim.latencyFrames
        for (i in d until 8192) {
            assertEquals(x[2 * (i - d)], y[2 * i], 0f)
        }
    }

    @Test fun bypassIsBitIdentical() {
        val lim = Limiter(SR).apply { bypass = true }
        val x = sine(330f, 2048, 1.5f)
        val y = x.copyOf(); lim.run(y)
        assertArrayEquals(x, y, 0f)
    }

    @Test fun blockSizeDoesNotChangeOutput() {
        val x = sine(100f, 20_000, 1.8f)
        val a = x.copyOf(); Limiter(SR).run(a, 64)
        val b = x.copyOf(); Limiter(SR).run(b, 4096)
        assertArrayEquals(a, b, 0f)
    }

    @Test fun reportsGainReduction() {
        val lim = Limiter(SR)
        val x = constant(2f, 2048); lim.run(x)
        assertEquals(0.5f, lim.takeMinGain(), 0.01f)
        assertEquals(1f, lim.takeMinGain(), 0f)
    }

    @Test fun lowFrequencyOverdriveNeedsNoHardClamp() {
        val lim = Limiter(SR)
        lim.run(sine(40f, 8820, 2f), 512)
        assertEquals("pre-clamp overs", 0L, lim.clampedSamples)
    }
}

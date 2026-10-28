package com.levi.pocketdj.audio.dsp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DynamicsTest {
    private fun steadyOutDb(c: Compressor, inLinear: Float): Double {
        val x = constant(inLinear, 44_100)
        c.reset(); c.run(x)
        return db(Math.abs(x[x.size - 2]).toDouble())
    }

    @Test fun belowThresholdIsUnity() {
        val c = Compressor(SR).apply { set(-20f, 5f, 0.001f, 0.05f, 0f) }
        assertEquals(db(0.05), steadyOutDb(c, 0.05f), 0.01)
    }

    @Test fun aboveThresholdFollowsRatioCurve() {
        val c = Compressor(SR).apply { set(-20f, 5f, 0.001f, 0.05f, 0f) } // 4:1
        assertEquals(4f, c.ratio, 1e-4f)
        // input -6 dB: 14 dB over, reduction 14*(1-1/4)=10.5 -> -16.5 dB
        assertEquals(-16.5, steadyOutDb(c, 0.5012f), 0.15)
    }

    @Test fun glueIsGentlerThanPunch() {
        val punch = Compressor(SR).apply { set(-20f, 5f, 0.001f, 0.05f, 0f) }
        val glue = Compressor(SR).apply { set(-20f, 10f, 0.001f, 0.05f, 0f) }
        assertTrue(steadyOutDb(glue, 0.5f) > steadyOutDb(punch, 0.5f))
    }

    @Test fun makeupAddsGain() {
        val c = Compressor(SR).apply { set(0f, 5f, 0.01f, 0.1f, 6f) }
        assertEquals(db(0.1) + 6, steadyOutDb(c, 0.1f), 0.05)
    }

    @Test fun attackIsGradual() {
        val c = Compressor(SR).apply { set(-30f, 5f, 0.05f, 0.1f, 0f) }
        val x = constant(1f, 200)
        c.run(x)
        assertTrue(x[0] > x[x.size - 2]) // gain still coming down
        assertTrue(x[0] > 0.95f)
    }

    @Test fun bypassIsBitIdentical() {
        val c = Compressor(SR).apply { set(-30f, 1f, 0.001f, 0.1f, 6f); bypass = true }
        val x = sine(200f, 2048, 0.9f); val y = x.copyOf(); c.run(y)
        assertArrayEquals(x, y, 0f)
    }
}

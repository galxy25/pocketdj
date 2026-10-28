package com.levi.pocketdj.audio.dsp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MeterTest {
    @Test fun fullScaleSinePeakAndRms() {
        val m = Meter(windowFrames = 4096)
        m.run(sine(1_000f, 4096 * 4), 512)
        assertEquals(1f, m.levels.peak, 0.001f)
        assertEquals(0.7071f, m.levels.rms, 0.005f)
        assertEquals(4L, m.levels.updates)
    }

    @Test fun cadenceIsIndependentOfBlockSize() {
        for (block in intArrayOf(64, 1000, 2048, 8192)) {
            val m = Meter(windowFrames = 4096)
            m.run(sine(500f, 4096 * 3), block)
            assertEquals("block $block", 3L, m.levels.updates)
        }
    }

    @Test fun neverModifiesAudio() {
        val m = Meter()
        val x = sine(1_000f, 5000, 0.6f)
        val y = x.copyOf(); m.run(y)
        assertArrayEquals(x, y, 0f)
    }

    @Test fun channelsMeteredSeparately() {
        val m = Meter(windowFrames = 1024)
        val x = FloatArray(2048 * 2)
        for (i in 0 until 2048) { x[2 * i] = 0.5f; x[2 * i + 1] = 0.25f }
        m.run(x)
        assertEquals(0.5f, m.levels.peakL, 1e-6f)
        assertEquals(0.25f, m.levels.rmsR, 1e-6f)
    }

    // --- EnvelopeFollower ---

    private fun envAfter(block: Int, input: Float, frames: Int, env: EnvelopeFollower = EnvelopeFollower(SR)): Float {
        env.run(constant(input, frames), block)
        return env.value
    }

    @Test fun envelopeAttackReaches63PercentInEightMs() {
        val target = 0.925f // DC 0.707 -> -3 dBFS -> (37/40)
        val frames = (0.008f * SR).toInt()
        for (block in intArrayOf(64, 2048)) {
            // feed in exactly `frames` frames, but never in one gulp bigger than the block
            val v = envAfter(block, 0.7071f, frames)
            assertEquals("block $block", 0.632f * target, v, 0.07f)
        }
    }

    @Test fun envelopeBlockSizeIndependent() {
        val a = EnvelopeFollower(SR); val b = EnvelopeFollower(SR)
        val x = sine(300f, 8192, 0.8f)
        a.run(x.copyOf(), 64); b.run(x.copyOf(), 2048)
        assertEquals(a.value, b.value, 1e-6f)
    }

    @Test fun envelopeReleasesIn180Ms() {
        val env = EnvelopeFollower(SR)
        env.run(constant(0.7071f, 44_100), 512)
        val top = env.value
        assertEquals(0.925f, top, 0.01f)
        for (block in intArrayOf(64, 2048)) {
            val e = EnvelopeFollower(SR)
            e.run(constant(0.7071f, 44_100), 512)
            e.run(constant(0f, (0.180f * SR).toInt()), block)
            assertEquals("block $block", top * 0.368f, e.value, 0.06f)
        }
    }

    @Test fun envelopeMapsMinus40ToZero() {
        val v = envAfter(512, 0.01f, 44_100) // -40 dBFS
        assertTrue(v < 0.02f)
        assertEquals(0f, envAfter(512, 0f, 4410), 0f)
    }
}

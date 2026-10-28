package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Test

class PcmBufferTest {
    @Test fun monoToCanonicalDuplicatesAndResamples() {
        val m = PcmBuffer(22_050, 1, floatArrayOf(0f, 1f, 0f, 1f))
        val c = m.toCanonical()
        assertEquals(2, c.channels); assertEquals(44_100, c.sampleRate)
        assertEquals(8, c.frames)
        assertEquals(c.samples[2 * 1], 0.5f, 1e-6f) // interpolated midpoint
        assertEquals(c.samples[2 * 2], c.samples[2 * 2 + 1], 0f)
    }

    @Test fun surroundDropsToFrontPair() {
        val s = PcmBuffer(44_100, 3, floatArrayOf(1f, 2f, 3f, 4f, 5f, 6f)).toStereo()
        assertEquals(listOf(1f, 2f, 4f, 5f), s.samples.toList())
    }

    @Test fun pcm16BytesDecode() {
        val dst = FloatArray(2)
        PcmBuffer.fromPcm16(byteArrayOf(0x00, 0x40, 0x00, 0x80.toByte()), 4, dst, 0)
        assertEquals(0.5f, dst[0], 0f); assertEquals(-1f, dst[1], 0f)
    }
}

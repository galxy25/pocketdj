package com.levi.pocketdj.mix.recording

import com.levi.pocketdj.audio.core.AacEncoder
import org.junit.Test
import org.junit.Assert.assertEquals

class AdtsScanTest {
    private fun frame(payload: Int) = AacEncoder.adtsHeader(payload, 44100, 2) + ByteArray(payload)

    @Test fun countsWholeFramesAndDropsTruncatedTail() {
        val bytes = frame(100) + frame(120) + frame(90).copyOf(50)
        val r = AdtsScan.scan(bytes)
        assertEquals(2, r.frames)
        assertEquals(44100, r.sampleRate)
        assertEquals(2 * 1024 * 1000 / 44100, r.durationMs)
    }

    @Test fun garbageOrEmptyIsZero() {
        assertEquals(0, AdtsScan.scan(ByteArray(0)).durationMs)
        assertEquals(0, AdtsScan.scan(ByteArray(64) { 7 }).frames)
    }
}

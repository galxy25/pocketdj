package com.levi.pocketdj.audio.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WavWriterTest {
    @Test fun pcm16HeaderAndSamples() {
        val pcm = PcmBuffer(44_100, 2, floatArrayOf(0f, 1f, -1f, 0.5f))
        val bytes = WavWriter.encode(pcm)
        val info = WavWriter.parse(bytes)!!
        assertEquals(1, info.format); assertEquals(2, info.channels); assertEquals(44_100, info.sampleRate)
        assertEquals(16, info.bits); assertEquals(8L, info.dataBytes)
        assertEquals(44 + 8, bytes.size)
        val bb = ByteBuffer.wrap(bytes, 44, 8).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0, bb.short.toInt()); assertEquals(32767, bb.short.toInt())
        assertEquals(-32767, bb.short.toInt()); assertEquals(16384, bb.short.toInt())
    }

    @Test fun float32RoundTripsExactlyAndClipDoesNotWrapInPcm16() {
        val src = floatArrayOf(0.123456f, -0.75f, 2f, -3f)
        val f = WavWriter.encode(PcmBuffer(48_000, 1, src), WavWriter.Format.FLOAT32)
        assertEquals(3, WavWriter.parse(f)!!.format)
        val fb = ByteBuffer.wrap(f, 44, 16).order(ByteOrder.LITTLE_ENDIAN)
        assertArrayEquals(src, FloatArray(4) { fb.float }, 0f)
        val p = WavWriter.encode(PcmBuffer(48_000, 1, src))
        val pb = ByteBuffer.wrap(p, 44, 8).order(ByteOrder.LITTLE_ENDIAN)
        pb.short; pb.short
        assertEquals(32767, pb.short.toInt()); assertEquals(-32767, pb.short.toInt())
    }

    @Test fun streamingPatchesSizesOnClose() {
        val f = File.createTempFile("wav", ".wav")
        val w = WavWriter.Streaming(f, 44_100, 2)
        w.append(FloatArray(100), 0, 100)
        w.append(FloatArray(60), 0, 60)
        w.close()
        val bytes = f.readBytes(); f.delete()
        val info = WavWriter.parse(bytes)!!
        assertEquals(320L, info.dataBytes)
        assertEquals(364, bytes.size)
        assertEquals(356, ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getInt(4))
    }

    @Test fun parseRejectsNonWav() { assertNull(WavWriter.parse(ByteArray(64))) ; assertNotNull(WavWriter.parse(WavWriter.encode(PcmBuffer(1, 1, FloatArray(1))))) }

    @Test fun adtsHeaderEncodesLengthRateAndChannels() {
        val h = AacEncoder.adtsHeader(payloadBytes = 300, sampleRate = 44_100, channels = 2)
        assertEquals(0xFF, h[0].toInt() and 0xFF); assertEquals(0xF0, h[1].toInt() and 0xF0)
        val freqIdx = (h[2].toInt() ushr 2) and 0xF
        assertEquals(4, freqIdx)
        assertEquals(1, (h[2].toInt() ushr 6) and 3) // AAC-LC
        val ch = ((h[2].toInt() and 1) shl 2) or ((h[3].toInt() ushr 6) and 3)
        assertEquals(2, ch)
        val len = ((h[3].toInt() and 3) shl 11) or ((h[4].toInt() and 0xFF) shl 3) or ((h[5].toInt() and 0xFF) ushr 5)
        assertEquals(307, len)
    }
}

package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sin

class StreamingResamplerTest {
    private fun signal(frames: Int, rate: Int, ch: Int = 2) =
        PcmBuffer(rate, ch, FloatArray(frames * ch) { i -> sin(i * 0.013).toFloat() * 0.8f + (i % 7) * 0.01f })

    /** Feed [src] in [chunks]-frame pieces (cycled), return everything emitted + the largest block seen. */
    private fun run(src: PcmBuffer, rate: Int, chunks: IntArray): Pair<FloatArray, Int> {
        val r = StreamingResampler(src.sampleRate, rate, src.channels)
        val out = ArrayList<Float>(); var biggest = 0
        val grab = { b: FloatArray, n: Int -> biggest = maxOf(biggest, n); for (i in 0 until n * src.channels) out += b[i] }
        var pos = 0; var k = 0
        while (pos < src.frames) {
            val n = minOf(chunks[k++ % chunks.size], src.frames - pos)
            r.process(src.samples.copyOfRange(pos * src.channels, (pos + n) * src.channels), n, grab)
            pos += n
        }
        r.finish(grab)
        return out.toFloatArray() to biggest
    }

    private fun assertMatchesOneShot(src: PcmBuffer, rate: Int, chunks: IntArray) {
        val expected = src.resampled(rate)
        val (got, _) = run(src, rate, chunks)
        assertEquals("length for ${src.sampleRate}->$rate chunks=${chunks.toList()}", expected.samples.size, got.size)
        for (i in got.indices) assertEquals("sample $i", expected.samples[i], got[i], 1e-6f)
    }

    @Test fun downsample48kTo44kMatchesOneShotForAnyChunking() {
        val src = signal(48_000 + 123, 48_000)
        for (c in listOf(intArrayOf(1), intArrayOf(3, 1, 7), intArrayOf(512), intArrayOf(4096), intArrayOf(1_000_000)))
            assertMatchesOneShot(src, 44_100, c)
    }

    @Test fun upsample44kTo48kAndOddRatiosMatchOneShot() {
        assertMatchesOneShot(signal(44_100, 44_100), 48_000, intArrayOf(999))
        assertMatchesOneShot(signal(10_000, 22_050), 44_100, intArrayOf(1, 2, 3, 5000))
        assertMatchesOneShot(signal(7_001, 96_000), 44_100, intArrayOf(64))   // ratio > 2: more than 2 carry frames
        assertMatchesOneShot(signal(5_000, 44_100, ch = 1), 16_000, intArrayOf(333))
    }

    @Test fun tinyAndSingleFrameInputsKeepTheEndClamp() {
        assertMatchesOneShot(signal(1, 48_000), 44_100, intArrayOf(1))
        assertMatchesOneShot(signal(2, 48_000), 44_100, intArrayOf(1))
        assertMatchesOneShot(signal(3, 44_100), 48_000, intArrayOf(1))
    }

    @Test fun sameRateIsAPassthroughAndEmptyIsEmpty() {
        val src = signal(1000, 44_100)
        val (got, _) = run(src, 44_100, intArrayOf(300))
        assertEquals(src.samples.toList(), got.toList())
        val r = StreamingResampler(48_000, 44_100)
        var calls = 0
        r.finish { _, _ -> calls++ }
        assertEquals(0, calls)
    }

    @Test fun outputBlocksAreBoundedRegardlessOfInputChunkSize() {
        val src = signal(300_000, 48_000)
        val (_, biggest) = run(src, 44_100, intArrayOf(250_000))
        assertTrue("block $biggest", biggest <= StreamingResampler.OUT_FRAMES)
    }

    @Test fun resampleHelperEqualsPcmBufferResampled() {
        val src = signal(20_000, 48_000)
        val a = StreamingResampler.resample(src, 44_100, chunkFrames = 777)
        val b = src.resampled(44_100)
        assertEquals(b.frames, a.frames)
        for (i in a.samples.indices) assertEquals(b.samples[i], a.samples[i], 1e-6f)
    }
}

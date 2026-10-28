package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.audio.core.PcmSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WaveformExtractorTest {
    /** Mono/stereo ramp source: frame i has amplitude amp(i) on every channel. */
    private class Fake(
        override val sampleRate: Int, override val channels: Int, private val frames: Long, private val amp: (Long) -> Float,
    ) : PcmSource {
        private var pos = 0L
        override val totalFrames get() = frames
        override val isComplete get() = true
        override val availableFrames get() = frames - pos
        override fun seek(frame: Long) { pos = frame }
        override fun read(dst: FloatArray, frames: Int): Int {
            if (pos >= totalFrames) return -1
            val n = minOf(frames.toLong(), totalFrames - pos).toInt()
            for (i in 0 until n) for (c in 0 until channels) dst[i * channels + c] = amp(pos + i) * (if (c == 0) 1f else 0.5f)
            pos += n
            return n
        }
    }

    @Test fun foldChecksCancellationEveryChunk() {
        val s = Fake(1000, 1, 100_000) { 0.5f }
        var calls = 0
        val r = runCatching { WaveformExtractor.fold(s, null, null, 10) { if (++calls == 2) throw java.util.concurrent.CancellationException() } }
        assertTrue(r.exceptionOrNull() is java.util.concurrent.CancellationException)
        assertEquals(2, calls)
    }

    @Test fun foldsToTargetCountNormalisedToTheLoudestBucket() {
        val s = Fake(1000, 2, 10_000) { i -> if (i < 5000) 0.25f else 0.5f }
        val p = WaveformExtractor.fold(s, null, null, 10)
        assertEquals(10, p.size)
        assertEquals(0.5f, p[0], 1e-6f)      // 0.25 / 0.5
        assertEquals(1.0f, p[9], 1e-6f)
    }

    @Test fun analogWindowOnlyReadsThisSongsSlice() {
        // 0..4 s silent-ish (0.1), 4..6 s loud (1.0), 6..10 s (0.1). Window the loud slice.
        val s = Fake(1000, 1, 10_000) { i -> if (i in 4000..5999) 1.0f else 0.1f }
        val p = WaveformExtractor.fold(s, startMs = 4000, lengthMs = 2000, targetCount = 4)
        assertEquals(4, p.size)
        for (v in p) assertEquals(1.0f, v, 1e-6f)
        // whole file would not be flat
        val whole = WaveformExtractor.fold(Fake(1000, 1, 10_000) { i -> if (i in 4000..5999) 1.0f else 0.1f }, null, null, 4)
        assertTrue(whole.min() < 1.0f)
    }

    @Test fun lengthIsClampedToTheFile() {
        val s = Fake(1000, 1, 3000) { 0.8f }
        val p = WaveformExtractor.fold(s, startMs = 2000, lengthMs = 60_000, targetCount = 5)
        assertEquals(5, p.size)
    }

    @Test fun silentEmptyAndUnreadableReturnEmpty() {
        assertEquals(0, WaveformExtractor.fold(Fake(1000, 1, 5000) { 0f }, null, null).size)
        assertEquals(0, WaveformExtractor.fold(Fake(1000, 1, 0) { 1f }, null, null).size)
        assertEquals(0, WaveformExtractor.fold(Fake(1000, 1, 5000) { 1f }, startMs = 99_000, lengthMs = null).size)
        assertEquals(0, WaveformExtractor.fold(Fake(1000, 1, 5000) { 1f }, null, null, targetCount = 0).size)
    }
}

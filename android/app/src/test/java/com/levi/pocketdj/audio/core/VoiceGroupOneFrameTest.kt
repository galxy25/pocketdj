package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceGroupOneFrameTest {
    private fun settle(vs: List<Voice>) {
        val s = FloatArray(2)
        repeat(6) { for (v in vs) { v.pump(); v.read(s, 0, Long.MIN_VALUE / 2); while (v.pump()) { } } }
    }

    @Test fun fourStemsStartOnTheSameRenderFrame() {
        val sr = 44_100
        val voices = listOf(100.0, 200.0, 300.0, 400.0).map { Voice(SyntheticPcmSource.tone(it, 200_000)) }
        // different phases would differ in value but all must be non-zero from the same frame
        voices.forEach { it.schedule(10_000) }
        settle(voices)
        val renderer = OfflineRenderer(sr, blockFrames = 333)
        val group = VoiceGroup(voices)
        assertTrue(group.allReady(1024))
        val tmp = FloatArray(333 * 2)
        val firstNonZero = IntArray(4) { -1 }
        var startFrame = -1L
        renderer.start { _, _ -> }
        renderer.renderFrames(1000) // advance the clock somewhere that is not a block boundary
        startFrame = group.startTogether(renderer.clock, 0.06)
        assertEquals(1000L + 2646, startFrame)
        renderer.start { out, n ->
            java.util.Arrays.fill(out, 0, n * 2, 0f)
            val base = renderer.clock.now()
            for ((i, v) in voices.withIndex()) {
                v.read(tmp, n, base)
                val f = OfflineRenderer.firstNonZeroFrame(tmp.copyOf(n * 2))
                if (f >= 0 && firstNonZero[i] < 0) firstNonZero[i] = (base + f - 1000).toInt()
                for (k in 0 until n * 2) out[k] += tmp[k]
            }
        }
        renderer.renderFrames(5000)
        assertTrue(firstNonZero.all { it >= 0 })
        // voices begin at file frame 10000 (non-zero for every tone): first sound is exactly the start frame
        assertEquals(1, firstNonZero.toSet().size)
        assertEquals(2646, firstNonZero[0])
    }

    @Test fun groupPauseAndSeekFanOut() {
        val voices = List(4) { Voice(SyntheticPcmSource.counter(10_000)) }
        val g = VoiceGroup(voices)
        g.seekAll(500); settle(voices)
        g.startAt(0)
        assertTrue(voices.all { it.isPlaying })
        g.pauseAll()
        assertTrue(voices.none { it.isPlaying })
        assertTrue(voices.all { it.bufferedFrames > 0 })
    }
}

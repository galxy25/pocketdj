package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceTest {
    /** Drive the 3-step schedule handshake + decode synchronously. */
    private fun Voice.settle(rounds: Int = 6) {
        val scratch = FloatArray(2)
        repeat(rounds) { pump(); read(scratch, 0, Long.MIN_VALUE / 2); while (pump()) { } }
    }

    private fun Voice.take(frames: Int, blockStart: Long = 0): FloatArray {
        val out = FloatArray(frames * 2)
        read(out, frames, blockStart)
        return out
    }

    private fun frames(out: FloatArray) = (0 until out.size / 2).map { SyntheticPcmSource.frameOf(out[2 * it]) }

    @Test fun playsSourceFramesInOrderFromSchedulePoint() {
        val v = Voice(SyntheticPcmSource.counter(10_000))
        v.schedule(100); v.settle()
        v.play()
        val out = v.take(50)
        assertEquals((100L until 150L).toList(), frames(out))
        assertEquals(150L, v.playerFrame)
        assertEquals(Voice.Status.PLAYING, v.status)
    }

    @Test fun idleVoiceOutputsSilenceAndHoldsPosition() {
        val v = Voice(SyntheticPcmSource.counter(1000))
        v.schedule(0); v.settle()
        val out = FloatArray(64) { 9f }
        assertEquals(Voice.Status.IDLE, v.read(out, 32, 0))
        assertTrue(out.all { it == 0f })
        assertEquals(0L, v.playerFrame)
    }

    @Test fun emptyRingOnIncompleteSourceYieldsSilencePlusUnderrunAndDoesNotAdvance() {
        val src = SyntheticPcmSource.counter(total = 10_000, available = 40).also { it.forceIncomplete = true }
        val v = Voice(src)
        v.schedule(0, to = 10_000, final = false); v.settle()
        v.play()
        val out = v.take(100)
        assertEquals(Voice.Status.UNDERRUN, v.status)
        assertTrue(v.underrun)
        assertEquals((0L until 40L).toList(), frames(out).take(40))
        assertTrue(out.drop(80).all { it == 0f })
        assertEquals(40L, v.playerFrame)
        v.take(10) // ring is empty now: pure hold
        assertEquals(40L, v.playerFrame)
        assertEquals(2L, v.underrunCount)
        // bytes arrive: the voice resumes exactly where it held
        src.available = 200
        v.settle()
        assertEquals((40L until 60L).toList(), frames(v.take(20)))
        assertFalse(v.underrun)
    }

    @Test fun appendExtendsAGrowingWindowWithoutEnding() {
        val src = SyntheticPcmSource.counter(total = 1000, available = 100).also { it.forceIncomplete = true }
        val v = Voice(src)
        v.schedule(0, to = 100, final = false); v.settle(); v.play()
        v.take(100)
        v.take(10)
        assertEquals(Voice.Status.UNDERRUN, v.status) // window end reached but not final => hold, not ended
        src.available = 300
        v.append(300, final = false); v.settle()
        assertEquals((100L until 110L).toList(), frames(v.take(10)))
    }

    @Test fun completeSourceAtEndReturnsEnded() {
        val v = Voice(SyntheticPcmSource.counter(64))
        v.schedule(0); v.settle(); v.play()
        v.take(64)
        assertEquals(Voice.Status.PLAYING, v.status)
        v.take(16)
        assertEquals(Voice.Status.ENDED, v.status)
        assertFalse(v.underrun)
    }

    @Test fun seekReplacesBufferedAudioWithoutStaleFrames() {
        val v = Voice(SyntheticPcmSource.counter(100_000))
        v.schedule(0); v.settle(); v.play()
        v.take(10)
        v.seek(5000); v.settle()
        assertEquals((5000L until 5010L).toList(), frames(v.take(10)))
    }

    @Test fun scheduledStartLandsOnTheExactRenderFrame() {
        val v = Voice(SyntheticPcmSource.counter(10_000))
        v.schedule(0); v.settle()
        v.play(atRenderFrame = 1000)
        val a = FloatArray(512 * 2)
        assertEquals(Voice.Status.SCHEDULED, v.read(a, 512, 0))
        assertTrue(a.all { it == 0f })
        val b = FloatArray(512 * 2)
        assertEquals(Voice.Status.PLAYING, v.read(b, 512, 512)) // block covers 512..1023
        assertEquals(488, OfflineRenderer.firstNonZeroFrame(b)) // frame 1000
        assertEquals(0L, SyntheticPcmSource.frameOf(b[488 * 2]))
    }

    @Test fun loopWrapsFrameExactly() {
        val v = Voice(SyntheticPcmSource.counter(10_000))
        v.schedule(1000); v.settle()
        v.setLoop(1000, 1100); v.settle(); v.play()
        val all = ArrayList<Long>()
        repeat(5) { all += frames(v.take(64)) }
        for ((i, f) in all.withIndex()) assertEquals("at $i", 1000L + (i % 100), f)
        assertEquals(1000L + 320 % 100, v.playerFrame)
    }

    @Test fun clickAtLoopStartRepeatsEveryLoopLength() {
        val v = Voice(SyntheticPcmSource.clicks(5000, setOf(200L)))
        v.schedule(200); v.settle()
        v.setLoop(200, 500); v.settle(); v.play()
        val out = FloatArray(0).toMutableList()
        repeat(10) { out += v.take(100).toList() }
        val clickFrames = (0 until out.size / 2).filter { out[2 * it] != 0f }
        assertEquals(listOf(0, 300, 600, 900), clickFrames)
    }

    @Test fun gainRampNeverStepsMoreThanOneOverBlockFrames() {
        val src = SyntheticPcmSource(44_100, 2, 100_000) { _, _ -> 1f }
        val v = Voice(src)
        v.schedule(0); v.settle(); v.play()
        val n = 256
        v.take(n)
        v.setGain(0f)
        val out = v.take(n)
        var prev = 1f
        var maxStep = 0f
        for (i in 0 until n) { maxStep = maxOf(maxStep, kotlin.math.abs(out[2 * i] - prev)); prev = out[2 * i] }
        assertTrue("step $maxStep", maxStep <= 1f / n + 1e-6f)
        assertEquals(0f, v.take(n)[2 * (n - 1)], 1e-6f)
    }

    @Test fun monoAndOtherRateSourcesAreConvertedToStereoAtSinkRate() {
        val mono = SyntheticPcmSource(44_100, 1, 1000) { f, _ -> (f + 1) * 1e-6f }
        val v = Voice(mono)
        v.schedule(0); v.settle(); v.play()
        val out = v.take(10)
        for (i in 0 until 10) { assertEquals(out[2 * i], out[2 * i + 1], 0f); assertEquals(i.toLong(), SyntheticPcmSource.frameOf(out[2 * i])) }

        val half = SyntheticPcmSource(22_050, 1, 1000) { f, _ -> f * 0.001f }
        val w = Voice(half, sampleRate = 44_100)
        w.schedule(0); w.settle(); w.play()
        val o = w.take(8)
        // 2x upsample: even frames land on source samples, odd frames interpolate between them
        assertEquals(0f, o[0], 1e-6f); assertEquals(0.0005f, o[2], 1e-6f); assertEquals(0.001f, o[4], 1e-6f)
        assertEquals(2000L, w.totalFrames)
    }

    @Test fun readNeverAllocates() {
        val v = Voice(SyntheticPcmSource.counter(1_000_000))
        v.schedule(0); v.settle(); v.play()
        val out = FloatArray(512 * 2)
        val mx = Class.forName("java.lang.management.ManagementFactory").getMethod("getThreadMXBean").invoke(null)
        val m = Class.forName("com.sun.management.ThreadMXBean").getMethod("getThreadAllocatedBytes", Long::class.javaPrimitiveType)
        fun allocated(): Long = m.invoke(mx, Thread.currentThread().id) as Long
        repeat(200) { v.read(out, 512, it * 512L) } // warm up
        val before = allocated()
        repeat(1000) { v.read(out, 512, it * 512L) }
        val grew = allocated() - before
        assertTrue("allocated $grew bytes in 1000 reads", grew < 4096)
    }
}

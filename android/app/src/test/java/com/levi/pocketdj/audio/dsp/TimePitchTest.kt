package com.levi.pocketdj.audio.dsp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TimePitchTest {
    private val sr = 44_100

    /** Feed [seconds] of [freq] sine in 1024-frame blocks, collect all output (incl. tail). */
    private fun runTone(tp: TimePitch, freq: Float, seconds: Float): FloatArray {
        val total = (seconds * sr).toInt()
        val out = ArrayList<Float>()
        val tmp = FloatArray(8192 * 2)
        var fed = 0
        while (fed < total) {
            val n = minOf(1024, total - fed)
            tp.push(sine(freq, n, 0.7f, fed), n)
            fed += n
            while (tp.availableFrames > 0) { val g = tp.pull(tmp, 8192); for (i in 0 until g * 2) out.add(tmp[i]) }
        }
        tp.endOfStream()
        while (tp.availableFrames > 0) { val g = tp.pull(tmp, 8192); for (i in 0 until g * 2) out.add(tmp[i]) }
        return out.toFloatArray()
    }

    private fun zeroCrossHz(a: FloatArray, fromFrame: Int, toFrame: Int): Double {
        var c = 0
        for (i in fromFrame + 1 until toFrame) if (a[2 * (i - 1)] < 0f && a[2 * i] >= 0f) c++
        return c * sr.toDouble() / (toFrame - fromFrame)
    }

    @Test fun passthroughAtUnity() {
        val tp = TimePitch(sr)
        val out = runTone(tp, 440f, 1f)
        assertEquals(sr.toDouble(), (out.size / 2).toDouble(), 2.0)
    }

    @Test fun speed15ConsumesOnePointFiveXInput() {
        val tp = TimePitch(sr).apply { setSpeed(1.5f) }
        val out = runTone(tp, 440f, 3f)
        val expected = 3 * sr / 1.5
        assertEquals(expected, (out.size / 2).toDouble(), expected * 0.02)
    }

    @Test fun speedKeepsPitch() {
        val tp = TimePitch(sr).apply { setSpeed(1.5f) }
        val out = runTone(tp, 440f, 3f)
        val f = zeroCrossHz(out, 20_000, out.size / 2 - 20_000)
        assertEquals(440.0, f, 440 * 0.03)
    }

    @Test fun pitchPlus12DoublesFrequencyAndKeepsLength() {
        val tp = TimePitch(sr).apply { setPitchSemitones(12f) }
        val out = runTone(tp, 440f, 3f)
        assertEquals(3.0 * sr, (out.size / 2).toDouble(), 3.0 * sr * 0.02)
        val f = zeroCrossHz(out, 20_000, out.size / 2 - 20_000)
        assertEquals(880.0, f, 880 * 0.03)
    }

    @Test fun speedAndPitchAreIndependent() {
        val tp = TimePitch(sr).apply { setSpeed(0.75f); setPitchSemitones(-12f) }
        val out = runTone(tp, 880f, 3f)
        val expected = 3 * sr / 0.75
        assertEquals(expected, (out.size / 2).toDouble(), expected * 0.02)
        assertEquals(440.0, zeroCrossHz(out, 20_000, out.size / 2 - 20_000), 440 * 0.03)
    }

    @Test fun speedIsClampedToRange() {
        val tp = TimePitch(sr).apply { setSpeed(5f) }
        assertEquals(2f, tp.speed, 0f)
        tp.setSpeed(0.1f)
        assertEquals(0.5f, tp.speed, 0f)
    }

    @Test fun flushClearsTails() {
        val tp = TimePitch(sr).apply { setSpeed(1.5f) }
        tp.push(sine(440f, 4096, 0.7f), 4096)
        assertTrue(tp.availableFrames > 0)
        tp.flush()
        assertEquals(0, tp.availableFrames)
        tp.endOfStream()
        assertEquals(0, tp.availableFrames)
    }

    @Test fun liveSpeedChangeKeepsInFlightAudio() {
        val tp = TimePitch(sr)
        tp.setSpeed(1.2f)
        tp.push(sine(440f, 8192, 0.7f), 8192)
        val before = tp.availableFrames
        tp.setSpeed(1.1f)
        tp.push(sine(440f, 1024, 0.7f, 8192), 1024)
        assertTrue(tp.availableFrames >= before) // nothing dropped by the parameter change
    }

    @Test fun continuousGlideDoesNotRebuildSonicEveryStep() {
        val tp = TimePitch(sr)
        tp.setSpeed(1.0f); tp.push(sine(440f, 512, 0.5f), 512)
        val base = tp.reconfigureCount
        var s = 1.0f
        for (k in 0 until 80) { // 10 Hz-style glide 1.00 -> 1.06
            s += 0.06f / 80f
            tp.setSpeed(s)
            tp.push(sine(440f, 4410, 0.5f, 512 + k * 4410), 4410)
        }
        assertTrue("reconfigures ${tp.reconfigureCount - base}", tp.reconfigureCount - base <= 30)
    }

    // ---------------------------------------------------------------- TimeStretcher contract (ANS-MIX-2)

    /** Stand-in kernel: nearest-sample resampler (rate = in/out) with a fixed delay line like the real one. */
    private class FakeBackend(override val inputLatency: Int = 1000, override val outputLatency: Int = 500) : RtStretchBackend {
        var pitch = 0.0; var resets = 0; var closed = false
        val calls = ArrayList<Pair<Int, Int>>()
        override fun setPitchSemitones(semitones: Double) { pitch = semitones }
        override fun process(input: FloatArray, inFrames: Int, out: FloatArray, outFrames: Int) {
            calls += inFrames to outFrames
            for (i in 0 until outFrames) {
                val src = minOf(inFrames - 1, (i.toLong() * inFrames / outFrames).toInt())
                out[2 * i] = input[2 * src]; out[2 * i + 1] = input[2 * src + 1]
            }
        }
        override fun reset() { resets++ }
        override fun close() { closed = true }
    }

    @Test fun factoryFallsBackToSonicWhenTheNativeLibraryIsAbsent() {
        val t = TimeStretchers.create(sr, 2048, nativeAvailable = false)
        assertTrue(t is TimePitch)
        // and the JVM test environment really has no libpdjdsp
        assertTrue(TimeStretchers.create(sr, 2048) is TimePitch)
    }

    @Test fun ratioPlannerHasNoLongRunDriftAtAwkwardTempos() {
        for (speed in listOf(0.7f, 1.0f, 1.0833f, 1.3f, 1.49f, 2.0f, 0.5f)) {
            val p = RatioPlanner()
            var out = 0L; var inn = 0L
            repeat(2000) { out += p.outFramesFor(1024, speed); inn += 1024 }
            assertEquals("speed $speed", inn / speed.toDouble(), out.toDouble(), 1.5)
        }
    }

    @Test fun ratioPlannerFollowsPerBlockTempoChangesAndStaysPositive() {
        val p = RatioPlanner()
        assertEquals(1024, p.outFramesFor(1024, 1f))
        assertEquals(512, p.outFramesFor(1024, 2f))
        assertEquals(2048, p.outFramesFor(1024, 0.5f))
        assertTrue(p.outFramesFor(1, 2f) >= 1) // tiny block at max speed never asks for 0 frames
    }

    @Test fun nativeStretcherEmitsInputOverSpeedFramesPerBlockWithoutReconfiguring() {
        val be = FakeBackend()
        val t = NativeTimePitch(sr, 2048, backend = be)
        t.setSpeed(1.3f)
        val blk = sine(440f, 1024, 0.5f)
        repeat(100) { t.push(blk, 1024) }
        val expect = 100 * 1024 / 1.3
        assertEquals(expect, t.availableFrames.toDouble(), 2.0)
        // glide the tempo: every block still maps 1:1 onto one backend call (no rebuild, no extra flush)
        be.calls.clear()
        var s = 1.3f
        repeat(50) { s -= 0.01f; t.setSpeed(s); t.push(blk, 1024) }
        assertEquals(50, be.calls.size)
        assertEquals(0, be.resets)
        assertTrue(be.calls.map { it.second }.distinct().size > 1) // the ratio really changed per block
    }

    @Test fun nativeStretcherClampsSpeedAndForwardsPitchOnlyWhenItChanges() {
        val be = FakeBackend()
        val t = NativeTimePitch(sr, 2048, backend = be)
        t.setSpeed(9f); assertEquals(2f, t.speed, 0f)
        t.setSpeed(0.01f); assertEquals(0.5f, t.speed, 0f)
        t.setPitchSemitones(3f)
        t.push(sine(440f, 256, 0.5f), 256)
        assertEquals(3.0, be.pitch, 0.0)
        be.pitch = -99.0
        t.push(sine(440f, 256, 0.5f), 256) // unchanged -> not re-sent
        assertEquals(-99.0, be.pitch, 0.0)
    }

    @Test fun nativeLatencyIsConstantAcrossTempoAndFlush() {
        val be = FakeBackend(inputLatency = 2400, outputLatency = 1200)
        val t = NativeTimePitch(sr, 2048, backend = be)
        assertEquals(2400 + 1200, t.algorithmicLatencyFrames())
        t.setSpeed(1.5f)
        assertEquals((2400 / 1.5).toInt() + 1200, t.algorithmicLatencyFrames())
        t.push(sine(440f, 1024, 0.5f), 1024)
        assertEquals(t.algorithmicLatencyFrames() + t.availableFrames, t.latencyFrames())
        val before = t.algorithmicLatencyFrames()
        t.flush()
        assertEquals(0, t.availableFrames)
        assertEquals(1, be.resets)
        assertEquals(before, t.algorithmicLatencyFrames())
    }

    @Test fun nativePushLargerThanMaxPushIsChunkedAndLossless() {
        val be = FakeBackend()
        val t = NativeTimePitch(sr, 1024, backend = be)
        t.push(sine(440f, 5000, 0.5f), 5000)
        assertEquals(5, be.calls.size)
        assertEquals(5000, t.availableFrames)
        val out = FloatArray(6000 * 2)
        assertEquals(5000, t.pull(out, 6000))
        assertEquals(0, t.availableFrames)
        t.close(); t.close()
        assertTrue(be.closed)
    }

    @Test fun nativeRingOverflowDropsOldestAndCounts() {
        val t = NativeTimePitch(sr, 1024, ringFrames = 2048, backend = FakeBackend())
        repeat(5) { t.push(sine(440f, 1024, 0.5f), 1024) }
        assertEquals(2048, t.availableFrames)
        assertEquals(5L * 1024 - 2048, t.overflowFrames)
    }
}

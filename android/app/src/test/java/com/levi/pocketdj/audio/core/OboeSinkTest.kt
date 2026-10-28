package com.levi.pocketdj.audio.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

class OboeSinkTest {
    /** Ring-less fake: free space is a settable budget; open() outcomes are scripted. */
    private class FakeBackend(@Volatile var budget: Int = 4096) : OboeBackend {
        @Volatile var disconnectedFlag = false
        val openResults = java.util.concurrent.LinkedBlockingQueue<Boolean>()
        val opens = AtomicInteger()
        val frames = CopyOnWriteArrayList<Float>() // left channel of everything written, in order
        @Volatile var closed = false
        @Volatile var released = false
        override fun open(): Boolean {
            opens.incrementAndGet()
            val ok = openResults.poll() ?: true
            if (ok) disconnectedFlag = false
            return ok
        }
        override fun close() { closed = true }
        override fun release() { released = true }
        override fun write(buf: FloatArray, frames: Int): Int {
            val n = minOf(frames, budget)
            for (i in 0 until n) this.frames.add(buf[2 * i])
            budget -= n
            return n
        }
        override fun freeFrames() = budget
        override fun bufferedFrames() = 64
        override fun underruns() = 3L
        override fun disconnected() = disconnectedFlag
        override fun streamLatencyFrames() = 192
    }

    private var sink: OboeSink? = null
    @Before fun quiet() { AudioDiag.emit = { }; AudioDiag.reset() }
    @After fun tearDown() { sink?.stop() }

    private fun waitFor(ms: Long = 3000, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { if (cond()) return true; Thread.sleep(2) }
        return cond()
    }

    /** Rising ramp so any gap or duplication shows up as a discontinuity. */
    private class RampRenderer : BlockRenderer {
        var next = 0
        override fun render(out: FloatArray, frames: Int) { for (i in 0 until frames) { out[2 * i] = next.toFloat(); out[2 * i + 1] = next.toFloat(); next++ } }
    }

    @Test fun startFeedsBlocksInOrderWithNoGapsAndAdvancesTheClock() {
        val b = FakeBackend(budget = 2048)
        val s = OboeSink(44_100, 256) { b }.also { sink = it }
        s.start(RampRenderer())
        assertTrue(waitFor { b.frames.size == 2048 }) // ring full -> feeder parks
        assertEquals(2048L, s.clock.now())
        for (i in 0 until 2048) assertEquals(i.toFloat(), b.frames[i], 0f)
        b.budget = 512 // the device drained space -> feeder resumes exactly where it left off
        assertTrue(waitFor { b.frames.size == 2560 })
        assertEquals(2559f, b.frames.last(), 0f)
        assertTrue(s.isRendering)
        assertEquals(64 + 192, s.latencyFrames())
        assertEquals(3L, s.underruns)
    }

    @Test fun feederNeverWritesAPartialBlockWhenTheRingIsTight() {
        val b = FakeBackend(budget = 255) // < one block
        val s = OboeSink(44_100, 256) { b }.also { sink = it }
        s.start(RampRenderer())
        Thread.sleep(60)
        assertEquals(0, b.frames.size)
        assertEquals(0L, s.clock.now())
    }

    @Test fun disconnectRebuildsWithBackoffAndResumesRendering() {
        val b = FakeBackend(budget = 1 shl 30)
        val s = OboeSink(44_100, 256) { b }.also { sink = it }
        val routed = CopyOnWriteArrayList<Boolean>()
        s.onRoutingChanged = { routed += it }
        s.start(RampRenderer())
        assertTrue(waitFor { s.clock.now() > 1000 })
        // the route vanishes; the next two reopen attempts fail (BT handoff), the third works
        b.openResults.add(false); b.openResults.add(false); b.openResults.add(true)
        val opensBefore = b.opens.get()
        val t0 = System.nanoTime()
        b.disconnectedFlag = true
        assertTrue(waitFor { routed.isNotEmpty() })
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertEquals(listOf(true), routed.toList())
        assertEquals(opensBefore + 3, b.opens.get())
        assertTrue("rebuild took ${ms}ms", ms < 300 + 250) // scripted 20+40 ms backoff + slack for a loaded CI box
        val before = s.clock.now()
        assertTrue("rendering resumed", waitFor { s.clock.now() > before + 1000 })
        assertTrue(s.isRendering)
        assertEquals(1, AudioDiag.count("play", "stream-rebuilt"))
        assertEquals(2, AudioDiag.count("play.skip", "stream-rebuild-failed"))
    }

    @Test fun renderingStaysFalseWhileTheStreamIsDown() {
        val b = FakeBackend(budget = 1 shl 30)
        val s = OboeSink(44_100, 256) { b }.also { sink = it }
        s.start(RampRenderer())
        assertTrue(waitFor { s.isRendering })
        repeat(500) { b.openResults.add(false) }
        b.disconnectedFlag = true
        assertTrue(waitFor { !s.isRendering })
        val frozen = s.clock.now()
        Thread.sleep(80)
        assertEquals("no blocks render while the device is gone", frozen, s.clock.now())
    }

    @Test fun retryBackoffSchedule() {
        assertEquals(listOf(20L, 40L, 80L, 100L, 100L), (0..4).map { OboeSink.retryDelayMs(it) })
        assertTrue(OboeSink.retryDelayMs(0) + OboeSink.retryDelayMs(1) + OboeSink.retryDelayMs(2) <= 300)
        assertEquals(100L, OboeSink.retryDelayMs(1000))
    }

    @Test fun failedInitialOpenLeavesTheSinkIdleAndStartRetryable() {
        val b = FakeBackend(budget = 1 shl 30)
        b.openResults.add(false)
        val s = OboeSink(44_100, 256) { b }.also { sink = it }
        s.start(RampRenderer())
        assertFalse(s.isRendering)
        assertTrue(b.released)
        s.start(RampRenderer()) // the owner's watchdog retries
        assertTrue(waitFor { s.isRendering && b.frames.size > 0 })
    }

    @Test fun stopClosesTheBackendAndSilencesTheFeeder() {
        val b = FakeBackend(budget = 1 shl 30)
        val s = OboeSink(44_100, 256) { b }.also { sink = it }
        s.start(RampRenderer())
        assertTrue(waitFor { s.clock.now() > 0 })
        s.stop()
        assertTrue(b.closed && b.released)
        assertFalse(s.isRendering)
        val n = b.frames.size
        Thread.sleep(40)
        assertEquals(n, b.frames.size)
        assertEquals(0, s.latencyFrames())
    }

    @Test fun startOnARunningSinkIsANoOp() {
        val b = FakeBackend(budget = 1 shl 30)
        val creates = AtomicInteger()
        val s = OboeSink(44_100, 256) { creates.incrementAndGet(); b }.also { sink = it }
        s.start(RampRenderer()); s.start(RampRenderer())
        assertEquals(1, creates.get())
    }
}

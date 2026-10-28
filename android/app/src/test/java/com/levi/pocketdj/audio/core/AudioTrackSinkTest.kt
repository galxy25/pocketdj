package com.levi.pocketdj.audio.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

class AudioTrackSinkTest {
    private class FakeTrack : TrackHandle {
        override val underrunCount = 0
        override val bufferSizeInFrames = 1024
        override fun play() {}
        override fun write(buf: FloatArray, count: Int): Int { Thread.sleep(1); return count }
        override fun stop() {}
        override fun release() {}
    }
    private class FakeRoutes : RouteWatcher {
        @Volatile var change: (() -> Unit)? = null
        override fun register(onChange: () -> Unit) { change = onChange }
        override fun unregister() { change = null }
    }

    private var sink: AudioTrackSink? = null
    @Before fun quiet() { AudioDiag.emit = { }; AudioDiag.reset() }
    @After fun tearDown() { sink?.stop() }

    private fun until(ms: Long = 3000, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { if (cond()) return true; Thread.sleep(2) }
        return cond()
    }

    @Test fun failedRecreateRecoversByItselfAndReReportsRouting() {
        val calls = AtomicInteger()
        val routes = FakeRoutes()
        val s = AudioTrackSink(44_100, 128, {
            val n = calls.incrementAndGet()
            if (n in 2..4) throw IllegalStateException("bt handoff") // initial build is call 1
            FakeTrack()
        }, routes, retryInitialMs = 5, retryMaxMs = 20)
        sink = s
        val reports = CopyOnWriteArrayList<Boolean>()
        s.onRoutingChanged = { reports += it }
        s.start { out, n -> java.util.Arrays.fill(out, 0, n * 2, 0.1f) }
        assertTrue(until { s.isRendering })

        routes.change!!.invoke()
        assertTrue("recovered without a restart", until { calls.get() >= 5 && s.isRendering })
        assertEquals(false, reports.first())
        assertEquals(true, reports.last())
        val t0 = s.clock.now()
        assertTrue("clock advances again", until { s.clock.now() > t0 })
    }

    @Test fun startOnARunningSinkIsANoOp() {
        val calls = AtomicInteger()
        val s = AudioTrackSink(44_100, 128, { calls.incrementAndGet(); FakeTrack() }, FakeRoutes())
        sink = s
        s.start { _, _ -> }; s.start { _, _ -> }
        assertEquals(1, calls.get())
    }

    @Test fun throwingRendererIsRecordedAndTheLoopSurvives() {
        val s = AudioTrackSink(44_100, 128, { FakeTrack() }, FakeRoutes(), retryInitialMs = 5)
        sink = s
        val boom = AtomicInteger()
        s.start { _, _ -> if (boom.incrementAndGet() == 1) throw IllegalStateException("graph bug") }
        assertTrue(until { AudioDiag.count("stop", "render-exception") >= 1 })
        assertTrue(until { boom.get() > 2 && s.isRendering })
    }

    @Test fun initialBuildFailureLeavesNotRenderingAndStartCanBeRetried() {
        val calls = AtomicInteger()
        val s = AudioTrackSink(44_100, 128, { if (calls.incrementAndGet() == 1) throw IllegalStateException("x") else FakeTrack() }, FakeRoutes())
        sink = s
        s.start { _, _ -> }
        assertFalse(s.isRendering)
        s.start { _, _ -> }
        assertTrue(until { s.isRendering })
    }
}

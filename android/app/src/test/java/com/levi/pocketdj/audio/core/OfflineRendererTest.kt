package com.levi.pocketdj.audio.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OfflineRendererTest {
    @Test fun clockAdvancesWithEveryRenderedFrameAndBlocksSeeNothingTornAcrossChunks() {
        val r = OfflineRenderer(44_100, blockFrames = 100)
        val starts = mutableListOf<Long>()
        r.start { out, n -> starts += r.clock.now(); for (i in 0 until n) { out[2 * i] = 1f; out[2 * i + 1] = 1f } }
        val out = r.renderFrames(250)
        assertEquals(500, out.size)
        assertTrue(out.all { it == 1f })
        assertEquals(listOf(0L, 100L, 200L), starts)
        assertEquals(250L, r.clock.now())
    }

    @Test fun startStopTogglesIsRendering() {
        val r = OfflineRenderer()
        assertFalse(r.isRendering)
        r.start { _, _ -> }
        assertTrue(r.isRendering)
        r.stop()
        assertFalse(r.isRendering)
    }

    @Test fun firstNonZeroFrameFindsEitherChannel() {
        assertEquals(2, OfflineRenderer.firstNonZeroFrame(floatArrayOf(0f, 0f, 0f, 0f, 0f, 0.5f)))
        assertEquals(-1, OfflineRenderer.firstNonZeroFrame(FloatArray(8)))
    }

    @Test fun clockConversions() {
        val c = RenderClock(48_000)
        c.advance(1000)
        assertEquals(1000L + 2880, c.frameAfter(0.06))
        assertEquals(1.0, c.framesToSeconds(48_000), 0.0)
    }
}

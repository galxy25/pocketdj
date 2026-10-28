package com.levi.pocketdj.mix.recording

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue

class TapSinkTest {
    @Test fun neverDropsWhileConsumerKeepsUp() {
        val tap = RecordingTapSink(capacityFrames = 1024)
        tap.setCapturing(true)
        val block = FloatArray(512 * 2) { it.toFloat() }
        val dst = FloatArray(2048)
        var total = 0
        repeat(50) {
            tap.onHouse(block, 512)
            total += tap.drain(dst, dst.size)
        }
        assertEquals(0L, tap.droppedFloats)
        assertEquals(50 * 1024, total)
    }

    @Test fun dropsAreCountedWhenConsumerStalls() {
        val tap = RecordingTapSink(capacityFrames = 1024)
        val block = FloatArray(512 * 2)
        repeat(3) { tap.onHouse(block, 512) } // 2 fit, third dropped whole
        assertEquals(1024L, tap.droppedFloats)
        assertEquals(2048, tap.queuedFloats)
    }

    @Test fun capturingFlagGatesOnlyTheFlagAndClearDropsStale() {
        val tap = RecordingTapSink(capacityFrames = 1024)
        assertFalse(tap.isCapturing)
        tap.setCapturing(true); assertTrue(tap.isCapturing)
        tap.onHouse(FloatArray(8), 4)
        tap.clear()
        assertEquals(0, tap.queuedFloats)
    }

    @Test fun drainPreservesOrderAcrossWrap() {
        val tap = RecordingTapSink(capacityFrames = 4)
        val dst = FloatArray(8)
        tap.onHouse(floatArrayOf(1f, 2f, 3f, 4f, 5f, 6f), 3); tap.drain(dst, 4)
        tap.onHouse(floatArrayOf(7f, 8f, 9f, 10f, 11f, 12f), 3)
        val n = tap.drain(dst, 8)
        assertEquals(listOf(5f, 6f, 7f, 8f, 9f, 10f, 11f, 12f).take(n), dst.take(n))
    }
}

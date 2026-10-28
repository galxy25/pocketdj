package com.levi.pocketdj.studio.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MultitrackClockTest {
    private var now = 1_000_000_000L
    private val clock = MultitrackClock { now }

    @Test fun zeroBeforeStartAndAfterStop() {
        assertEquals(0.0, clock.currentSeconds, 0.0)
        clock.start()
        assertTrue(clock.isRunning)
        now += 2_500_000_000L
        assertEquals(2.5, clock.currentSeconds, 1e-9)
        clock.stop()
        assertFalse(clock.isRunning)
        assertEquals(0.0, clock.currentSeconds, 0.0)
    }

    @Test fun preRollBeforeFutureStartReadsZero() {
        clock.start(atNanos = now + 500_000_000L) // shared start host-time in the future
        assertEquals(0.0, clock.currentSeconds, 0.0)
        now += 700_000_000L
        assertEquals(0.2, clock.currentSeconds, 1e-9)
    }

    @Test fun latencyIsSubtractedSoCursorTracksAudibleAudio() {
        clock.latencyMs = 100
        clock.start()
        now += 50_000_000L
        assertEquals(0.0, clock.currentSeconds, 0.0) // still inside the output latency
        now += 450_000_000L
        assertEquals(0.4, clock.currentSeconds, 1e-9)
    }

    @Test fun timelinePositionAddsSeekOffsetAndClampsToLength() {
        assertEquals(10_000 + 1_500, MultitrackClock.positionMs(10_000, 1.5, lengthMs = 60_000))
        assertEquals(60_000, MultitrackClock.positionMs(59_000, 5.0, lengthMs = 60_000))
        assertEquals(0, MultitrackClock.positionMs(0, 3.0, lengthMs = 0))
    }

    @Test fun loopPositionStartsAtLoopStartAndWrapsModuloRegion() {
        // Loop 4000..8000 ms (4 s region), offset ignored while looping.
        assertEquals(4_000, MultitrackClock.positionMs(30_000, 0.0, 60_000, 4_000, 8_000, true))
        assertEquals(5_000, MultitrackClock.positionMs(30_000, 1.0, 60_000, 4_000, 8_000, true))
        assertEquals(5_000, MultitrackClock.positionMs(30_000, 5.0, 60_000, 4_000, 8_000, true))
        // A degenerate region is not a loop.
        assertEquals(31_000, MultitrackClock.positionMs(30_000, 1.0, 60_000, 8_000, 8_000, true))
    }

    @Test fun timelineMsReadsTheClock() {
        clock.start()
        now += 2_000_000_000L
        assertEquals(12_000, clock.timelineMs(10_000, 60_000))
    }
}

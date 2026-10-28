package com.levi.pocketdj.screens.producer.tracks

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LoopRegionMathTest {
    @Test fun timelineCoordinateRoundTrip() {
        assertEquals(96f, LoopRegionMath.msToDp(2_000, 48f), 1e-4f)
        assertEquals(2_000, LoopRegionMath.dpToMs(96f, 48f))
        assertEquals(0, LoopRegionMath.dpToMs(10f, 0f))
    }

    @Test fun dragStartClampsAtZeroAndMinLengthBeforeEnd() {
        assertEquals(0, LoopRegionMath.dragStart(1_000, 5_000, -500f, 48f, 120.0, false))
        assertEquals(4_750, LoopRegionMath.dragStart(1_000, 5_000, 9_999f, 48f, 120.0, false))
        assertEquals(2_000, LoopRegionMath.dragStart(1_000, 5_000, 48f, 48f, 120.0, false))
    }

    @Test fun dragEndKeepsMinLengthAndStaysInArrangement() {
        assertEquals(1_250, LoopRegionMath.dragEnd(1_000, 5_000, -9_999f, 48f, 120.0, false, 10_000))
        assertEquals(10_000, LoopRegionMath.dragEnd(1_000, 5_000, 9_999f, 48f, 120.0, false, 10_000))
        assertEquals(6_000, LoopRegionMath.dragEnd(1_000, 5_000, 48f, 48f, 120.0, false, 10_000))
    }

    @Test fun beatMatchSnapsHandlesToTheGrid() {
        // 120 bpm = 500 ms/beat; 1 dp = 20.8 ms at 48 px/s.
        assertEquals(1_500, LoopRegionMath.dragEnd(1_000, 1_200, 5f, 48f, 120.0, true, 0)) // 1,304 -> 1,500
        assertEquals(1_000, LoopRegionMath.snap(1_120, 120.0, true))
        assertEquals(1_120, LoopRegionMath.snap(1_120, 120.0, false))
    }

    @Test fun defaultRegionIsTwoBarsFromCursorClampedToLength() {
        assertEquals(4_000 to 8_000, LoopRegionMath.defaultRegion(4_000, 60_000, 120.0)) // 8 beats = 4 s
        val tail = LoopRegionMath.defaultRegion(9_000, 10_000, 120.0)
        assertEquals(9_000, tail.first); assertEquals(10_000, tail.second)
        assertTrue(LoopRegionMath.isUsable(tail.first, tail.second))
        assertFalse(LoopRegionMath.isUsable(1_000, 1_100))
    }
}

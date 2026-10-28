package com.levi.pocketdj.screens.nowplaying

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RecordPlayerMathTest {
    @Test fun rpmMapsBpmOverFourWithClamps() {
        assertEquals(30.0, RecordMath.rpm(120.0), 1e-9)
        assertEquals(8.0, RecordMath.rpm(10.0), 1e-9)      // floor
        assertEquals(120.0, RecordMath.rpm(900.0), 1e-9)   // ceiling
        assertEquals(0.5, RecordMath.revsPerSecond(120.0), 1e-9)
    }

    @Test fun fallsBackTo33AndAThirdWhenBpmUnknownOrNonPositive() {
        assertEquals(100.0 / 3.0, RecordMath.rpm(null), 1e-9)
        assertEquals(100.0 / 3.0, RecordMath.rpm(0.0), 1e-9)
        assertEquals(100.0 / 3.0, RecordMath.rpm(-5.0), 1e-9)
    }

    @Test fun manifestBeatGridBeatsCatalogBpm() {
        assertEquals(128.0, RecordMath.effectiveBpm(128.0, 100.0)!!, 0.0)
        assertEquals(100.0, RecordMath.effectiveBpm(null, 100.0)!!, 0.0)
        assertEquals(100.0, RecordMath.effectiveBpm(0.0, 100.0)!!, 0.0)
        assertNull(RecordMath.effectiveBpm(null, null))
    }

    @Test fun angleAccumulatesOnlyWhileAudibleAndFreezesOnPause() {
        var a = 0.0
        a = RecordMath.advance(a, 0.1, true, 120.0)      // 180 deg/s * 0.1
        assertEquals(18.0, a, 1e-9)
        val frozen = RecordMath.advance(a, 0.1, false, 120.0)
        assertEquals(a, frozen, 0.0)
        // Resume continues from the same angle.
        assertEquals(36.0, RecordMath.advance(frozen, 0.1, true, 120.0), 1e-9)
    }

    @Test fun angleWrapsAndStallsAreClamped() {
        assertEquals(26.0, RecordMath.advance(350.0, 0.2, true, 120.0), 1e-9) // 350 + 36 - 360
        // A 10 s stall only counts as one capped frame (0.25 s * 180 = 45 deg).
        assertEquals(45.0, RecordMath.advance(0.0, 10.0, true, 120.0), 1e-9)
    }

    @Test fun lengthPrefersCatalogThenPlayerDuration() {
        assertEquals(200_000L, RecordMath.lengthMs(200_000, 180_000))
        assertEquals(180_000L, RecordMath.lengthMs(null, 180_000))
        assertEquals(180_000L, RecordMath.lengthMs(0, 180_000))
        assertNull(RecordMath.lengthMs(null, null))
    }

    @Test fun progressFractionClampsAndNullsWithoutLength() {
        assertEquals(0.25, RecordMath.progressFraction(50_000, 200_000)!!, 1e-9)
        assertEquals(1.0, RecordMath.progressFraction(300_000, 200_000)!!, 0.0)
        assertEquals(0.0, RecordMath.progressFraction(-5, 200_000)!!, 0.0)
        assertNull(RecordMath.progressFraction(10, null))
    }

    @Test fun tonearmSweepsOuterToCenter() {
        assertEquals(RecordMath.TONEARM_OUTER_DEG, RecordMath.tonearmAngle(0.0), 1e-9)
        assertEquals(RecordMath.TONEARM_INNER_DEG, RecordMath.tonearmAngle(1.0), 1e-9)
        assertEquals(RecordMath.TONEARM_OUTER_DEG, RecordMath.tonearmAngle(null), 1e-9)
    }
}

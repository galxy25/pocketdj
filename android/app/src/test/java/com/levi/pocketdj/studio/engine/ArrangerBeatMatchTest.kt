package com.levi.pocketdj.studio.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ArrangerBeatMatchTest {
    @Test fun rateIsWarpTimesTempoClamped() {
        assertEquals(1.0, ArrangerBeatMatch.rate(0.0, 120.0, 1.0, true), 0.0)
        assertEquals(1.25, ArrangerBeatMatch.rate(96.0, 120.0, 1.0, true), 1e-9)
        assertEquals(2.5, ArrangerBeatMatch.rate(96.0, 120.0, 2.0, true), 1e-9)
        assertEquals(2.0, ArrangerBeatMatch.rate(96.0, 120.0, 2.0, false), 1e-9)
        assertEquals(32.0, ArrangerBeatMatch.rate(1.0, 300.0, 10.0, true), 0.0)
        assertEquals(1.0 / 32, ArrangerBeatMatch.rate(300.0, 1.0, 0.1, true), 0.0)
    }

    @Test fun ninetyBpmClipToHundredTwentyMasterIsFourThirdsTimesTempoRatio() {
        assertEquals(4.0 / 3.0, ArrangerBeatMatch.rate(90.0, 120.0, 1.0, true), 1e-12)
        assertEquals(4.0 / 3.0 * 0.75, ArrangerBeatMatch.rate(90.0, 120.0, 0.75, true), 1e-12)
    }

    @Test fun sentinelZeroBpmGridLeavesClipAtNaturalRate() {
        // The analyzer's "unanalyzable" sentinel (bpm 0) must never warp to a bogus tempo.
        assertEquals(1.0, ArrangerBeatMatch.rate(0.0, 120.0, 1.0, true), 0.0)
        assertEquals(0.5, ArrangerBeatMatch.rate(0.0, 120.0, 0.5, true), 0.0)
    }

    @Test fun startSnapsToNearestMasterBeatOnlyWhenBeatMatching() {
        val beat = 22_050.0
        assertEquals(22_050, ArrangerBeatMatch.snappedStartFrame(20_000, beat, true))
        assertEquals(20_000, ArrangerBeatMatch.snappedStartFrame(20_000, beat, false))
        assertEquals(20_000, ArrangerBeatMatch.snappedStartFrame(20_000, 0.0, true))
        assertEquals(0, ArrangerBeatMatch.snappedStartFrame(10_000, beat, true))
        assertEquals(44_100, ArrangerBeatMatch.snappedStartFrame(34_000, beat, true))
    }

    @Test fun beatFramesAtHundredTwentyIsHalfASecond() {
        assertEquals(22_050.0, ArrangerBeatMatch.beatFrames(120.0), 1e-9)
        assertEquals(0.0, ArrangerBeatMatch.beatFrames(0.0), 0.0)
    }

    @Test fun warpedLengthAndFileStartScaleByRate() {
        // Rate 4/3 shortens a 4 s window to 3 s; the window offset scales the same way.
        val r = 4.0 / 3.0
        assertEquals(132_300L, ArrangerBeatMatch.warpedFrames(176_400, r))
        assertEquals(1500, ArrangerBeatMatch.scaledFileStartMs(2000, r))
        assertEquals(2000, ArrangerBeatMatch.scaledFileStartMs(2000, 1.0))
    }

    @Test fun needsBakeOnlyWhenRateOrPitchMoves() {
        assertFalse(ArrangerBeatMatch.needsBake(1.0, 0.0))
        assertFalse(ArrangerBeatMatch.needsBake(1.0004, 0.4))
        assertTrue(ArrangerBeatMatch.needsBake(4.0 / 3.0, 0.0))
        assertTrue(ArrangerBeatMatch.needsBake(1.0, 100.0))
    }
}

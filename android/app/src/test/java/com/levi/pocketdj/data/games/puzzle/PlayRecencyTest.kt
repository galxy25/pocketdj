package com.levi.pocketdj.data.games.puzzle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayRecencyTest {
    private val now = 1_700_000_000_000.0
    private val day = 86_400_000.0

    @Test fun pinnedConstants() {
        assertEquals(730.0, PlayRecency.HALF_LIFE_DAYS, 0.0)
        assertEquals(8.0, PlayRecency.GAIN, 0.0)
    }

    @Test fun decayIsOneAtZeroAndHalfAtOneHalfLife() {
        assertEquals(1.0, PlayRecency.decay(0.0), 1e-12)
        assertEquals(0.5, PlayRecency.decay(730.0), 1e-12)
        assertEquals(0.25, PlayRecency.decay(1460.0), 1e-12)
    }

    @Test fun futureStampClampsToOneNotAboveIt() {
        assertEquals(1.0, PlayRecency.decay(-400.0), 1e-12)
        assertEquals(1.0, PlayRecency.score(now + 5 * day, now), 1e-12)
    }

    @Test fun nonFiniteAgeScoresZero() {
        assertEquals(0.0, PlayRecency.decay(Double.NaN), 0.0)
        assertEquals(0.0, PlayRecency.decay(Double.POSITIVE_INFINITY), 0.0)
    }

    @Test fun absentOrInvalidStampIsZero() {
        assertEquals(0.0, PlayRecency.score(null, now), 0.0)
        assertEquals(0.0, PlayRecency.score(0.0, now), 0.0)
        assertEquals(0.0, PlayRecency.score(-5.0, now), 0.0)
        assertEquals(0.0, PlayRecency.score(Double.NaN, now), 0.0)
        assertEquals(0.0, PlayRecency.score(now - day, Double.NaN), 0.0)
    }

    @Test fun scoreFromStampMatchesDecayOfAgeInDays() {
        assertEquals(0.5, PlayRecency.score(now - 730 * day, now), 1e-12)
        assertTrue(PlayRecency.score(now - day, now) > PlayRecency.score(now - 2190 * day, now))
    }

    @Test fun monotonicallyDecreasingWithAge() {
        var prev = 2.0
        for (d in listOf(0, 1, 30, 365, 730, 2117, 5000)) {
            val s = PlayRecency.score(now - d * day, now)
            assertTrue("age $d: $s !< $prev", s < prev || d == 0)
            prev = s
        }
    }
}

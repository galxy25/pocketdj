package com.levi.pocketdj

import com.levi.pocketdj.data.location.FgsTypeTracker
import com.levi.pocketdj.data.location.LocationFgsPolicy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FgsTypeTrackerTest {
    private val both = LocationFgsPolicy.types(true, true, true, 34)

    @Test fun sameTypesAreSkippedUntilMedia3Repromotes() {
        val t = FgsTypeTracker()
        assertTrue(t.shouldApply(both)); t.applied(both)
        assertFalse(t.shouldApply(both))
        // Media3 startForeground(mediaPlayback) on a track transition drops location: must re-apply.
        t.onMedia3Promoted()
        assertTrue(t.shouldApply(both))
    }

    @Test fun resetOnPauseReappliesOnNextPlay() {
        val t = FgsTypeTracker(); t.applied(both); t.reset()
        assertTrue(t.shouldApply(both))
    }
}

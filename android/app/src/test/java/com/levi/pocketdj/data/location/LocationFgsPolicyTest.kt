package com.levi.pocketdj.data.location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationFgsPolicyTest {
    private val both = LocationFgsPolicy.TYPE_MEDIA_PLAYBACK or LocationFgsPolicy.TYPE_LOCATION

    @Test fun locationTypeOnlyWhenPlayingPlacesOnAndGranted() {
        assertEquals(both, LocationFgsPolicy.types(true, true, true, 34))
    }

    @Test fun everyMissingConditionDropsLocation() {
        assertEquals(LocationFgsPolicy.TYPE_MEDIA_PLAYBACK, LocationFgsPolicy.types(false, true, true, 34))
        assertEquals(LocationFgsPolicy.TYPE_MEDIA_PLAYBACK, LocationFgsPolicy.types(true, false, true, 34))
        assertEquals(LocationFgsPolicy.TYPE_MEDIA_PLAYBACK, LocationFgsPolicy.types(true, true, false, 34))
    }

    @Test fun preQHasNoLocationType() {
        assertFalse(LocationFgsPolicy.wantsLocationType(true, true, true, 28))
        assertTrue(LocationFgsPolicy.wantsLocationType(true, true, true, 29))
    }

    @Test fun coarseOnlyCountsAsWhileInUseAndBackgroundIsNeverAssumed() {
        assertTrue(LocationFgsPolicy.whileInUse(coarse = true, fine = false))
        assertTrue(LocationFgsPolicy.whileInUse(coarse = false, fine = true))
        assertFalse(LocationFgsPolicy.whileInUse(coarse = false, fine = false))
        // WHEN_IN_USE (no background grant) is enough for the FGS rule.
        val a = LocationSettings.authorization(coarse = true, fine = false, background = false, askedBefore = true)
        assertEquals(ListeningLocationAuthorization.WHEN_IN_USE, a)
    }
}

package com.levi.pocketdj.data.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SyncSettingsDefaultTest {
    /** Levi 2026-10-29: profile sync is opt-in on Android. An install that never chose reads the default. */
    @Test fun cloudSyncIsOptInOffByDefault() {
        assertFalse(SyncSettings.CLOUD_SYNC_ENABLED.default)
        // Key name is frozen (stored choices of users who opted in must keep working).
        assertEquals("cloudSyncEnabled", SyncSettings.CLOUD_SYNC_ENABLED.name)
    }
}

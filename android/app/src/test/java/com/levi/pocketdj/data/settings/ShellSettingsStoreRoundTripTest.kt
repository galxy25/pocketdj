package com.levi.pocketdj.data.settings

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** SURF-6 persistence: values survive a "relaunch" (second store over the same file). */
class ShellSettingsStoreRoundTripTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun roundTrip_acrossStoreInstances() = runBlocking {
        val file = File(tmp.root, "s.preferences_pb")
        val scope1 = CoroutineScope(Dispatchers.IO + Job())
        val s1 = AppSettingsStore(PreferenceDataStoreFactory.create(scope = scope1) { file })
        assertEquals(3650, s1.defaultRecentlyAddedCount())
        assertFalse(s1.get(ShellSettings.RIP_FROM_CLOUD))
        s1.setDefaultRecentlyAddedCount(0)
        assertEquals(1, s1.defaultRecentlyAddedCount())
        s1.setDefaultRecentlyAddedCount(250_000)
        s1.setRipFromCloud(true)
        scope1.cancel()

        val scope2 = CoroutineScope(Dispatchers.IO + Job())
        val s2 = AppSettingsStore(PreferenceDataStoreFactory.create(scope = scope2) { file })
        assertEquals(100_000, s2.defaultRecentlyAddedCount())
        assertTrue(s2.get(ShellSettings.RIP_FROM_CLOUD))
        scope2.cancel()
    }
}

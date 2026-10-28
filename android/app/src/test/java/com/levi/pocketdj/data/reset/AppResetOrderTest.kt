package com.levi.pocketdj.data.reset

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.AppSettings
import com.levi.pocketdj.onboarding.DataStoreOnboardingMarkerStorage
import com.levi.pocketdj.onboarding.OnboardingMarker
import com.levi.pocketdj.onboarding.OnboardingMarkerCodec
import com.levi.pocketdj.onboarding.OnboardingPrefs
import com.levi.pocketdj.onboarding.OnboardingStore
import com.levi.pocketdj.screens.settings.sections.ResetConfirmation
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppResetOrderTest {
    @get:Rule val tmp = TemporaryFolder()
    private val scopes = mutableListOf<CoroutineScope>()
    @After fun tearDown() { scopes.forEach { it.cancel() } }

    private fun settings(): AppSettingsStore {
        val scope = CoroutineScope(Dispatchers.IO + Job()).also { scopes += it }
        return AppSettingsStore(PreferenceDataStoreFactory.create(scope = scope) { File(tmp.root, "s.preferences_pb") })
    }

    private fun recordingService(calls: MutableList<String>, fail: Set<String> = emptySet()): AppResetService {
        fun step(n: String): suspend () -> Unit = { calls += n; if (n in fail) error("boom $n") }
        return AppResetService(
            holdPushes = { calls += "holdPushes" },
            ejectMix = step("mix"),
            clearCollections = step("collections"),
            deleteCatalogCache = step("catalog"),
            deleteCredentialsMirror = step("mirror"),
            clearArtwork = step("artwork"),
            clearSecrets = step("secrets"),
            resetSettings = step("settings"),
            markOnboardingPending = step("pending"),
            clearSyncState = step("sync"),
        )
    }

    @Test fun order_isHoldMixCollectionsCachesSecretsSettingsPendingSync() = runBlocking {
        val calls = mutableListOf<String>()
        val report = recordingService(calls).resetEverything()
        assertEquals(
            listOf("holdPushes", "mix", "collections", "catalog", "mirror", "artwork", "secrets", "settings", "pending", "sync"),
            calls,
        )
        assertTrue(report.ok)
        assertEquals(calls.size, report.steps.size)
    }

    @Test fun pendingMarker_isWrittenAfterTheSettingsReset() = runBlocking {
        val calls = mutableListOf<String>()
        recordingService(calls).resetEverything()
        assertTrue(calls.indexOf("pending") > calls.indexOf("settings"))
    }

    @Test fun aFailingStep_isRecorded_andTheRestStillRun() = runBlocking {
        val calls = mutableListOf<String>()
        val report = recordingService(calls, fail = setOf("catalog", "secrets")).resetEverything()
        assertEquals(setOf(AppResetService.STEP_CATALOG_CACHE, AppResetService.STEP_SECRETS), report.failures.map { it.name }.toSet())
        assertTrue("settings still reset", "settings" in calls)
        assertTrue("marker still written", "pending" in calls)
        assertTrue("sync state still cleared", "sync" in calls)
        assertFalse(report.ok)
    }

    @Test fun realSettingsStore_resetKeepsInstallId_andPendingSurvivesTheClear() = runBlocking {
        val store = settings()
        val storage = DataStoreOnboardingMarkerStorage(store)
        val install = store.ensureInstallId()
        store.setRipServer("https://rip.example", "tok")
        store.set(OnboardingPrefs.PROFILE_NAME, "Levi")
        OnboardingStore.markPendingAfterReset(storage) // simulate a previous (completed) marker being replaced
        val svc = AppResetService(
            holdPushes = {}, clearCollections = {}, deleteCatalogCache = {}, deleteCredentialsMirror = {},
            clearArtwork = {}, clearSecrets = {},
            resetSettings = { store.resetToDefaultsKeepingInstallId() },
            markOnboardingPending = { OnboardingStore.markPendingAfterReset(storage) },
            clearSyncState = {},
        )
        // Pretend onboarding had completed so we can see it flip back.
        storage.write(OnboardingMarkerCodec.encode(OnboardingMarker.Completed))
        svc.resetEverything()
        val cur: AppSettings = store.current()
        assertEquals("install id preserved on device reset", install, cur.installId)
        assertEquals("", cur.ripServerUrl)
        assertEquals("", store.get(OnboardingPrefs.PROFILE_NAME))
        assertEquals(AppSettings.defaultSources().map { it.url }, cur.sources.map { it.url })
        assertEquals(OnboardingMarker.Pending, OnboardingMarkerCodec.decode(storage.read()))
    }

    @Test fun settingsStore_resetInstallId_remintsADifferentOne() = runBlocking {
        val store = settings()
        val first = store.ensureInstallId()
        store.resetInstallId()
        assertEquals("", store.current().installId)
        val second = store.ensureInstallId()
        assertTrue(second.isNotEmpty())
        assertFalse(first == second)
    }

    @Test fun resetSettingsOnly_skipsHoldCollectionsAndSync() = runBlocking {
        val calls = mutableListOf<String>()
        recordingService(calls).resetSettingsOnly()
        assertEquals(listOf("catalog", "mirror", "artwork", "secrets", "settings", "pending"), calls)
    }

    @Test fun confirmation_requiresTheTypedWord_caseInsensitiveTrimmed() {
        assertFalse(ResetConfirmation.armed("", ResetConfirmation.RESET_WORD))
        assertFalse(ResetConfirmation.armed("RESE", ResetConfirmation.RESET_WORD))
        assertFalse(ResetConfirmation.armed("DELETE", ResetConfirmation.RESET_WORD))
        assertTrue(ResetConfirmation.armed(" reset ", ResetConfirmation.RESET_WORD))
        assertTrue(ResetConfirmation.armed("Delete", ResetConfirmation.DELETE_WORD))
    }
}

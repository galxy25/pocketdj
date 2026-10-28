package com.levi.pocketdj.data.reset

import com.levi.pocketdj.data.credentials.DiagKeySync
import com.levi.pocketdj.data.credentials.SettingsCredentialsDocument
import com.levi.pocketdj.data.games.GamesPrefs
import com.levi.pocketdj.data.sync.SyncRegistry
import com.levi.pocketdj.di.BrowseGraph
import com.levi.pocketdj.di.GamesGraph
import java.io.File
import java.io.IOException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AccountDeletionTest {

    private class Rig(
        val cloudEnabled: Boolean = true,
        val failCloudDocs: Boolean = false,
        val failCloudProfile: Boolean = false,
        val hangCloud: Boolean = false,
        val failing: Set<String> = emptySet(),
    ) {
        val calls = mutableListOf<String>()
        var deletedKeys: List<String>? = null
        private fun s(n: String): suspend () -> Unit = { calls += n; if (n in failing) error("boom $n") }

        val appReset = AppResetService(
            holdPushes = {}, clearCollections = {}, deleteCatalogCache = s("catalog"), deleteCredentialsMirror = s("mirror"),
            clearArtwork = s("artwork"), clearSecrets = s("secrets"), resetSettings = s("settings"),
            markOnboardingPending = s("pending"), clearSyncState = {},
        )

        val service = AccountDeletionService(
            holdPushes = { calls += "hold" },
            stopLiveActivity = listOf("jukebox" to s("stop-jukebox"), "playback" to s("stop-playback"), "transfers" to s("stop-transfers")),
            cloudDeleteEnabled = { cloudEnabled },
            deleteCloudDocs = { keys ->
                calls += "cloud-docs"
                if (hangCloud) delay(60_000)
                if (failCloudDocs) throw IOException("offline")
                deletedKeys = keys
            },
            deleteCloudProfile = { calls += "cloud-profile"; if (failCloudProfile) throw IOException("offline") },
            tombstoneCloudProfile = { calls += "tombstone" },
            localStores = listOf("collections" to s("clear-collections"), "favorites" to s("clear-favorites"), "hook" to s("clear-hook")),
            mediaDeletes = listOf("burns" to s("media-burns"), "lyrics" to s("media-lyrics")),
            appReset = appReset,
            clearSyncState = s("sync-state"),
            resetProfile = s("id-profile"),
            clearProfileSecret = s("id-secret"),
            resetInstallId = s("id-install"),
            cloudTimeoutMs = 200,
        )
    }

    @Test fun order_cloudBeforeLocal_mediaBeforeSettings_identityLast() = runBlocking {
        val r = Rig()
        val report = r.service.deleteAccountAndAllData()
        assertTrue(report.ok)
        assertEquals(
            listOf(
                "hold", "stop-jukebox", "stop-playback", "stop-transfers",
                "cloud-docs", "cloud-profile",
                "clear-collections", "clear-favorites", "clear-hook",
                "media-burns", "media-lyrics",
                "catalog", "mirror", "artwork", "secrets", "settings", "pending",
                "sync-state", "id-profile", "id-secret", "id-install",
            ),
            r.calls,
        )
    }

    @Test fun identitySteps_runExactlyOnce_andAreTheLastThree() = runBlocking {
        val r = Rig()
        val report = r.service.deleteAccountAndAllData()
        assertEquals(1, r.calls.count { it == "id-profile" })
        assertEquals(1, r.calls.count { it == "id-install" })
        assertEquals(
            listOf(
                AccountDeletionService.STEP_IDENTITY_PROFILE,
                AccountDeletionService.STEP_IDENTITY_SECRET,
                AccountDeletionService.STEP_IDENTITY_INSTALL_ID,
            ),
            report.names.takeLast(3),
        )
    }

    @Test fun cloudUnreachable_stillWipesTheDeviceCompletely() = runBlocking {
        val r = Rig(failCloudDocs = true, failCloudProfile = true)
        val report = r.service.deleteAccountAndAllData()
        assertEquals(
            setOf(AccountDeletionService.STEP_CLOUD_DOCS, AccountDeletionService.STEP_CLOUD_PROFILE),
            report.failures.map { it.name }.toSet(),
        )
        for (n in listOf("clear-collections", "clear-favorites", "media-burns", "settings", "pending", "sync-state", "id-profile", "id-secret", "id-install")) {
            assertTrue("$n must still run", n in r.calls)
        }
    }

    @Test fun cloudProfileFailure_writesTheTombstone_beforeAnyIdentityClear() = runBlocking {
        val r = Rig(failCloudProfile = true)
        r.service.deleteAccountAndAllData()
        assertEquals(1, r.calls.count { it == "tombstone" })
        assertTrue(r.calls.indexOf("tombstone") < r.calls.indexOf("id-profile"))
        assertTrue(r.calls.indexOf("tombstone") < r.calls.indexOf("id-secret"))
    }

    @Test fun docsTimeout_butProfileDeleted_needsNoTombstone() = runBlocking {
        val r = Rig(hangCloud = true)
        r.service.deleteAccountAndAllData()
        assertFalse("DELETE /profile wipes the prefix, so no tombstone", "tombstone" in r.calls)
    }

    @Test fun cloudProfileSuccess_orDisabledCloud_writesNoTombstone() = runBlocking {
        val ok = Rig(); ok.service.deleteAccountAndAllData()
        assertFalse("tombstone" in ok.calls)
        val off = Rig(cloudEnabled = false); off.service.deleteAccountAndAllData()
        assertFalse("tombstone" in off.calls)
    }

    @Test fun hangingCloud_isBounded_andDoesNotBlockTheWipe() = runBlocking {
        val r = Rig(hangCloud = true)
        val t0 = System.nanoTime()
        val report = r.service.deleteAccountAndAllData()
        assertTrue("bounded wait", (System.nanoTime() - t0) / 1_000_000 < 10_000)
        assertTrue(AccountDeletionService.STEP_CLOUD_DOCS in report.failures.map { it.name })
        assertTrue("id-install" in r.calls)
    }

    @Test fun aFailingStep_isLogged_andTheRestRun() = runBlocking {
        val r = Rig(failing = setOf("stop-playback", "clear-favorites", "media-burns", "catalog"))
        val report = r.service.deleteAccountAndAllData()
        assertEquals(
            setOf("stop:playback", "clear:favorites", "media:burns", AppResetService.STEP_CATALOG_CACHE),
            report.failures.map { it.name }.toSet(),
        )
        assertEquals("id-install", r.calls.last())
        assertTrue("media-lyrics" in r.calls && "settings" in r.calls)
    }

    @Test fun cloudDisabled_skipsBothCloudSteps_butStillWipes() = runBlocking {
        val r = Rig(cloudEnabled = false)
        r.service.deleteAccountAndAllData()
        assertFalse("cloud-docs" in r.calls)
        assertFalse("cloud-profile" in r.calls)
        assertTrue("id-install" in r.calls)
    }

    @Test fun cloudDelete_sendsTheRegistryKeys() = runBlocking {
        val r = Rig()
        r.service.deleteAccountAndAllData()
        assertEquals(AccountDeletionService.cloudDocKeys, r.deletedKeys)
    }

    // ---- lockstep with the sync registry ----------------------------------------------------

    @Test fun cloudDocKeys_equalTheRegistryKeySet() {
        val registry = setOf(
            SyncRegistry.KEY_PROFILE, SyncRegistry.KEY_COLLECTIONS, SyncRegistry.KEY_PLAY_HISTORY,
            SyncRegistry.KEY_COLLECTION_ACTIVITY, SyncRegistry.KEY_PLAY_STATS, SyncRegistry.KEY_TIMELINE_CUES,
            SettingsCredentialsDocument.KEY, DiagKeySync.KEY,
            BrowseGraph.REC_FEEDBACK_SYNC_KEY, BrowseGraph.FORYOU_FEED_SYNC_KEY, BrowseGraph.REC_KEY_SYNC_KEY,
            "studio-cues", GamesPrefs.SCOREBOARD_SYNC_KEY, GamesGraph.PUZZLE_DECISIONS_SYNC_KEY,
        )
        assertEquals(registry, AccountDeletionService.cloudDocKeys.toSet())
        assertEquals("no duplicates", AccountDeletionService.cloudDocKeys.size, AccountDeletionService.cloudDocKeys.toSet().size)
    }

    /**
     * Catches a NEW package registering a `SyncEntry` without extending [AccountDeletionService.cloudDocKeys]:
     * the number of `SyncEntry(` construction sites under di/ must equal the key count.
     */
    @Test fun everySyncEntryConstructionSite_isCoveredByTheKeyList() {
        val di = listOf("src/main/java/com/levi/pocketdj/di", "app/src/main/java/com/levi/pocketdj/di")
            .map(::File).first { it.isDirectory }
        val sites = di.listFiles { f -> f.extension == "kt" }!!.sumOf { f ->
            Regex("""\bSyncEntry\(""").findAll(f.readText()).count()
        }
        assertEquals(
            "a SyncEntry was added/removed: update AccountDeletionService.cloudDocKeys (and this count)",
            AccountDeletionService.cloudDocKeys.size, sites,
        )
    }
}

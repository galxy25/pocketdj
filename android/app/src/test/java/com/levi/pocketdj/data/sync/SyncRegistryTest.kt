package com.levi.pocketdj.data.sync

import com.levi.pocketdj.shell.FeatureModule
import com.levi.pocketdj.shell.FeatureModuleRegistry
import com.levi.pocketdj.shell.SyncEntry
import java.io.File
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class SyncRegistryTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun module(area: String, vararg e: SyncEntry) = object : FeatureModule {
        override val area = area
        override val syncEntries = e.toList()
    }

    @Test fun coreKeysAndFilesUseTheIosNames() {
        assertEquals(
            listOf("profile", "collections", "play-history", "collection-activity", "play-stats"),
            listOf(
                SyncRegistry.KEY_PROFILE, SyncRegistry.KEY_COLLECTIONS, SyncRegistry.KEY_PLAY_HISTORY,
                SyncRegistry.KEY_COLLECTION_ACTIVITY, SyncRegistry.KEY_PLAY_STATS,
            ),
        )
        assertEquals("pocketdj-profile.json", ProfileStore.FILE_NAME)
    }

    @Test fun registersEveryModuleEntryUnderFilesDirInOrder() = runTest {
        val a = module("a", SyncEntry("profile", "pocketdj-profile.json"), SyncEntry("collections", "pocketdj-collections.json"))
        val b = module("b", SyncEntry("studio-cues", "pocketdj-studio.cues.json"))
        val reg = FeatureModuleRegistry(listOf(a, b))
        val svc = CloudSyncService(InMemoryCloudDocDatabase(), { true }, File(tmp.root, "s.json"), backgroundScope)
        val keys = SyncRegistry.registerAll(svc, tmp.root, reg.syncEntries)
        assertEquals(listOf("profile", "collections", "studio-cues"), keys)
        assertEquals(keys, svc.registeredKeys)
    }

    @Test fun pullRoutesToTheContributorsReloadSeam() = runTest {
        val db = InMemoryCloudDocDatabase()
        val reloaded = mutableListOf<String>()
        val entries = listOf(
            SyncEntry("collections", "c.json", onPulled = { reloaded += "collections" }),
            SyncEntry("fileonly", "f.json"), // restore-later store: no reload seam
        )
        val svc = CloudSyncService(db, { true }, File(tmp.root, "s.json"), backgroundScope)
        SyncRegistry.registerAll(svc, tmp.root, entries)
        File(tmp.root, "c.json").apply { writeText("old"); setLastModified(1_000_000_000_000L) }
        db.put(CloudDoc("collections", "new".toByteArray(), 1_000_000_020_000.0, "Mac"))
        db.put(CloudDoc("fileonly", "pulled".toByteArray(), 1_000_000_020_000.0, "Mac"))
        svc.syncNow()
        assertEquals(listOf("collections"), reloaded)
        assertEquals("new", File(tmp.root, "c.json").readText())
        assertEquals("pulled", File(tmp.root, "f.json").readText())
    }

    @Test fun duplicateKeysFailFast() {
        val svc = CloudSyncService(InMemoryCloudDocDatabase(), { true }, File(tmp.root, "s.json"), kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined))
        assertThrows(IllegalArgumentException::class.java) {
            SyncRegistry.registerAll(svc, tmp.root, listOf(SyncEntry("x", "a"), SyncEntry("x", "b")))
        }
        assertThrows(IllegalArgumentException::class.java) {
            FeatureModuleRegistry(listOf(module("a", SyncEntry("x", "a")), module("b", SyncEntry("x", "b"))))
        }
    }
}

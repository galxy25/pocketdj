package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.settings.PrefKey

/** DataStore keys for document sync (names frozen once shipped). */
object SyncSettings {
    /** Settings > Profile "Sync across devices" (iOS `cloudSyncEnabled`, default on). */
    val CLOUD_SYNC_ENABLED = PrefKey.boolean("cloudSyncEnabled", true)

    /** Debug only: back the engine with [InMemoryCloudDocDatabase] so the pipeline is drivable without a backend. */
    val DEBUG_IN_MEMORY_DB = PrefKey.boolean("debugInMemorySyncDb", false)
}

package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.settings.PrefKey

/** DataStore keys for document sync (names frozen once shipped). */
object SyncSettings {
    /**
     * Settings > Profile "Sync across devices". OPT-IN, default OFF on Android (Levi, 2026-10-29,
     * Play data-safety). Only the Settings toggle writes this key, so an install that never chose
     * has no stored value and reads the default: existing installs that never opted in stay off.
     */
    val CLOUD_SYNC_ENABLED = PrefKey.boolean("cloudSyncEnabled", false)

    /** Debug only: back the engine with [InMemoryCloudDocDatabase] so the pipeline is drivable without a backend. */
    val DEBUG_IN_MEMORY_DB = PrefKey.boolean("debugInMemorySyncDb", false)
}

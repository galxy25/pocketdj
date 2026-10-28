package com.levi.pocketdj.shell

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.LegacyPrefKeys
import com.levi.pocketdj.navigation.PocketDjDestination

/**
 * Last-visited section persistence (iOS `settings.lastSection`). Restores on cold launch;
 * nothing valid persisted ⇒ History.
 */
class LastSectionStore(private val settings: AppSettingsStore) {
    suspend fun restore(): PocketDjDestination =
        PocketDjDestination.fromToken(settings.get(LegacyPrefKeys.LAST_SECTION))

    suspend fun save(destination: PocketDjDestination) {
        settings.set(LegacyPrefKeys.LAST_SECTION, destination.token)
    }
}

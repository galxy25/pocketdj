package com.levi.pocketdj.data.favorites

import com.levi.pocketdj.data.settings.PrefKey

/**
 * Favorites-sync settings (iOS `SettingsStore.favoritesTwoWaySync` / `applyOwnerFavoritesSeed`).
 * Persisted names are frozen to the iOS keys. BOTH default OFF: there is no owner gate on
 * Android (the write path uses the user's own Music-User-Token against their own account),
 * and adopting someone else's picks as your favorites must be an explicit choice.
 */
object FavoritesSyncSettings {
    /** Opt-in two-way sync with Apple Music (push pending, pull loved). */
    val TWO_WAY = PrefKey.boolean("favoritesTwoWaySync", false)

    /** Adopt the curator's shipped ♥ seed as this install's initial favorites. */
    val APPLY_OWNER_SEED = PrefKey.boolean("applyOwnerFavoritesSeed", false)
}

package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.settings.PrefKey

/**
 * Source-sync settings + the auto-pass policy (COL-7). iOS `settings.syncConvertedPockets`
 * (field name predates playlist support): DEFAULT ON; the persisted name is frozen.
 */
object SourceSyncSettings {
    val SYNC_CONVERTED_POCKETS = PrefKey.boolean("syncConvertedPockets", true)

    /**
     * The auto pass run on every catalog assignment (cache seed + refresh): OFF or no catalog
     * ⇒ ZERO mutations. Per-item toggles and the direction gate live in
     * [CollectionsStore.syncConvertedCollections]. Returns the number of items changed.
     */
    fun autoPass(enabled: Boolean, catalog: MergedCatalog?, store: CollectionsStore): Int {
        if (!enabled || catalog == null) return 0
        return store.syncConvertedCollections(catalog.playlists)
    }

    /**
     * Apple Music source playlists a pocket can be linked to (the only sources write-back can
     * push to), name-ordered case-insensitively. iOS `linkableSources`.
     */
    fun linkableSources(playlists: List<SourcePlaylist>): List<SourcePlaylist> =
        playlists.filter { it.sourceName == Endpoints.SOURCE_NAME_APPLE_MUSIC }
            .sortedBy { it.playlist.name.lowercase() }
}

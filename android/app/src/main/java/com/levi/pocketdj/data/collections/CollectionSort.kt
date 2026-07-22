package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.SourcePlaylist

/**
 * The user-selectable collection sort (specs/playlists-ui.md §2.3, iOS
 * `CollectionSortOrder`). The raw [token] is the value persisted in
 * `AppSettingsStore.collectionSort`; a missing/unknown token coalesces to
 * [NAME] (the fresh-install AND upgrade default).
 *
 * `recentlyPlayed` keys off the collection's `lastPlayedAt` — stamped ONLY by
 * the play funnel ([CollectionsStore.markPlaylistPlayed] /
 * [CollectionsStore.markPocketPlayed]), never by edits — so playback and
 * "Last updated" stay distinct signals.
 */
enum class CollectionSortOrder(val token: String, val label: String) {
    RECENTLY_PLAYED("recentlyPlayed", "Recently played"),
    NAME("name", "A–Z"),
    LAST_UPDATED("lastUpdated", "Last updated"),
    ;

    /**
     * Order a list of collections by this sort (iOS comparator, exactly):
     * `name` = case-insensitive ascending; `lastUpdated` = `updatedAt` DESC,
     * tie-break name; `recentlyPlayed` = `lastPlayedAt ?? 0` DESC (never-played
     * sorts LAST), then `updatedAt` DESC, then name.
     */
    fun <T : CollectionSortable> sorted(items: List<T>): List<T> = when (this) {
        NAME -> items.sortedWith(nameComparator())
        LAST_UPDATED -> items.sortedWith(
            compareByDescending<T> { it.updatedAt }.then(nameComparator()),
        )
        RECENTLY_PLAYED -> items.sortedWith(
            compareByDescending<T> { it.lastPlayedAt ?: 0.0 }
                .thenByDescending { it.updatedAt }
                .then(nameComparator()),
        )
    }

    /**
     * Source playlists sort with NEUTRAL keys (`updatedAt = 0`,
     * `lastPlayedAt = null`), so every order degrades to A–Z for them.
     */
    fun sortedSourcePlaylists(sources: List<SourcePlaylist>): List<SourcePlaylist> =
        sources.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.playlist.name })

    private fun <T : CollectionSortable> nameComparator(): Comparator<T> =
        compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }

    companion object {
        val DEFAULT = NAME

        /** Persisted token → order; missing/unknown ⇒ [NAME]. */
        fun fromToken(token: String?): CollectionSortOrder =
            entries.firstOrNull { it.token == token } ?: NAME
    }
}

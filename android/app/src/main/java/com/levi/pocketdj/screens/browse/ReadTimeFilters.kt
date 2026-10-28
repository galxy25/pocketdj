package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.favorites.FavoriteFilter

/**
 * Collection-membership SHOW/HIDE filter (iOS `BrowseState.includeAny/includeIds/excludeAny/
 * excludeIds`). TRANSIENT: never in the persisted snapshot, never in the results memo key.
 * Each id set mixes `pls_` and `pkt_` ids.
 */
data class MembershipFilter(
    val includeAny: Boolean = false,
    val includeIds: Set<String> = emptySet(),
    val excludeAny: Boolean = false,
    val excludeIds: Set<String> = emptySet(),
) {
    val active: Boolean get() = includeAny || includeIds.isNotEmpty() || excludeAny || excludeIds.isNotEmpty()
    val showActive: Boolean get() = includeAny || includeIds.isNotEmpty()
    val hideActive: Boolean get() = excludeAny || excludeIds.isNotEmpty()

    /** The "Clear membership" action (separate from Clear All). */
    fun cleared() = MembershipFilter()

    /**
     * Stable signature of the selection (not store contents) — folds into the paging key so the
     * list resets when the CONSTRAINT changes, never when a collection's contents move.
     */
    fun selectionKey(): String =
        if (!active) "" else
            "mem=" + (if (includeAny) "*" else includeIds.sorted().joinToString(",")) + "/" +
                (if (excludeAny) "*" else excludeIds.sorted().joinToString(","))
}

/** Read-time filter layers (membership, favorites) — cheap O(n) Set lookups, never memoized. */
object ReadTimeFilters {

    /** Union of song ids in the selected collections (placed albums already expanded by the resolver). */
    fun memberSongIds(ids: Set<String>, membersOf: (String) -> Collection<String>): Set<String> {
        val out = HashSet<String>()
        for (id in ids) out.addAll(membersOf(id))
        return out
    }

    /**
     * SHOW keeps members of ANY selected collection; HIDE drops them; both = intersection
     * (in SHOW and not in HIDE); `*Any` = every playlist + pocket ([allCollectionIds]).
     * Non-song rows pass untouched. Song mode only — callers gate by kind.
     */
    fun <T : BrowseRow> applyMembership(
        rows: List<T>,
        m: MembershipFilter,
        allCollectionIds: Set<String>,
        membersOf: (String) -> Collection<String>,
    ): List<T> {
        if (!m.active) return rows
        val show = if (m.showActive) memberSongIds(if (m.includeAny) allCollectionIds else m.includeIds, membersOf) else null
        val hide = if (m.hideActive) memberSongIds(if (m.excludeAny) allCollectionIds else m.excludeIds, membersOf) else null
        return rows.filter { row ->
            if (row !is SongRow) return@filter true
            val id = row.song.id
            if (show != null && id !in show) return@filter false
            if (hide != null && id in hide) return@filter false
            true
        }
    }

    /**
     * Favorite tri-state over a Set. [favoriteIds] null = no provider wired -> no constraint.
     * ONLY keeps favorites; NOT keeps everything else (never-touched songs included).
     * Non-song rows pass untouched.
     */
    fun <T : BrowseRow> applyFavorites(rows: List<T>, filter: FavoriteFilter, favoriteIds: Set<String>?): List<T> {
        if (filter == FavoriteFilter.ANY || favoriteIds == null) return rows
        val want = filter == FavoriteFilter.FAVORITE
        return rows.filter { row -> row !is SongRow || (row.song.id in favoriteIds) == want }
    }

    /** Both layers in iOS order: membership -> favorites. */
    fun <T : BrowseRow> apply(
        rows: List<T>,
        membership: MembershipFilter,
        allCollectionIds: Set<String>,
        membersOf: (String) -> Collection<String>,
        favorite: FavoriteFilter,
        favoriteIds: Set<String>?,
    ): List<T> = applyFavorites(
        applyMembership(rows, membership, allCollectionIds, membersOf), favorite, favoriteIds,
    )

    /** History's Hide-skips lens, applied while building the base (part of the base key). */
    fun <E> hideSkips(events: List<E>, hide: Boolean, wasSkipped: (E) -> Boolean): List<E> =
        if (!hide) events else events.filterNot(wasSkipped)
}

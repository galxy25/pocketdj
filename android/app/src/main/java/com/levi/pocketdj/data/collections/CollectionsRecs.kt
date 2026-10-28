package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.recs.ForYouCollections
import com.levi.pocketdj.data.recs.RecMembership
import java.util.Collections
import java.util.WeakHashMap

/**
 * For You helpers on [CollectionsStore] (iOS `recommendationsEnabled`, `recommendationsOffIds`,
 * `recommendationsOffCollections`, `suggestibleCollections`, `playableIdsForAnyCollection`,
 * `suggestionsExcludingMembers`). Extensions so CollectionsStore.kt (another package's file)
 * is untouched.
 */

/** A collection offered to the suggestion pass: members are PLAYABLE ids. */
data class SuggestibleCollection(val id: String, val kind: String, val name: String, val songIds: List<String>)

data class RecsOffCollection(val id: String, val kind: String, val name: String)

/**
 * Does this collection want suggestions? Takes an id of UNKNOWN KIND (all a For You tile carries).
 * An id that resolves to NOTHING answers true: a since-deleted collection is dropped by the
 * caller's own existence filter, and answering "off" would silently double as a delete detector.
 */
fun CollectionsStore.recommendationsEnabled(forCollection: String): Boolean {
    playlist(forCollection)?.let { return it.wantsRecommendations }
    pocket(forCollection)?.let { return it.wantsRecommendations }
    return true
}

/** Flip it from a tile (id only). False when the id resolves to nothing. */
fun CollectionsStore.setRecommendationsEnabled(on: Boolean, forCollection: String): Boolean {
    if (playlist(forCollection) != null) { setRecommendationsEnabledForPlaylist(on, forCollection); return true }
    if (pocket(forCollection) != null) { setRecommendationsEnabledForPocket(on, forCollection); return true }
    return false
}

/** Ids `ForYouFeedBuilder` must NOT rank suggestions for. */
fun CollectionsStore.recommendationsOffIds(): Set<String> {
    val out = HashSet<String>()
    for (p in playlists) if (!p.wantsRecommendations) out += p.id
    for (p in pockets) if (!p.wantsRecommendations) out += p.id
    return out
}

/**
 * EVERY collection with recs off, named, sorted by name (case-insensitive, then id) — the "turn it
 * back on" list. Deliberately NOT `suggestibleCollections().filter {..}`: that drops EMPTY
 * collections, which would make an empty switched-off collection unreachable from the only screen
 * that can switch it back on.
 */
fun CollectionsStore.recommendationsOffCollections(): List<RecsOffCollection> {
    val out = ArrayList<RecsOffCollection>()
    for (p in playlists) if (!p.wantsRecommendations) out += RecsOffCollection(p.id, "playlist", p.name)
    for (p in pockets) if (!p.wantsRecommendations) out += RecsOffCollection(p.id, "pocket", p.name)
    return out.sortedWith(
        Comparator<RecsOffCollection> { a, b -> a.name.compareTo(b.name, ignoreCase = true) }
            .thenComparing { a, b -> if (a.name == b.name) a.id.compareTo(b.id) else 0 },
    )
}

/**
 * Playlists then pockets with at least one playable member. The recs opt-out is deliberately NOT
 * applied here: a switched-off collection still informs In Da Zone's co-membership signal; the
 * opt-out is applied in the builder (recsOffCrateIds), where it also skips the expensive sweep.
 * Setlists are excluded (frozen performance instances).
 */
fun CollectionsStore.suggestibleCollections(): List<SuggestibleCollection> {
    val out = ArrayList<SuggestibleCollection>()
    for (p in playlists) {
        val ids = playableIdsForPlaylist(p.id)
        if (ids.isNotEmpty()) out += SuggestibleCollection(p.id, "playlist", p.name, ids)
    }
    for (p in pockets) {
        val ids = playableIdsForPocket(p.id)
        if (ids.isNotEmpty()) out += SuggestibleCollection(p.id, "pocket", p.name, ids)
    }
    return out
}

/** Playable ids for a collection id of unknown kind; [] for a since-deleted one. */
fun CollectionsStore.playableIdsForAnyCollection(id: String): List<String> = when {
    playlist(id) != null -> playableIdsForPlaylist(id)
    pocket(id) != null -> playableIdsForPocket(id)
    else -> emptyList()
}

private class RecMembershipMemo(var revision: Int, val byId: HashMap<String, RecMembership>)

private val membershipMemos: MutableMap<CollectionsStore, RecMembershipMemo> =
    Collections.synchronizedMap(WeakHashMap())

/** Membership as REC IDENTITY, memoized per collection per store revision. */
fun CollectionsStore.recMembership(forCollection: String): RecMembership {
    val rev = state.value.revision
    val memo = synchronized(membershipMemos) {
        val cur = membershipMemos[this]
        if (cur != null && cur.revision == rev) cur
        else RecMembershipMemo(rev, HashMap()).also { membershipMemos[this] = it }
    }
    synchronized(memo) { memo.byId[forCollection]?.let { return it } }
    val songs = catalogProvider?.invoke()?.songsById
    val m = RecMembership(
        memberIds = playableIdsForAnyCollection(forCollection),
        appleMusicId = { songs?.get(it)?.appleMusicId },
        titleArtist = { id -> songs?.get(id)?.let { RecMembership.TitleArtist(it.name, it.artist) } },
    )
    synchronized(memo) { memo.byId[forCollection] = m }
    return m
}

/**
 * The READ-TIME half of "never suggest what is already in here": suggestion lists are frozen but
 * membership moves on every add, so a thumbed-up song must leave its tile immediately.
 */
fun CollectionsStore.suggestionsExcludingMembers(suggestionIds: List<String>, ofCollection: String): List<String> {
    val m = recMembership(ofCollection)
    if (m.isEmpty) return suggestionIds
    val songs = catalogProvider?.invoke()?.songsById
    return m.excluding(
        suggestionIds,
        appleMusicId = { songs?.get(it)?.appleMusicId },
        titleArtist = { id -> songs?.get(id)?.let { RecMembership.TitleArtist(it.name, it.artist) } },
    )
}

/** Adapter so [com.levi.pocketdj.data.recs.ForYouGrid] reads the live store. */
fun CollectionsStore.asForYouCollections(): ForYouCollections = object : ForYouCollections {
    override fun exists(id: String) = playlist(id) != null || pocket(id) != null
    override fun recommendationsEnabled(id: String) = this@asForYouCollections.recommendationsEnabled(id)
    override fun suggestionsExcludingMembers(suggestionIds: List<String>, id: String) =
        this@asForYouCollections.suggestionsExcludingMembers(suggestionIds, id)
}

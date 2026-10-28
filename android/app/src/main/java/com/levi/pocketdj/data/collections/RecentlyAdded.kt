package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.settings.ShellSettings

/**
 * The virtual "Recently added" playlist (iOS `AppModel.recentlyAddedSongIds` /
 * `hasRecentlyAddedItems` / `recentlyAddedPlaylist`): the newest `limit` songs by catalog
 * `dateAdded` UNION in-app adds (activity `catalogAdd` events), newest first, id-tiebroken so the
 * order is deterministic, filtered to songs still resolvable in the live catalog. Not a persisted
 * Playlist — a read-derived [SourcePlaylist].
 */
object RecentlyAdded {
    const val PLAYLIST_ID = "__pdj_recently_added__"
    const val NAME = "Recently added"

    /**
     * Add-times that do not come off a catalog row: in-app adds from `catalogAdd` events. The
     * LATEST catalogAdd/catalogRemove per item wins, so a newer remove cancels the add (iOS drops
     * the entry from its add stores on remove).
     */
    fun addTimeOverrides(events: List<ActivityEvent>): Map<String, Double> {
        val latest = HashMap<String, ActivityEvent>()
        for (e in events) {
            if ((e.kind != ActivityKind.CATALOG_ADD && e.kind != ActivityKind.CATALOG_REMOVE) || e.at <= 0) continue
            val cur = latest[e.itemId]
            // On an exact tie a remove wins (conservative).
            if (cur == null || e.at > cur.at || (e.at == cur.at && e.kind == ActivityKind.CATALOG_REMOVE)) latest[e.itemId] = e
        }
        val out = HashMap<String, Double>()
        for ((id, e) in latest) if (e.kind == ActivityKind.CATALOG_ADD) out[id] = e.at
        return out
    }

    /**
     * Every add-time by song id: catalog dateAdded (>0), then overrides win when newer.
     * [isOwnLibrary] mirrors iOS `addDatesScopedToOwnLibrary` (hybrid-integrity owner-gate): when
     * a non-owner's catalog carries a curator's shared library, only own-library rows count their
     * catalog dateAdded. Android has no owner identity yet, so callers pass the all-true default.
     */
    fun addedAtBySongId(
        songs: Collection<IndexSong>,
        overrides: Map<String, Double>,
        isOwnLibrary: (IndexSong) -> Boolean = { true },
    ): Map<String, Double> {
        val out = HashMap<String, Double>(songs.size)
        for (s in songs) {
            val d = s.dateAdded ?: continue
            if (d > 0 && isOwnLibrary(s) && d > (out[s.id] ?: 0.0)) out[s.id] = d
        }
        for ((id, ms) in overrides) if (ms > (out[id] ?: 0.0)) out[id] = ms
        return out
    }

    /** Newest-first top [limit]; ties break on id descending; unresolvable ids are dropped. */
    fun newestFirst(addedAt: Map<String, Double>, limit: Int, isResolvable: (String) -> Boolean): List<String> {
        if (limit <= 0) return emptyList()
        val cmp = Comparator<Map.Entry<String, Double>> { a, b ->
            if (a.value != b.value) b.value.compareTo(a.value) else b.key.compareTo(a.key)
        }
        val buf = ArrayList<Map.Entry<String, Double>>()
        var cutoff: Map.Entry<String, Double>? = null
        for (entry in addedAt.entries) {
            val c = cutoff
            if (c != null && cmp.compare(entry, c) >= 0) continue
            if (!isResolvable(entry.key)) continue
            buf.add(java.util.AbstractMap.SimpleImmutableEntry(entry.key, entry.value))
            if (buf.size >= limit * 2L) {
                buf.sortWith(cmp)
                while (buf.size > limit) buf.removeAt(buf.size - 1)
                cutoff = buf[limit - 1]
            }
        }
        buf.sortWith(cmp)
        return buf.take(limit).map { it.key }
    }
}

/**
 * Memoizing front for [RecentlyAdded]. The memo is keyed on (catalog snapshot identity — a new
 * snapshot is a new revision —, clamped limit, in-app add signature); a repeat call with the same
 * key does no work ([computeCount] proves it). Safe to call from any thread.
 */
class RecentlyAddedBuilder {
    // Weak catalog ref: a strong key would pin the previous ~93k-song snapshot after a refresh.
    private class Key(val catalog: java.lang.ref.WeakReference<MergedCatalog>, val limit: Int, val sig: String, val scoped: Boolean) {
        fun matches(c: MergedCatalog, l: Int, s: String, sc: Boolean) =
            catalog.get() === c && limit == l && sig == s && scoped == sc
    }

    private var memo: Pair<Key, List<String>>? = null

    /** Number of real derivations performed (test seam). */
    @Volatile
    var computeCount: Int = 0
        private set

    private fun signature(overrides: Map<String, Double>): String {
        var newest = 0.0
        for (v in overrides.values) if (v > newest) newest = v
        return "${overrides.size}:$newest"
    }

    /** [filterToOwnLibrary] + [isOwnLibrary] = iOS owner-gate; part of the memo key. */
    @Synchronized
    fun songIds(
        catalog: MergedCatalog,
        events: List<ActivityEvent>,
        rawLimit: Int,
        filterToOwnLibrary: Boolean = false,
        isOwnLibrary: (IndexSong) -> Boolean = { true },
    ): List<String> {
        val limit = ShellSettings.clampRecentlyAdded(rawLimit)
        val overrides = RecentlyAdded.addTimeOverrides(events)
        val sig = signature(overrides)
        memo?.let { if (it.first.matches(catalog, limit, sig, filterToOwnLibrary)) return it.second }
        computeCount++
        val own: (IndexSong) -> Boolean = if (filterToOwnLibrary) isOwnLibrary else { _ -> true }
        val ids = RecentlyAdded.newestFirst(RecentlyAdded.addedAtBySongId(catalog.songs, overrides, own), limit) {
            catalog.songsById.containsKey(it)
        }
        memo = Key(java.lang.ref.WeakReference(catalog), limit, sig, filterToOwnLibrary) to ids
        return ids
    }

    /** Cheap yes/no gate: serves from the memo, else short-circuits on the first dated/added song. */
    @Synchronized
    fun hasItems(
        catalog: MergedCatalog,
        events: List<ActivityEvent>,
        rawLimit: Int,
        filterToOwnLibrary: Boolean = false,
        isOwnLibrary: (IndexSong) -> Boolean = { true },
    ): Boolean {
        val limit = ShellSettings.clampRecentlyAdded(rawLimit)
        if (limit <= 0) return false
        val overrides = RecentlyAdded.addTimeOverrides(events)
        val m = memo
        if (m != null && m.first.matches(catalog, limit, signature(overrides), filterToOwnLibrary)) return m.second.isNotEmpty()
        val own: (IndexSong) -> Boolean = if (filterToOwnLibrary) isOwnLibrary else { _ -> true }
        if (catalog.songs.any { (it.dateAdded ?: 0.0) > 0 && own(it) }) return true
        return overrides.keys.any { catalog.songsById.containsKey(it) }
    }

    /** The virtual playlist, or null when empty. */
    fun playlist(catalog: MergedCatalog, events: List<ActivityEvent>, rawLimit: Int): SourcePlaylist? {
        val ids = songIds(catalog, events, rawLimit)
        if (ids.isEmpty()) return null
        return SourcePlaylist(IndexPlaylist(RecentlyAdded.PLAYLIST_ID, RecentlyAdded.NAME, ids), RecentlyAdded.NAME)
    }
}

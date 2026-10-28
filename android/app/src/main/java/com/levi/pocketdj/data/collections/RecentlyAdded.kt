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

    /** Add-times that do not come off a catalog row: in-app adds from `catalogAdd` events. */
    fun addTimeOverrides(events: List<ActivityEvent>): Map<String, Double> {
        val out = HashMap<String, Double>()
        for (e in events) {
            if (e.kind != ActivityKind.CATALOG_ADD || e.at <= 0) continue
            if (e.at > (out[e.itemId] ?: 0.0)) out[e.itemId] = e.at
        }
        return out
    }

    /** Every add-time by song id: catalog dateAdded (>0), then overrides win when newer. */
    fun addedAtBySongId(songs: Collection<IndexSong>, overrides: Map<String, Double>): Map<String, Double> {
        val out = HashMap<String, Double>(songs.size)
        for (s in songs) {
            val d = s.dateAdded ?: continue
            if (d > 0 && d > (out[s.id] ?: 0.0)) out[s.id] = d
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
    private data class Key(val catalog: MergedCatalog, val limit: Int, val sig: String)

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

    @Synchronized
    fun songIds(catalog: MergedCatalog, events: List<ActivityEvent>, rawLimit: Int): List<String> {
        val limit = ShellSettings.clampRecentlyAdded(rawLimit)
        val overrides = RecentlyAdded.addTimeOverrides(events)
        val key = Key(catalog, limit, signature(overrides))
        memo?.let { if (it.first.catalog === key.catalog && it.first.limit == limit && it.first.sig == key.sig) return it.second }
        computeCount++
        val ids = RecentlyAdded.newestFirst(RecentlyAdded.addedAtBySongId(catalog.songs, overrides), limit) {
            catalog.songsById.containsKey(it)
        }
        memo = key to ids
        return ids
    }

    /** Cheap yes/no gate: serves from the memo, else short-circuits on the first dated/added song. */
    @Synchronized
    fun hasItems(catalog: MergedCatalog, events: List<ActivityEvent>, rawLimit: Int): Boolean {
        if (ShellSettings.clampRecentlyAdded(rawLimit) <= 0) return false
        val m = memo
        if (m != null && m.first.catalog === catalog && m.first.limit == ShellSettings.clampRecentlyAdded(rawLimit) &&
            m.first.sig == signature(RecentlyAdded.addTimeOverrides(events))
        ) return m.second.isNotEmpty()
        if (catalog.songs.any { (it.dateAdded ?: 0.0) > 0 }) return true
        return events.any { it.kind == ActivityKind.CATALOG_ADD && it.at > 0 && catalog.songsById.containsKey(it.itemId) }
    }

    /** The virtual playlist, or null when empty. */
    fun playlist(catalog: MergedCatalog, events: List<ActivityEvent>, rawLimit: Int): SourcePlaylist? {
        val ids = songIds(catalog, events, rawLimit)
        if (ids.isEmpty()) return null
        return SourcePlaylist(IndexPlaylist(RecentlyAdded.PLAYLIST_ID, RecentlyAdded.NAME, ids), RecentlyAdded.NAME)
    }
}

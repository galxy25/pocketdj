package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind

/**
 * COLLECTION MEMBERSHIP, FLATTENED — port of apple Models/CollectionFlattener.swift. The one place
 * that turns the Pocket DAG + playlist templates + source playlists into "which songs are in
 * collection X" (albums expanded to their tracklists, child pockets flattened cycle-guarded,
 * first-seen dedup) and the add history into "when was each CURRENT member last added".
 * PURE: every input is a value.
 */
object CollectionFlattener {

    /** One collection's effective membership. [name] is LOCAL ONLY — never uploaded. */
    data class Collection(
        val id: String,
        /** "pocket" | "playlist" | "source" (the wire's `kind`). */
        val kind: String,
        val name: String,
        val songIds: List<String>,
    )

    data class SourcePlaylist(val id: String, val name: String, val songIds: List<String>)

    /** What the flattener reads. `albumTracks`: album id → ordered track ids (absent ⇒ contributes nothing). */
    data class Source(
        val pockets: List<Pocket> = emptyList(),
        val playlists: List<Playlist> = emptyList(),
        val sourcePlaylists: List<SourcePlaylist> = emptyList(),
        val albumTracks: Map<String, List<String>> = emptyMap(),
    )

    /** Every collection: pockets first, then playlists, then source playlists. Uncapped (see [capped]). */
    fun flatten(src: Source): List<Collection> {
        val byId = pocketsById(src.pockets)
        val out = ArrayList<Collection>(src.pockets.size + src.playlists.size + src.sourcePlaylists.size)
        for (p in src.pockets) {
            out += Collection(p.id, "pocket", p.name, pocketSongs(p.id, byId, src.albumTracks))
        }
        for (pl in src.playlists) {
            out += Collection(pl.id, "playlist", pl.name, playlistSongs(pl, byId, src.albumTracks))
        }
        for (s in src.sourcePlaylists) {
            out += Collection(s.id, "source", s.name, s.songIds.distinct())
        }
        return out
    }

    /** First occurrence wins on duplicate ids (iOS `uniquingKeysWith: { a, _ in a }`). */
    fun pocketsById(pockets: List<Pocket>): Map<String, Pocket> {
        val m = LinkedHashMap<String, Pocket>()
        for (p in pockets) m.putIfAbsent(p.id, p)
        return m
    }

    fun pocketSongs(id: String, pocketsById: Map<String, Pocket>, albumTracks: Map<String, List<String>>): List<String> {
        val out = ArrayList<String>()
        collectPocket(id, pocketsById, albumTracks, HashSet(), HashSet(), out)
        return out
    }

    private fun collectPocket(
        id: String, pocketsById: Map<String, Pocket>, albumTracks: Map<String, List<String>>,
        visited: MutableSet<String>, added: MutableSet<String>, out: MutableList<String>,
    ) {
        if (!visited.add(id)) return
        val p = pocketsById[id] ?: return
        for (s in p.songIds) if (added.add(s)) out += s
        for (a in p.albumIds) for (s in albumTracks[a].orEmpty()) if (added.add(s)) out += s
        for (c in p.childPocketIds) collectPocket(c, pocketsById, albumTracks, visited, added, out)
    }

    fun playlistSongs(pl: Playlist, pocketsById: Map<String, Pocket>, albumTracks: Map<String, List<String>>): List<String> {
        val out = ArrayList<String>()
        val added = HashSet<String>()
        val visited = HashSet<String>()
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) {
                when (n.kind) {
                    PlaylistNode.Kind.SONG -> n.songId?.let { if (added.add(it)) out += it }
                    PlaylistNode.Kind.ALBUM -> n.albumId?.let { a ->
                        for (s in albumTracks[a].orEmpty()) if (added.add(s)) out += s
                    }
                    PlaylistNode.Kind.POCKET -> n.pocketId?.let { collectPocket(it, pocketsById, albumTracks, visited, added, out) }
                    PlaylistNode.Kind.TEXT, PlaylistNode.Kind.SEQUENCE -> Unit
                }
                n.children?.let { walk(it) }
            }
        }
        walk(pl.sequences)
        return out
    }

    /** Trim to the server caps, in order, so the hash describes what the server stores. */
    fun capped(
        collections: List<Collection>, collectionCap: Int = 500, songCap: Int = 5_000, totalCap: Int = 100_000,
    ): List<Collection> {
        var budget = totalCap
        val out = ArrayList<Collection>()
        for (c in collections.take(collectionCap)) {
            val take = minOf(c.songIds.size, songCap, maxOf(0, budget))
            budget -= take
            out += c.copy(songIds = c.songIds.take(take))
        }
        return out
    }

    // MARK: - Add history

    /** A pocket id → its flattened songs, an album id → its tracks, anything else → itself. */
    fun expand(itemId: String, pocketsById: Map<String, Pocket>, albumTracks: Map<String, List<String>>): List<String> {
        if (pocketsById.containsKey(itemId)) return pocketSongs(itemId, pocketsById, albumTracks)
        albumTracks[itemId]?.let { return it }
        return listOf(itemId)
    }

    /**
     * Per collection id → song id → epoch ms that CURRENT member was last added. Replays add/remove
     * per (collection, ITEM) in time order (a later remove cancels), credits each standing item's
     * songs with its add time; a standing child pocket credits max(pocket added here, song added
     * to that pocket); a song reachable through several items takes the EARLIEST path.
     */
    fun addTimes(
        collections: List<Collection>, activity: List<ActivityEvent>,
        pockets: List<Pocket>, albumTracks: Map<String, List<String>>,
    ): Map<String, Map<String, Double>> {
        val byId = pocketsById(pockets)
        val standing = HashMap<String, MutableMap<String, Double>>()
        for (e in activity.sortedBy { it.at }) {
            val cid = e.collectionId?.takeIf { it.isNotEmpty() } ?: continue
            when (e.kind) {
                ActivityKind.ADD -> standing.getOrPut(cid) { HashMap() }[e.itemId] = e.at
                ActivityKind.REMOVE -> standing[cid]?.remove(e.itemId)
                else -> continue
            }
        }
        val memo = HashMap<String, Map<String, Double>>()
        fun times(cid: String, visiting: MutableSet<String>): Map<String, Double> {
            memo[cid]?.let { return it }
            if (!visiting.add(cid)) return emptyMap()
            val out = HashMap<String, Double>()
            for ((item, t) in standing[cid].orEmpty()) {
                if (byId.containsKey(item)) {
                    val inner = times(item, visiting)
                    for (s in pocketSongs(item, byId, albumTracks)) {
                        val v = maxOf(t, inner[s] ?: t)
                        out[s] = minOf(out[s] ?: v, v)
                    }
                } else {
                    for (s in albumTracks[item] ?: listOf(item)) out[s] = minOf(out[s] ?: t, t)
                }
            }
            visiting.remove(cid)
            memo[cid] = out
            return out
        }
        val result = LinkedHashMap<String, Map<String, Double>>()
        for (c in collections) {
            val all = times(c.id, HashSet())
            if (all.isEmpty()) continue
            val mine = LinkedHashMap<String, Double>()
            for (s in c.songIds) all[s]?.let { mine[s] = it }
            if (mine.isNotEmpty()) result[c.id] = mine
        }
        return result
    }

    /** One song-level add/remove (an album / pocket add expands into one row per song). */
    data class AddEvent(val songId: String, val collectionId: String, val atMs: Double, val kind: String)

    /** Song-level add history at/after [sinceMs], expanded to songs, NEWEST FIRST, at most [cap] rows. */
    fun addEvents(
        activity: List<ActivityEvent>, pockets: List<Pocket>, albumTracks: Map<String, List<String>>,
        sinceMs: Double, cap: Int = 5_000,
    ): List<AddEvent> {
        val byId = pocketsById(pockets)
        val out = ArrayList<AddEvent>()
        val sorted = activity.sortedWith(compareByDescending<ActivityEvent> { it.at }.thenBy { it.id })
        for (e in sorted) {
            if (out.size >= cap) break
            val cid = e.collectionId?.takeIf { it.isNotEmpty() } ?: continue
            if (e.at < sinceMs || (e.kind != ActivityKind.ADD && e.kind != ActivityKind.REMOVE)) continue
            for (s in expand(e.itemId, byId, albumTracks)) {
                if (out.size >= cap) break
                out += AddEvent(s, cid, e.at, e.kind.token)
            }
        }
        return out
    }
}

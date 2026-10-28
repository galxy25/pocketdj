package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.collections.AddTarget
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.Pocket
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull

/*
 * Wire types for the PocketDJ recommendation engine (`scripts/lambda/rec-engine`), ported from
 * iOS `RecModels.swift`.
 *
 * DOCTRINE: never rename the wire `kind`/`source`/`action`/`verdict` strings once shipped.
 * Responses decode EVERY field leniently (per-field try, defaults) so a newer server can add
 * keys without stranding older clients. Upload structs are additive-optional.
 */

// ---- Upload wire types -------------------------------------------------------------------------

@Serializable
data class RecPlayEventWire(val id: String, val songId: String, val atMs: Double, val source: String? = null)

@Serializable
data class RecFavoriteWire(val songId: String, val favorited: Boolean, val atMs: Double)

@Serializable
data class RecActivityWire(
    val id: String,
    val atMs: Double,
    val kind: String,
    val itemId: String,
    val collectionId: String? = null,
    val collectionKind: String? = null,
    val collectionName: String? = null,
)

/** Collector's Puzzle results (the Games seam; the provider stays null until Games wires it). */
@Serializable
data class RecPuzzleEventWire(
    val id: String,
    val atMs: Double,
    val gameId: String? = null,
    val songId: String? = null,
    val collectionId: String? = null,
    val action: String,
    val points: Int? = null,
)

/** 👍/👎 on a suggestion. `verdict` is "accepted" | "rejected" | "cleared" and never renames. */
@Serializable
data class RecFeedbackWire(
    val id: String,
    val atMs: Double,
    val songId: String,
    val verdict: String,
    val surface: String? = null,
    val context: String? = null,
)

@Serializable
data class RecCollectionsSnapshotWire(val atMs: Double, val collections: List<Entry>) {
    @Serializable
    data class Entry(val id: String, val kind: String, val name: String, val songIds: List<String>)
}

/** LIFETIME play counts — a SNAPSHOT (SET never ADD). `lastPlayedDays` = whole days since epoch. */
@Serializable
data class RecPlayCountsWire(
    val atMs: Double,
    val counts: Map<String, Int>,
    val lastPlayedDays: Map<String, Int>? = null,
)

/** The audio-analysis shortlist: ids and nothing else; a SET on the server. */
@Serializable
data class RecAudioQueueWire(val atMs: Double, val songIds: List<String>)

@Serializable
data class RecUploadBatch(
    val v: Int = 1,
    val deviceId: String,
    val sentAtMs: Double,
    val plays: List<RecPlayEventWire>? = null,
    val favorites: List<RecFavoriteWire>? = null,
    val activity: List<RecActivityWire>? = null,
    val puzzle: List<RecPuzzleEventWire>? = null,
    val feedback: List<RecFeedbackWire>? = null,
    val collectionsSnapshot: RecCollectionsSnapshotWire? = null,
    val playCounts: RecPlayCountsWire? = null,
    val audioQueue: RecAudioQueueWire? = null,
)

// ---- Response wire types (lenient) -------------------------------------------------------------

data class RecUploadResponse(val ok: Boolean? = null, val totalPlays: Int? = null)

data class RecSongSuggestionWire(
    val songId: String,
    val name: String? = null,
    val artist: String? = null,
    val score: Double? = null,
    val reasons: List<String>? = null,
)

data class RecSongsResponse(val songs: List<RecSongSuggestionWire> = emptyList())

data class RecCollectionSuggestionWire(
    val id: String,
    val kind: String? = null,
    val name: String? = null,
    val score: Double? = null,
    val reasons: List<String>? = null,
)

data class RecCollectionsResponse(
    val songId: String? = null,
    val suggestions: List<RecCollectionSuggestionWire> = emptyList(),
)

/** Lenient decoders: a malformed field is absent, a malformed row is dropped, never a throw. */
object RecWire {
    private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonElement?.dbl(): Double? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
    private fun JsonElement?.strList(): List<String>? =
        (this as? JsonArray)?.takeIf { arr -> arr.all { (it as? JsonPrimitive)?.isString == true } }
            ?.map { (it as JsonPrimitive).content }

    fun uploadResponse(root: JsonElement): RecUploadResponse {
        val o = root as? JsonObject ?: return RecUploadResponse()
        val ok = (o["ok"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
        val plays = ((o["totals"] as? JsonObject)?.get("plays") as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
        return RecUploadResponse(ok, plays)
    }

    fun songsResponse(root: JsonElement): RecSongsResponse {
        val rows = ((root as? JsonObject)?.get("songs") as? JsonArray).orEmpty().mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val id = o["songId"].str().orEmpty()
            if (id.isEmpty()) null
            else RecSongSuggestionWire(id, o["name"].str(), o["artist"].str(), o["score"].dbl(), o["reasons"].strList())
        }
        return RecSongsResponse(rows)
    }

    fun collectionsResponse(root: JsonElement): RecCollectionsResponse {
        val o = root as? JsonObject ?: return RecCollectionsResponse()
        val rows = (o["suggestions"] as? JsonArray).orEmpty().mapNotNull { el ->
            val r = el as? JsonObject ?: return@mapNotNull null
            val id = r["id"].str().orEmpty()
            if (id.isEmpty()) null
            else RecCollectionSuggestionWire(id, r["kind"].str(), r["name"].str(), r["score"].dbl(), r["reasons"].strList())
        }
        return RecCollectionsResponse(o["songId"].str(), rows)
    }
}

// ---- Suggestion -> AddTarget (pure) ------------------------------------------------------------

object RecSuggestionFilter {
    /**
     * Map server suggestions to local [AddTarget]s: drop ids that no longer resolve locally,
     * drop any already in [excluding] (dedupe by (kind, id), sequenceId ignored), cap at [limit].
     */
    fun resolveTargets(
        suggestions: List<RecCollectionSuggestionWire>,
        pockets: List<Pocket>,
        playlists: List<Playlist>,
        excluding: List<AddTarget>,
        limit: Int = 3,
    ): List<AddTarget> {
        val pocketIds = pockets.mapTo(HashSet()) { it.id }
        val playlistIds = playlists.mapTo(HashSet()) { it.id }
        val excluded = excluding.mapTo(HashSet()) { "${it.kind.token}|${it.id}" }
        val out = ArrayList<AddTarget>()
        for (s in suggestions) {
            if (out.size >= limit) break
            val kind = when (s.kind) {
                "pocket" -> AddTarget.Kind.POCKET
                "playlist" -> AddTarget.Kind.PLAYLIST
                else -> continue
            }
            val resolves = if (kind == AddTarget.Kind.POCKET) s.id in pocketIds else s.id in playlistIds
            if (!resolves || "${kind.token}|${s.id}" in excluded) continue
            out += AddTarget(kind, s.id)
        }
        return out
    }
}

// ---- Collection membership flattener (iOS CollectionFlattener, rec-snapshot subset) ------------

/** One collection's effective membership. `kind` = "pocket" | "playlist" | "source". */
data class RecFlatCollection(val id: String, val kind: String, val name: String, val songIds: List<String>)

object RecCollectionFlattener {
    /**
     * Pockets first, then playlists, then source playlists. A pocket's songs: own songIds, album
     * tracks, then child pockets (cycle-guarded). A playlist's: every song/album/pocket leaf of
     * every chapter in order. Deduped, first-seen order. Uncapped (see [capped]).
     */
    fun flatten(
        pockets: List<Pocket>,
        playlists: List<Playlist>,
        sourcePlaylists: List<Triple<String, String, List<String>>> = emptyList(),
        albumTracks: Map<String, List<String>> = emptyMap(),
    ): List<RecFlatCollection> {
        val byId = LinkedHashMap<String, Pocket>()
        for (p in pockets) byId.putIfAbsent(p.id, p)
        val out = ArrayList<RecFlatCollection>(pockets.size + playlists.size + sourcePlaylists.size)
        for (p in pockets) out += RecFlatCollection(p.id, "pocket", p.name, pocketSongs(p.id, byId, albumTracks))
        for (pl in playlists) out += RecFlatCollection(pl.id, "playlist", pl.name, playlistSongs(pl, byId, albumTracks))
        for ((id, name, ids) in sourcePlaylists) out += RecFlatCollection(id, "source", name, ids.distinct())
        return out
    }

    fun pocketSongs(id: String, byId: Map<String, Pocket>, albumTracks: Map<String, List<String>>): List<String> {
        val out = ArrayList<String>()
        collectPocket(id, byId, albumTracks, HashSet(), HashSet(), out)
        return out
    }

    private fun collectPocket(
        id: String, byId: Map<String, Pocket>, albumTracks: Map<String, List<String>>,
        visited: MutableSet<String>, added: MutableSet<String>, out: MutableList<String>,
    ) {
        if (!visited.add(id)) return
        val p = byId[id] ?: return
        for (s in p.songIds) if (added.add(s)) out += s
        for (a in p.albumIds) for (s in albumTracks[a].orEmpty()) if (added.add(s)) out += s
        for (c in p.childPocketIds) collectPocket(c, byId, albumTracks, visited, added, out)
    }

    fun playlistSongs(pl: Playlist, byId: Map<String, Pocket>, albumTracks: Map<String, List<String>>): List<String> {
        val out = ArrayList<String>()
        val added = HashSet<String>()
        val visited = HashSet<String>()
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) {
                when (n.kind) {
                    PlaylistNode.Kind.SONG -> n.songId?.let { if (added.add(it)) out += it }
                    PlaylistNode.Kind.ALBUM -> n.albumId?.let { a -> for (s in albumTracks[a].orEmpty()) if (added.add(s)) out += s }
                    PlaylistNode.Kind.POCKET -> n.pocketId?.let { collectPocket(it, byId, albumTracks, visited, added, out) }
                    else -> Unit
                }
                n.children?.let(::walk)
            }
        }
        walk(pl.sequences)
        return out
    }

    /** Every album id the flatten could need expanded, so callers resolve just those. */
    fun referencedAlbumIds(pockets: List<Pocket>, playlists: List<Playlist>): Set<String> {
        val ids = HashSet<String>()
        for (p in pockets) ids += p.albumIds
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) {
                if (n.kind == PlaylistNode.Kind.ALBUM) n.albumId?.let(ids::add)
                n.children?.let(::walk)
            }
        }
        for (pl in playlists) walk(pl.sequences)
        return ids
    }

    /** Trim to the server's caps, in order, so the membership hash describes what it stores. */
    fun capped(
        collections: List<RecFlatCollection>,
        collectionCap: Int = 500,
        songCap: Int = 5_000,
        totalCap: Int = 100_000,
    ): List<RecFlatCollection> {
        var budget = totalCap
        val out = ArrayList<RecFlatCollection>()
        for (c in collections.take(collectionCap)) {
            val take = minOf(c.songIds.size, songCap, maxOf(0, budget))
            budget -= take
            out += c.copy(songIds = c.songIds.take(take))
        }
        return out
    }
}

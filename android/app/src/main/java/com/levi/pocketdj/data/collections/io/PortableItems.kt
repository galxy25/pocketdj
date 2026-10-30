package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.rips.PlayResolver
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/**
 * The `items.json` codec for PORTABLE playlist/pocket zips (iOS `PortableItems.swift`).
 *
 * WIRE FORMAT: the PWA's `MusicItem[]` EXACTLY — songs use `name` (never `title`), `lengthMs`
 * (never `length`), REQUIRED `sentimentKeywords` (`[]`) and `explicit` (`false`), and bpm/key/camelot
 * are explicit `null` when unknown. `appleMusicId` rides as an extra field. `sourceId` is the fixed
 * sentinel `src_imported`. DECODE is lenient dict-parsing: unknown fields ignored, a junk row drops
 * only itself.
 */
object PortableItems {
    const val SOURCE_ID = "src_imported"

    data class Song(
        val id: String,
        val name: String,
        val artist: String,
        val albumId: String? = null,
        val trackNumber: Int? = null,
        val year: Int? = null,
        val lengthMs: Long? = null,
        val bpm: Double? = null,
        val key: String? = null,
        val camelot: String? = null,
        val appleMusicId: String? = null,
    )

    data class Album(
        val id: String,
        val name: String,
        val artist: String,
        val trackIds: List<String>,
        val coverArtUrl: String? = null,
        val genre: String? = null,
        val year: Int? = null,
    )

    data class Payload(val songs: List<Song> = emptyList(), val albums: List<Album> = emptyList()) {
        val isEmpty: Boolean get() = songs.isEmpty() && albums.isEmpty()
    }

    /** iOS `ProfileSourceStore.songIdPrefix`: on-device profile (sample/demux) songs never travel. */
    const val PROFILE_SONG_PREFIX = "pdj_"
    fun isProfileSongId(id: String): Boolean = id.startsWith(PROFILE_SONG_PREFIX)

    /** Only catalog ids travel in items.json: never studio or profile ids. */
    fun isPortable(id: String): Boolean = !PlayResolver.isStudioId(id) && !isProfileSongId(id)

    data class Ids(val songs: Set<String>, val albums: Set<String>)

    // MARK: Collect

    /** Catalog ids a playlist (+ bundled pockets) references. Studio ids never travel. */
    fun referencedIds(playlist: Playlist, pockets: List<Pocket>): Ids {
        val songs = LinkedHashSet<String>()
        val albums = LinkedHashSet<String>()
        fun walk(nodes: List<PlaylistNode>) {
            for (n in nodes) when (n.kind) {
                PlaylistNode.Kind.SONG -> n.songId?.takeIf { isPortable(it) }?.let(songs::add)
                PlaylistNode.Kind.ALBUM -> n.albumId?.let(albums::add)
                PlaylistNode.Kind.SEQUENCE -> walk(n.children.orEmpty())
                else -> Unit
            }
        }
        walk(playlist.sequences)
        collect(pockets, songs, albums)
        return Ids(songs, albums)
    }

    /** Catalog ids a pocket bundle references (root + DAG-expanded children). */
    fun referencedIds(pocket: Pocket, children: List<Pocket>): Ids {
        val songs = LinkedHashSet<String>()
        val albums = LinkedHashSet<String>()
        collect(listOf(pocket) + children, songs, albums)
        return Ids(songs, albums)
    }

    private fun collect(pockets: List<Pocket>, songs: MutableSet<String>, albums: MutableSet<String>) {
        for (p in pockets) {
            p.songIds.filter(::isPortable).forEach(songs::add)
            albums.addAll(p.albumIds)
        }
    }

    // MARK: Encode

    /**
     * items.json bytes for the referenced ids, closed over the catalog the PWA way (two passes:
     * albums pull their track songs, songs pull their album). Albums first, then songs, each sorted by id.
     */
    fun encode(
        songIds: Set<String>,
        albumIds: Set<String>,
        songsById: Map<String, IndexSong>,
        albumsById: Map<String, IndexAlbum>,
        nowMs: Long = System.currentTimeMillis(),
        json: Json = Json,
    ): ByteArray = ZipIo.bytes(encodeElement(songIds, albumIds, songsById, albumsById, nowMs), json)

    fun encodeElement(
        songIds: Set<String>,
        albumIds: Set<String>,
        songsById: Map<String, IndexSong>,
        albumsById: Map<String, IndexAlbum>,
        nowMs: Long = System.currentTimeMillis(),
    ): JsonArray {
        val songs = LinkedHashMap<String, IndexSong>()
        val albums = LinkedHashMap<String, IndexAlbum>()
        for (id in songIds) songsById[id]?.let { songs[id] = it }
        for (id in albumIds) albumsById[id]?.let { albums[id] = it }
        for (pass in 0 until 2) {
            var need = false
            for (a in albums.values.toList()) for (t in a.trackList) {
                if (songs[t] == null) songsById[t]?.let { songs[t] = it; need = true }
            }
            for (s in songs.values.toList()) {
                val aid = s.albumId ?: continue
                if (albums[aid] == null) albumsById[aid]?.let { albums[aid] = it; need = true }
            }
            if (!need) break
        }
        val now = nowMs
        val rows = ArrayList<JsonElement>()
        for (a in albums.values.sortedBy { it.id }) {
            rows += buildJsonObject {
                put("id", a.id); put("sourceId", SOURCE_ID); put("type", "album")
                put("createdAt", now); put("updatedAt", now)
                put("artist", a.artist); put("name", a.name)
                put("trackIds", JsonArray(a.trackList.map(::JsonPrimitive)))
                a.coverArt?.let { put("coverArtUrl", it) }
                a.coverArtSources?.takeIf { it.isNotEmpty() }?.let { srcs ->
                    put("coverArtSources", JsonArray(srcs.map { s ->
                        buildJsonObject {
                            s.type?.let { put("type", it) }; put("url", s.url)
                            s.cors?.let { put("cors", it) }
                        }
                    }))
                }
                a.genre?.let { put("genre", it) }
                a.year?.let { put("year", it) }
            }
        }
        for (s in songs.values.sortedBy { it.id }) {
            rows += buildJsonObject {
                put("id", s.id); put("sourceId", SOURCE_ID); put("type", "song")
                put("createdAt", now); put("updatedAt", now)
                put("artist", s.artist); put("name", s.name)
                put("sentimentKeywords", JsonArray((s.sentimentKeywords ?: emptyList()).map(::JsonPrimitive)))
                put("explicit", s.explicit ?: false)
                put("bpm", s.bpm?.let { JsonPrimitive(it) } ?: JsonNull)
                put("key", s.key?.let { JsonPrimitive(it) } ?: JsonNull)
                put("camelot", s.camelot?.let { JsonPrimitive(it) } ?: JsonNull)
                s.albumId?.let { put("albumId", it) }
                s.trackNumber?.let { put("trackNumber", it) }
                s.year?.let { put("year", it) }
                s.length?.let { put("lengthMs", it) }
                s.appleMusicId?.let { put("appleMusicId", it) }
            }
        }
        return JsonArray(rows)
    }

    // MARK: Decode

    /** Lenient parse (PWA or native). A row missing essentials is skipped, never fatal. */
    fun decode(data: ByteArray, json: Json = Json): Payload {
        val root = runCatching { json.parseToJsonElement(String(data, Charsets.UTF_8)) }.getOrNull() as? JsonArray
            ?: return Payload()
        val songs = ArrayList<Song>()
        val albums = ArrayList<Album>()
        for (el in root) {
            val obj = el as? JsonObject ?: continue
            val id = obj.str("id") ?: continue
            val type = obj.str("type")
            val name = obj.str("name") ?: obj.str("title")
            val artist = obj.str("artist")
            if (type == "album" || (type == null && obj["trackIds"] != null)) {
                if (name == null || artist == null) continue
                val trackIds = obj.strList("trackIds") ?: obj.strList("trackList") ?: emptyList()
                val cover = obj.str("coverArtUrl")
                    ?: ((obj["coverArtSources"] as? JsonArray)?.firstOrNull() as? JsonObject)?.str("url")
                    ?: obj.str("coverArt")
                albums += Album(id, name, artist, trackIds, cover, obj.str("genre"), obj.int("year"))
            } else if (type == "song" || type == null) {
                if (name == null || artist == null) continue
                songs += Song(
                    id = id, name = name, artist = artist,
                    albumId = obj.str("albumId"),
                    trackNumber = obj.int("trackNumber"),
                    year = obj.int("year"),
                    lengthMs = obj.num("lengthMs")?.toLong() ?: obj.num("length")?.toLong(),
                    bpm = obj.num("bpm"),
                    key = obj.str("key"),
                    camelot = obj.str("camelot"),
                    appleMusicId = obj.str("appleMusicId"),
                )
            }
        }
        return Payload(songs, albums)
    }

    private fun JsonObject.str(k: String): String? =
        (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.num(k: String): Double? =
        (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull

    private fun JsonObject.int(k: String): Int? = num(k)?.toInt()

    /** Present + every element a string; anything else ⇒ null (iOS `as? [String]`). */
    private fun JsonObject.strList(k: String): List<String>? {
        val arr = this[k] as? JsonArray ?: return null
        val out = arr.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return null }
        return out
    }
}

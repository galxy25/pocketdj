package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.PdjJson
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject

/**
 * Typed, lenient views of Apple Music Web API payloads. Parsing is done over
 * [JsonElement] rather than strict `@Serializable` classes so ONE malformed row
 * costs that row, never the page (mirrors iOS `AppleMusicWebAPI` /
 * `AppleMusicFavorites`). Every parser returns null when the envelope itself is
 * unreadable, so callers can tell "empty" from "could not read".
 */
data class AmSong(
    val id: String,
    val title: String,
    val artist: String,
    val album: String?,
    val durationSec: Double?,
    val isrc: String? = null,
    val previewUrl: String? = null,
    val artworkUrl: String? = null,
    val explicit: Boolean = false,
)

data class AmAlbum(
    val id: String,
    val title: String,
    val artist: String,
    val releaseDate: String?,
    val trackCount: Int?,
    val artworkUrl: String? = null,
)

data class AmLibraryPlaylist(
    val id: String,
    val name: String,
    /** `attributes.canEdit`; ABSENT reads as editable (iOS invariant). */
    val canEdit: Boolean,
)

/** A library-playlist track page. [rowCount] (raw rows) is the only correct paging terminator. */
data class AmTrackPage(
    val catalogIds: List<String>,
    val rowCount: Int,
    val hasNext: Boolean,
    val nextOffset: Int?,
)

data class AmPage<T>(val items: List<T>, val nextOffset: Int?, val hasCursor: Boolean = nextOffset != null) {
    val hasNext: Boolean get() = nextOffset != null
}

data class AmCatalogSearch(
    val songs: AmPage<AmSong>,
    val albums: AmPage<AmAlbum>,
)

/** One catalog artist with its `latest-release` and `similar-artists` views. */
data class AmArtist(
    val id: String,
    val name: String,
    val latestRelease: AmAlbum?,
    val similarArtistIds: List<String>,
)

enum class AmSearchType(val wire: String) { SONGS("songs"), ALBUMS("albums") }
enum class AmLibraryKind(val wire: String) { SONGS("songs"), ALBUMS("albums") }

object AppleMusicApiModels {
    private val json: Json = PdjJson.lenient

    private fun root(body: String): JsonObject? =
        runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull()

    private fun JsonElement?.obj(): JsonObject? = this as? JsonObject
    private fun JsonElement?.arr(): JsonArray? = this as? JsonArray
    private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    /** Offset encoded in a `next` cursor (`/v1/...?offset=25&limit=25`), or null. */
    fun nextOffset(next: String?): Int? {
        if (next.isNullOrBlank()) return null
        val q = next.substringAfter('?', "")
        for (pair in q.split('&')) {
            if (pair.startsWith("offset=")) return pair.removePrefix("offset=").toIntOrNull()
        }
        return null
    }

    private fun artwork(attrs: JsonObject?): String? =
        attrs?.get("artwork").obj()?.get("url").str()
            ?.replace("{w}", "300")?.replace("{h}", "300")

    fun song(row: JsonElement): AmSong? {
        val o = row.obj() ?: return null
        val id = o["id"].str() ?: return null
        val a = o["attributes"].obj()
        return AmSong(
            id = id,
            title = a?.get("name").str().orEmpty(),
            artist = a?.get("artistName").str().orEmpty(),
            album = a?.get("albumName").str(),
            durationSec = (a?.get("durationInMillis") as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()?.div(1000),
            isrc = a?.get("isrc").str(),
            previewUrl = a?.get("previews").arr()?.firstOrNull().obj()?.get("url").str(),
            artworkUrl = artwork(a),
            explicit = a?.get("contentRating").str() == "explicit",
        )
    }

    fun album(row: JsonElement): AmAlbum? {
        val o = row.obj() ?: return null
        val id = o["id"].str() ?: return null
        val a = o["attributes"].obj()
        return AmAlbum(
            id = id,
            title = a?.get("name").str().orEmpty(),
            artist = a?.get("artistName").str().orEmpty(),
            releaseDate = a?.get("releaseDate").str(),
            trackCount = (a?.get("trackCount") as? JsonPrimitive)?.intOrNull,
            artworkUrl = artwork(a),
        )
    }

    private fun <T> page(container: JsonObject?, parse: (JsonElement) -> T?): AmPage<T> {
        val rows = container?.get("data").arr().orEmpty()
        val next = container?.get("next").str()
        return AmPage(rows.mapNotNull(parse), nextOffset(next), !next.isNullOrBlank())
    }

    /** `GET /v1/catalog/{sf}/search` -> songs and/or albums. Null when unreadable. */
    fun parseCatalogSearch(body: String): AmCatalogSearch? {
        val results = root(body)?.get("results").obj() ?: return null
        return AmCatalogSearch(
            songs = page(results["songs"].obj(), ::song),
            albums = page(results["albums"].obj(), ::album),
        )
    }

    /** `GET /v1/me/library/playlists`. Null when the `data` array is unreadable. */
    fun parseLibraryPlaylists(body: String): AmPage<AmLibraryPlaylist>? {
        val r = root(body) ?: return null
        if (r["data"].arr() == null) return null
        return page(r) { row ->
            val o = row.obj() ?: return@page null
            val id = o["id"].str() ?: return@page null
            val a = o["attributes"].obj()
            AmLibraryPlaylist(
                id = id,
                name = a?.get("name").str().orEmpty(),
                canEdit = (a?.get("canEdit") as? JsonPrimitive)?.booleanOrNull ?: true,
            )
        }
    }

    /** Ids of a created playlist response (`data[0].id`). */
    fun parseFirstId(body: String): String? =
        root(body)?.get("data").arr()?.firstOrNull().obj()?.get("id").str()

    /** `GET /v1/me/library/playlists/{id}/tracks` -> catalog ids (deduped, order kept). */
    fun parseTrackPage(body: String): AmTrackPage? {
        val r = root(body) ?: return null
        val rows = r["data"].arr() ?: return null
        val ids = LinkedHashSet<String>()
        for (row in rows) {
            val pp = row.obj()?.get("attributes").obj()?.get("playParams").obj() ?: continue
            (pp["catalogId"].str() ?: pp["id"].str())?.let(ids::add)
        }
        val next = r["next"].str()
        return AmTrackPage(ids.toList(), rows.size, next != null, nextOffset(next))
    }

    fun parseStorefront(body: String): String? =
        root(body)?.get("data").arr()?.firstOrNull().obj()?.get("id").str()

    /**
     * Ids the account LOVES (`value == 1`). Returns NULL, never an empty set, when
     * the body cannot be read: an empty set would let the caller tombstone the
     * whole favorites library (iOS invariant). Bad rows are dropped individually.
     */
    fun parseLovedIds(body: String): Set<String>? {
        val rows = root(body)?.get("data").arr() ?: return null
        val loved = LinkedHashSet<String>()
        for (row in rows) {
            val o = row.obj() ?: continue
            val id = o["id"].str() ?: continue
            val v = (o["attributes"].obj()?.get("value") as? JsonPrimitive)?.intOrNull
            if (v == 1) loved.add(id)
        }
        return loved
    }

    /** `GET /v1/catalog/{sf}/artists?views=latest-release,similar-artists`. Null when `data` is missing. */
    fun parseArtists(body: String): List<AmArtist>? {
        val rows = root(body)?.get("data").arr() ?: return null
        return rows.mapNotNull { row ->
            val o = row.obj() ?: return@mapNotNull null
            val id = o["id"].str() ?: return@mapNotNull null
            val views = o["views"].obj()
            val latest = views?.get("latest-release").obj()?.get("data").arr()?.firstOrNull()?.let(::album)
            val similar = views?.get("similar-artists").obj()?.get("data").arr()
                ?.mapNotNull { it.obj()?.get("id").str() }.orEmpty()
            AmArtist(id, o["attributes"].obj()?.get("name").str().orEmpty(), latest, similar)
        }
    }
}

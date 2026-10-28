package com.levi.pocketdj.data.applemusic

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** A flattened Apple Music album reference (iOS AppleMusicAlbumRef). */
data class AppleMusicAlbumRef(
    val storeId: String,
    val title: String,
    val artist: String,
    val year: Int? = null,
    val artworkUrl: String? = null,
    /** music.apple.com deep link. */
    val url: String? = null,
)

/** A recognized track resolved against Apple Music (iOS AppleMusicResolution). */
data class AppleMusicResolution(
    val songStoreId: String,
    val title: String,
    val artist: String,
    val inLibrary: Boolean,
    val album: AppleMusicAlbumRef?,
    val songUrl: String? = null,
)

/** Lenient parsers for the two Web-API payloads the resolver reads (pure, JVM-tested). */
object AppleMusicRecognitionParsing {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private fun JsonElement?.obj() = this as? JsonObject
    private fun JsonElement?.arr() = this as? JsonArray
    private fun JsonElement?.str() = (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun albumRef(row: JsonElement?): AppleMusicAlbumRef? {
        val o = row.obj() ?: return null
        val id = o["id"].str() ?: return null
        val a = o["attributes"].obj()
        val year = a?.get("releaseDate").str()?.take(4)?.toIntOrNull()
        return AppleMusicAlbumRef(
            storeId = id,
            title = a?.get("name").str().orEmpty(),
            artist = a?.get("artistName").str().orEmpty(),
            year = year,
            artworkUrl = a?.get("artwork").obj()?.get("url").str()?.replace("{w}", "300")?.replace("{h}", "300"),
            url = a?.get("url").str(),
        )
    }

    /** `GET /v1/catalog/{sf}/songs/{id}?include=albums` or a search top result -> (song, first album). */
    fun parseCatalogSong(body: String): AppleMusicResolution? {
        val root = runCatching { json.parseToJsonElement(body).obj() }.getOrNull() ?: return null
        val row = root["data"].arr()?.firstOrNull().obj() ?: return null
        return resolutionOf(row, inLibrary = false)
    }

    /** Catalog `search?types=songs` body -> first song. */
    fun parseSearchTopSong(body: String): AppleMusicResolution? {
        val root = runCatching { json.parseToJsonElement(body).obj() }.getOrNull() ?: return null
        val row = root["results"].obj()?.get("songs").obj()?.get("data").arr()?.firstOrNull().obj() ?: return null
        return resolutionOf(row, inLibrary = false)
    }

    private fun resolutionOf(row: JsonObject, inLibrary: Boolean): AppleMusicResolution? {
        val id = row["id"].str() ?: return null
        val a = row["attributes"].obj()
        val album = row["relationships"].obj()?.get("albums").obj()?.get("data").arr()?.firstOrNull()?.let(::albumRef)
        return AppleMusicResolution(
            songStoreId = id,
            title = a?.get("name").str().orEmpty(),
            artist = a?.get("artistName").str().orEmpty(),
            inLibrary = inLibrary,
            album = album,
            songUrl = a?.get("url").str(),
        )
    }

    /** `GET /v1/me/library/search?types=library-songs` body -> (title, artist) rows. */
    fun libraryRows(body: String): List<Pair<String, String>> {
        val root = runCatching { json.parseToJsonElement(body).obj() }.getOrNull() ?: return emptyList()
        val rows = root["results"].obj()?.get("library-songs").obj()?.get("data").arr() ?: return emptyList()
        return rows.mapNotNull { r ->
            val a = r.obj()?.get("attributes").obj() ?: return@mapNotNull null
            a["name"].str().orEmpty() to a["artistName"].str().orEmpty()
        }
    }
}

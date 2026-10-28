package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
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

/** What the Apple Music block of the result sheet offers (iOS AppleMusicRecognitionAction). */
sealed interface AppleMusicRecognitionAction {
    data object Unavailable : AppleMusicRecognitionAction
    data object Connect : AppleMusicRecognitionAction
    data object Checking : AppleMusicRecognitionAction
    data object NotFound : AppleMusicRecognitionAction
    data class OpenIndexAlbum(val albumId: String) : AppleMusicRecognitionAction
    data class OpenRecognizedAlbum(val album: AppleMusicAlbumRef) : AppleMusicRecognitionAction
    data object InLibrary : AppleMusicRecognitionAction
    data class OpenInMusicApp(val url: String) : AppleMusicRecognitionAction
    data class AddToLibrary(val storeId: String, val title: String, val artist: String) : AppleMusicRecognitionAction
}

/** Pure helpers for the recognizer -> Apple Music library flow (iOS AppleMusicRecognition). */
object AppleMusicRecognition {

    fun action(
        available: Boolean,
        canContribute: Boolean,
        canAdd: Boolean,
        resolving: Boolean,
        resolution: AppleMusicResolution?,
        indexAlbumId: String?,
    ): AppleMusicRecognitionAction {
        if (!available) return AppleMusicRecognitionAction.Unavailable
        if (!canContribute) return AppleMusicRecognitionAction.Connect
        if (resolving) return AppleMusicRecognitionAction.Checking
        val r = resolution ?: return AppleMusicRecognitionAction.NotFound
        if (r.inLibrary) {
            if (indexAlbumId != null) return AppleMusicRecognitionAction.OpenIndexAlbum(indexAlbumId)
            r.album?.let { return AppleMusicRecognitionAction.OpenRecognizedAlbum(it) }
            return AppleMusicRecognitionAction.InLibrary
        }
        if (canAdd) return AppleMusicRecognitionAction.AddToLibrary(r.songStoreId, r.title, r.artist)
        r.songUrl?.let { return AppleMusicRecognitionAction.OpenInMusicApp(it) }
        return AppleMusicRecognitionAction.NotFound
    }

    /** Catalog album matching a resolved Apple Music album by normalized title + compatible artist. */
    fun indexAlbum(ref: AppleMusicAlbumRef, albums: Collection<IndexAlbum>): IndexAlbum? {
        val title = ShazamCatalogMatch.norm(ref.title)
        if (title.isEmpty()) return null
        val artist = ShazamCatalogMatch.norm(ref.artist)
        return albums.firstOrNull { album ->
            if (ShazamCatalogMatch.norm(album.name) != title) return@firstOrNull false
            artist.isEmpty() || ShazamCatalogMatch.artistsCompatible(ShazamCatalogMatch.norm(album.artist), artist)
        }
    }

    /** Catalog id when the track is indexed, else a colon-free `amrec_<storeId>`. */
    fun burnSongId(catalogSongId: String?, storeId: String): String =
        if (!catalogSongId.isNullOrEmpty()) catalogSongId else "amrec_$storeId"

    /** The namespaced catalog id of an Apple Music (Local) song. */
    fun namespacedSongId(storeId: String): String = "am:$storeId"

    /** Already-indexed song for a recognized track: `am:<id>`, stamped appleMusicId, else title+artist. */
    fun indexSong(storeId: String, title: String?, artist: String?, songs: Collection<IndexSong>): IndexSong? {
        val namespaced = namespacedSongId(storeId)
        songs.firstOrNull { it.id == namespaced || it.appleMusicId == storeId }?.let { return it }
        val nt = title?.let(ShazamCatalogMatch::norm)
        if (nt.isNullOrEmpty()) return null
        val na = artist?.let(ShazamCatalogMatch::norm)
        return songs.firstOrNull { song ->
            if (ShazamCatalogMatch.norm(song.name) != nt) return@firstOrNull false
            na.isNullOrEmpty() || ShazamCatalogMatch.artistsCompatible(ShazamCatalogMatch.norm(song.artist), na)
        }
    }
}

/** Seam the Compose section drives; the production adapter lives in [com.levi.pocketdj.di.BrowseGraph]. */
interface AppleMusicRecognitionPort {
    /** Apple Music is usable in this build (the Web API is always compiled in on Android). */
    val available: Boolean
    /** The account is linked (Music-User-Token present). */
    suspend fun canContribute(): Boolean
    /** Web-API library writes work on Android. */
    val canAdd: Boolean
    suspend fun resolve(storeId: String?, title: String?, artist: String?): AppleMusicResolution?
    /** Saves the song to the user's own Apple Music library; false = rejected. */
    suspend fun addSongToLibrary(storeId: String): Boolean
    /** Asks the rip server to prepare + burn [songId]; the tracker reports progress. */
    suspend fun startRipAndBurn(songId: String, title: String, artist: String, storeId: String)
}

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

    /**
     * `GET /v1/me/library/search?types=library-songs` body: true when a library song matches the
     * resolved title + compatible artist (the iOS isInLibrary probe).
     */
    fun libraryContains(body: String, title: String, artist: String): Boolean {
        val root = runCatching { json.parseToJsonElement(body).obj() }.getOrNull() ?: return false
        val rows = root["results"].obj()?.get("library-songs").obj()?.get("data").arr() ?: return false
        val nt = ShazamCatalogMatch.norm(title)
        val na = ShazamCatalogMatch.norm(artist)
        return rows.any { r ->
            val a = r.obj()?.get("attributes").obj() ?: return@any false
            ShazamCatalogMatch.norm(a["name"].str().orEmpty()) == nt &&
                (na.isEmpty() || ShazamCatalogMatch.artistsCompatible(ShazamCatalogMatch.norm(a["artistName"].str().orEmpty()), na))
        }
    }
}

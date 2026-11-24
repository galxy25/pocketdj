package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.settings.PrefKey
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/** Settings for the on-device Apple Music library source (Settings ▸ Apple Music toggle; default ON after sign-in). */
object AmLibrarySettings {
    val ENABLED = PrefKey.boolean("amLibraryIndexEnabled", true)

    /** Epoch ms of the last SUCCESSFUL index run; 0 = never. */
    val LAST_INDEX_MS = PrefKey.double("amLibraryLastIndexAtMs", 0.0)
}

/** One library song row (`/v1/me/library/songs?include=catalog`). */
data class AmLibrarySong(
    val libraryId: String,
    /** Catalog store id from the `catalog` relationship (or playParams) - NOT the `i.…` library id. */
    val appleMusicId: String?,
    val title: String,
    val artist: String,
    val album: String?,
    val artworkUrl: String?,
    val durationMs: Int?,
    val trackNumber: Int?,
    val year: Int?,
    val genre: String?,
    /** `attributes.dateAdded` when the API carries it. */
    val dateAddedMs: Double?,
)

data class AmLibraryAlbum(
    val libraryId: String,
    val title: String,
    val artist: String,
    val artworkUrl: String?,
    val genre: String?,
    val year: Int?,
)

/** Lenient parsers (one bad row costs that row, never the page). */
object AppleMusicLibraryParsing {
    private fun root(body: String): JsonObject? =
        runCatching { PdjJson.lenient.parseToJsonElement(body) as? JsonObject }.getOrNull()

    private fun JsonElement?.obj() = this as? JsonObject
    private fun JsonElement?.arr() = this as? JsonArray
    private fun JsonElement?.str() = (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

    private fun art(attrs: JsonObject?): String? =
        attrs?.get("artwork").obj()?.get("url").str()?.replace("{w}", "600")?.replace("{h}", "600")

    fun yearOf(date: String?): Int? =
        date?.take(4)?.takeIf { it.length == 4 && it.all(Char::isDigit) }?.toIntOrNull()

    /** ISO-8601 instant or bare date -> epoch ms; null when absent/unparseable. */
    fun parseDateMs(s: String?): Double? {
        if (s.isNullOrBlank()) return null
        val t = s.trim()
        return runCatching { Instant.parse(t).toEpochMilli().toDouble() }.getOrNull()
            ?: runCatching { java.time.OffsetDateTime.parse(t).toInstant().toEpochMilli().toDouble() }.getOrNull()
            ?: runCatching { LocalDate.parse(t.take(10)).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli().toDouble() }.getOrNull()
    }

    /** The catalog id of a library row: the `catalog` relationship first, then non-library playParams. */
    private fun catalogId(row: JsonObject, attrs: JsonObject?): String? {
        row["relationships"].obj()?.get("catalog").obj()?.get("data").arr()
            ?.firstOrNull().obj()?.get("id").str()?.takeIf { it.isNotBlank() }?.let { return it }
        val pp = attrs?.get("playParams").obj() ?: return null
        pp["catalogId"].str()?.takeIf { it.isNotBlank() }?.let { return it }
        val isLib = (pp["isLibrary"] as? JsonPrimitive)?.booleanOrNull == true
        return pp["id"].str()?.takeIf { !isLib && !it.startsWith("i.") && it.isNotBlank() }
    }

    private fun <T> page(r: JsonObject, parse: (JsonObject) -> T?): AmPage<T>? {
        val rows = r["data"].arr() ?: return null
        val next = r["next"].str()
        return AmPage(rows.mapNotNull { it.obj()?.let(parse) }, AppleMusicApiModels.nextOffset(next), !next.isNullOrBlank())
    }

    fun parseSongs(body: String): AmPage<AmLibrarySong>? {
        val r = root(body) ?: return null
        return page(r) { row ->
            val id = row["id"].str()?.takeIf { it.isNotBlank() } ?: return@page null
            val a = row["attributes"].obj()
            val name = a?.get("name").str() ?: return@page null
            AmLibrarySong(
                libraryId = id,
                appleMusicId = catalogId(row, a),
                title = name,
                artist = a?.get("artistName").str().orEmpty(),
                album = a?.get("albumName").str()?.takeIf { it.isNotEmpty() },
                artworkUrl = art(a),
                durationMs = (a?.get("durationInMillis") as? JsonPrimitive)?.intOrNull,
                trackNumber = (a?.get("trackNumber") as? JsonPrimitive)?.intOrNull,
                year = yearOf(a?.get("releaseDate").str()),
                genre = a?.get("genreNames").arr()?.firstOrNull().str(),
                dateAddedMs = parseDateMs(a?.get("dateAdded").str()),
            )
        }
    }

    fun parseAlbums(body: String): AmPage<AmLibraryAlbum>? {
        val r = root(body) ?: return null
        return page(r) { row ->
            val id = row["id"].str()?.takeIf { it.isNotBlank() } ?: return@page null
            val a = row["attributes"].obj()
            AmLibraryAlbum(
                libraryId = id,
                title = a?.get("name").str() ?: return@page null,
                artist = a?.get("artistName").str().orEmpty(),
                artworkUrl = art(a),
                genre = a?.get("genreNames").arr()?.firstOrNull().str(),
                year = yearOf(a?.get("releaseDate").str()),
            )
        }
    }
}

/**
 * Builds the on-device "Apple Music" library source from the Apple Music Web API (iOS
 * `AppleMusicLibraryIndexer`, with the Web API standing in for MusicKit library reads, which the Android SDK
 * lacks). A FULL run replaces the store wholesale; an INCREMENTAL run appends songs the store has not seen.
 *
 * The Web API has no documented sort by add date, so an incremental run walks the song pages and keeps
 * only unseen `songId`s (idempotent) - the cost is paging, never a rewrite. `dateAdded` is used when the API
 * carries it; otherwise a row keeps an add time already known for it (pulled from iOS / an earlier run),
 * and only a genuinely new row is stamped with the first-indexed time.
 */
class AppleMusicLibraryIndexer(
    private val api: AppleMusicApi,
    private val store: AppleMusicLibraryStore,
    private val nowMs: () -> Double = { System.currentTimeMillis().toDouble() },
    private val pageSize: Int = 100,
    private val maxPages: Int = 2000,
) {
    enum class Mode { AUTO, FULL }

    sealed interface Outcome {
        /** [added] rows were new this run (full run: every row). */
        data class Indexed(val songs: Int, val added: Int, val full: Boolean) : Outcome
        data object NeedsUserToken : Outcome
        data class RateLimited(val retryAfterSec: Long?) : Outcome
        data class Failed(val status: Int?, val message: String) : Outcome
    }

    suspend fun run(mode: Mode = Mode.AUTO): Outcome {
        val songs = when (val r = allSongs()) {
            is AmResult.Ok -> r.value
            else -> return r.asOutcome()
        }
        // The whole song list is in hand every run, so reconcile removals: a stored row the library no longer
        // lists (deleted in Music) escalates the run to a full replace. An empty listing never counts (a blip).
        val live = songs.mapTo(HashSet()) { AppleMusicLibraryStore.SONG_PREFIX + it.libraryId }
        val removed = songs.isNotEmpty() && store.songs.any { it.songId !in live }
        val full = mode == Mode.FULL || store.lastAddedMs == null || store.songs.isEmpty() || removed
        val known = store.songs.associate { it.songId to it.addedAtMs }
        val now = nowMs()
        val entries = songs.map { toEntry(it, known, now) }
        val fresh = if (full) entries else entries.filter { it.songId !in known }
        // The incremental path keeps the stored order; new rows arrive in the order the API listed them.
        val albums = enrichAlbums(groupAlbums(if (full) entries else fresh))
        val playlists = playlists(entries)
        val mark = (entries.maxOfOrNull { it.addedAtMs })
        if (full) {
            store.replaceAll(entries, albums, playlists ?: store.playlists, mark)
        } else {
            store.applyIncremental(fresh, albums, playlists, mark)
        }
        return Outcome.Indexed(songs = store.songs.size, added = fresh.size, full = full)
    }

    private fun toEntry(s: AmLibrarySong, known: Map<String, Double>, now: Double): AppleMusicLibraryStore.SongEntry {
        val id = AppleMusicLibraryStore.SONG_PREFIX + s.libraryId
        val added = s.dateAddedMs ?: known[id]?.takeIf { it > 0 } ?: now
        return AppleMusicLibraryStore.SongEntry(
            songId = id, libraryId = s.libraryId, appleMusicId = s.appleMusicId,
            title = s.title, artist = s.artist, album = s.album,
            albumId = s.album?.let { albumId(it, s.artist) },
            artworkUrl = s.artworkUrl, durationMs = s.durationMs, trackNumber = s.trackNumber,
            year = s.year, genre = s.genre, addedAtMs = added,
        )
    }

    private suspend fun allSongs(): AmResult<List<AmLibrarySong>> {
        val out = LinkedHashMap<String, AmLibrarySong>()
        var offset = 0
        repeat(maxPages) {
            when (val r = api.librarySongsPage(offset, pageSize)) {
                is AmResult.Ok -> {
                    r.value.items.forEach { out.putIfAbsent(it.libraryId, it) }
                    offset = r.value.nextOffset
                        ?: if (r.value.hasCursor) offset + r.value.items.size.coerceAtLeast(1) else return AmResult.Ok(out.values.toList())
                }
                else -> return r.asFailure()
            }
        }
        return AmResult.Ok(out.values.toList())
    }

    /** Library albums add artwork/genre/year the song rows lack. Best effort: any failure keeps the grouped albums. */
    private suspend fun enrichAlbums(grouped: List<AppleMusicLibraryStore.AlbumEntry>): List<AppleMusicLibraryStore.AlbumEntry> {
        if (grouped.isEmpty()) return grouped
        val byKey = HashMap<String, AmLibraryAlbum>()
        var offset = 0
        repeat(maxPages) {
            val r = api.libraryAlbumsPage(offset, pageSize) as? AmResult.Ok ?: return apply(grouped, byKey)
            r.value.items.forEach { byKey.putIfAbsent(albumId(it.title, it.artist), it) }
            offset = r.value.nextOffset ?: return apply(grouped, byKey)
        }
        return apply(grouped, byKey)
    }

    private fun apply(grouped: List<AppleMusicLibraryStore.AlbumEntry>, byId: Map<String, AmLibraryAlbum>) =
        grouped.map { a ->
            val l = byId[a.albumId] ?: return@map a
            a.copy(artworkUrl = a.artworkUrl ?: l.artworkUrl, year = a.year ?: l.year, genre = a.genre ?: l.genre)
        }

    /** The user's library playlists with their tracks; null when any read failed (the caller keeps what it has). */
    private suspend fun playlists(songs: List<AppleMusicLibraryStore.SongEntry>): List<AppleMusicLibraryStore.PlaylistEntry>? {
        val lists = (api.allLibraryPlaylists(pageSize) as? AmResult.Ok)?.value ?: return null
        val out = ArrayList<AppleMusicLibraryStore.PlaylistEntry>(lists.size)
        for (p in lists) {
            val rows = (api.allPlaylistTrackRows(p.id, pageSize) as? AmResult.Ok)?.value ?: return null
            out += AppleMusicLibraryStore.PlaylistEntry(
                id = AppleMusicLibraryStore.PLAYLIST_PREFIX + p.id,
                name = p.name,
                songIds = rows.mapNotNull { it.libraryId?.let { id -> AppleMusicLibraryStore.SONG_PREFIX + id } },
            )
        }
        return out
    }

    private fun <T> AmResult<T>.asFailure(): AmResult<Nothing> = when (this) {
        is AmResult.Ok -> error("not a failure")
        AmResult.NeedsUserToken -> AmResult.NeedsUserToken
        is AmResult.RateLimited -> this
        is AmResult.Failure -> this
    }

    private fun AmResult<*>.asOutcome(): Outcome = when (this) {
        is AmResult.Ok -> error("not a failure")
        AmResult.NeedsUserToken -> Outcome.NeedsUserToken
        is AmResult.RateLimited -> Outcome.RateLimited(retryAfterSec)
        is AmResult.Failure -> Outcome.Failed(status, message)
    }

    companion object {
        /** Deterministic album id from the grouping key - FNV-1a 64, hex; byte-identical to iOS. */
        fun albumId(title: String, artist: String): String {
            val key = "${title.lowercase()}|${artist.lowercase()}"
            var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
            for (b in key.toByteArray(Charsets.UTF_8)) {
                hash = hash xor (b.toLong() and 0xff)
                hash *= 0x100000001b3L
            }
            return "amlib_alb_" + java.lang.Long.toHexString(hash).padStart(16, '0')
        }

        /** Group songs into albums (insertion order; in-album tracks by trackNumber, unknown last). */
        fun groupAlbums(songs: List<AppleMusicLibraryStore.SongEntry>): List<AppleMusicLibraryStore.AlbumEntry> {
            data class Acc(var e: AppleMusicLibraryStore.AlbumEntry)
            val byId = LinkedHashMap<String, Acc>()
            for (s in songs) {
                val title = s.album?.takeIf { it.isNotEmpty() } ?: continue
                val id = s.albumId ?: continue
                val acc = byId[id]
                if (acc == null) {
                    byId[id] = Acc(AppleMusicLibraryStore.AlbumEntry(id, title, s.artist, s.artworkUrl, s.year, s.genre, listOf(s.songId)))
                } else {
                    acc.e = acc.e.copy(
                        trackIds = acc.e.trackIds + s.songId,
                        artworkUrl = acc.e.artworkUrl ?: s.artworkUrl,
                        year = acc.e.year ?: s.year,
                    )
                }
            }
            val trackNo = songs.associate { it.songId to (it.trackNumber ?: Int.MAX_VALUE) }
            return byId.values.map { it.e.copy(trackIds = it.e.trackIds.sortedBy { id -> trackNo[id] ?: Int.MAX_VALUE }) }
        }
    }
}

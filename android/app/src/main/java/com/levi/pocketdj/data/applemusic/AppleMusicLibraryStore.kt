package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.PdjJson
import java.io.File
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Encodes a whole-number Double the way Swift's `JSONEncoder` does (`1700000000000`, not `1.7E12`), so an
 * iOS-written document round-trips through Android byte-stable per field. Decodes any JSON number.
 */
object EpochMsSerializer : KSerializer<Double> {
    override val descriptor = PrimitiveSerialDescriptor("EpochMs", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Double) {
        if (value.isFinite() && value == Math.rint(value) && Math.abs(value) < 9.0e15) encoder.encodeLong(value.toLong())
        else encoder.encodeDouble(value)
    }
    override fun deserialize(decoder: Decoder): Double = decoder.decodeDouble()
}

/**
 * The user's OWN Apple Music library as a catalog source (iOS `AppleMusicLibraryStore`, P2-LIB-2): the doc
 * `pocketdj-apple-music-library.json` has the SAME shape iOS writes (`schemaVersion`, `songs`, optional
 * `albums`/`playlists`/`lastAddedMs`/`supersededAddedAt`), so P2-LIB-3 can sync it whole-document LWW.
 *
 * HARD RULE (the DiscoverAddsStore decode lesson): `albums`/`playlists` are optional - a document missing
 * either key keeps what it has and never wipes the other half; an unreadable file decodes to an empty doc.
 * The catalog fold ([IndexJson] synthesis, supersede split) belongs to P2-LIB-3; this class holds the rows.
 */
class AppleMusicLibraryStore(private val file: File) {

    @Serializable
    data class SongEntry(
        /** `amlib_<libraryId>` - namespaced so it can never collide with catalog `sng_` ids. */
        val songId: String = "",
        /** Library id (`i.…`): the incremental-index join key on this device. */
        val libraryId: String = "",
        /** Apple Music catalog store id - the streaming + supersede key; null for unmatched library items. */
        val appleMusicId: String? = null,
        val title: String = "",
        val artist: String = "",
        val album: String? = null,
        val albumId: String? = null,
        val artworkUrl: String? = null,
        val durationMs: Int? = null,
        val trackNumber: Int? = null,
        val year: Int? = null,
        val genre: String? = null,
        /** Library add time (epoch ms) - powers "Recently added". */
        @Serializable(with = EpochMsSerializer::class) val addedAtMs: Double = 0.0,
    )

    @Serializable
    data class AlbumEntry(
        val albumId: String = "",
        val title: String = "",
        val artist: String = "",
        val artworkUrl: String? = null,
        val year: Int? = null,
        val genre: String? = null,
        val trackIds: List<String> = emptyList(),
    )

    @Serializable
    data class PlaylistEntry(
        /** `amlibpl_<libraryPlaylistId>`. */
        val id: String = "",
        val name: String = "",
        val songIds: List<String> = emptyList(),
    )

    @Serializable
    internal data class Document(
        val schemaVersion: Int = 1,
        val songs: List<SongEntry> = emptyList(),
        val albums: List<AlbumEntry>? = null,
        val playlists: List<PlaylistEntry>? = null,
        /** High-water mark: the max `addedAtMs` the indexer has seen. */
        @Serializable(with = EpochMsSerializer::class) val lastAddedMs: Double? = null,
        /** The user's own add-time for a song that SUPERSEDED onto an indexed twin, keyed by the surviving id. */
        val supersededAddedAt: Map<String, @Serializable(with = EpochMsSerializer::class) Double>? = null,
    )

    private val lock = Any()
    @Volatile private var doc: Document = decode(file)

    /** Fired (outside the lock) when the content changed shape: the live catalog must be rebuilt. */
    @Volatile var onChanged: (() -> Unit)? = null

    val songs: List<SongEntry> get() = doc.songs
    val albums: List<AlbumEntry> get() = doc.albums.orEmpty()
    val playlists: List<PlaylistEntry> get() = doc.playlists.orEmpty()
    val lastAddedMs: Double? get() = doc.lastAddedMs
    val supersededAddedAt: Map<String, Double> get() = doc.supersededAddedAt.orEmpty()
    val isEmpty: Boolean get() = doc.songs.isEmpty() && doc.playlists.isNullOrEmpty()

    /** The document the profile sync (P2-LIB-3) unions. */
    val syncFile: File get() = file

    /** A FULL index run replaces the source wholesale (the library is the truth). */
    fun replaceAll(
        songs: List<SongEntry>,
        albums: List<AlbumEntry>,
        playlists: List<PlaylistEntry>,
        lastAddedMs: Double?,
    ) {
        synchronized(lock) {
            // supersededAddedAt describes surviving INDEXED twins, not our rows - it outlives a re-index.
            doc = Document(songs = songs, albums = albums.ifEmpty { null }, playlists = playlists.ifEmpty { null },
                lastAddedMs = lastAddedMs, supersededAddedAt = doc.supersededAddedAt)
            save()
        }
        onChanged?.invoke()
    }

    /**
     * An INCREMENTAL run: append new songs (idempotent by songId), union album track lists, replace the
     * playlists wholesale when [playlists] is non-null (they are cheap and can reorder; null = keep), and
     * advance - never lower - the high-water mark. Returns whether the content changed.
     */
    fun applyIncremental(
        songs: List<SongEntry>,
        albums: List<AlbumEntry>,
        playlists: List<PlaylistEntry>?,
        lastAddedMs: Double?,
    ): Boolean {
        val changed: Boolean
        synchronized(lock) {
            val cur = doc
            val have = cur.songs.mapTo(HashSet()) { it.songId }
            val fresh = songs.filter { have.add(it.songId) }
            var didChange = fresh.isNotEmpty()

            val merged = LinkedHashMap<String, AlbumEntry>()
            cur.albums.orEmpty().forEach { merged[it.albumId] = it }
            for (a in albums) {
                val existing = merged[a.albumId]
                if (existing == null) {
                    merged[a.albumId] = a; didChange = true
                } else {
                    val seen = existing.trackIds.toHashSet()
                    val extra = a.trackIds.filter { it !in seen }
                    if (extra.isNotEmpty()) { merged[a.albumId] = existing.copy(trackIds = existing.trackIds + extra); didChange = true }
                }
            }
            val newPlaylists = if (playlists == null) cur.playlists else playlists.ifEmpty { null }
            if (newPlaylists != cur.playlists) didChange = true
            val mark = listOfNotNull(cur.lastAddedMs, lastAddedMs).maxOrNull()
            doc = cur.copy(songs = cur.songs + fresh, albums = merged.values.toList().ifEmpty { null },
                playlists = newPlaylists, lastAddedMs = mark)
            save()
            changed = didChange
        }
        if (changed) onChanged?.invoke()
        return changed
    }

    /**
     * Drop superseded rows (an indexed twin owns the id now), CARRYING each dropped row's add-time forward
     * keyed by the surviving twin so Recently-added still ranks the user's own library add.
     */
    fun supersede(pairs: List<Pair<String, String>>) {
        if (pairs.isEmpty()) return
        synchronized(lock) {
            val cur = doc
            val addedById = HashMap<String, Double>()
            cur.songs.forEach { s -> addedById.merge(s.songId, s.addedAtMs, ::maxOf) }
            val carried = LinkedHashMap(cur.supersededAddedAt.orEmpty())
            for ((from, to) in pairs) {
                val ms = addedById[from] ?: continue
                if (ms > (carried[to] ?: 0.0)) carried[to] = ms
            }
            val gone = pairs.mapTo(HashSet()) { it.first }
            val newAlbums = cur.albums.orEmpty()
                .map { a -> a.copy(trackIds = a.trackIds.filter { it !in gone }) }
                .filter { it.trackIds.isNotEmpty() }
            doc = cur.copy(songs = cur.songs.filter { it.songId !in gone }, albums = newAlbums.ifEmpty { null },
                supersededAddedAt = carried.ifEmpty { null })
            save()
        }
    }

    /** Empty the source: reset state and delete the persisted file. */
    fun clear() {
        synchronized(lock) {
            doc = Document()
            runCatching { file.delete() }
        }
        onChanged?.invoke()
    }

    /**
     * Re-decode after a sync pull wrote a newer copy (whole-document LWW: the peer's index replaces ours).
     * Returns whether the visible content changed (callers treat true as "rebuild the catalog").
     */
    fun reloadFromDisk(): Boolean {
        val changed: Boolean
        synchronized(lock) {
            val next = decode(file)
            changed = next != doc
            doc = next
        }
        if (changed) onChanged?.invoke()
        return changed
    }

    private fun save() {
        val text = PdjJson.lenient.encodeToString(doc)
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) { file.writeText(text); tmp.delete() }
        }
    }

    /** The serialized document (tests / sync diagnostics). */
    internal fun encoded(): String = PdjJson.lenient.encodeToString(doc)

    companion object {
        const val FILE_NAME = "pocketdj-apple-music-library.json"
        const val SOURCE_NAME = "Apple Music"
        const val SONG_PREFIX = "amlib_"
        const val PLAYLIST_PREFIX = "amlibpl_"

        private fun decode(file: File): Document =
            runCatching { PdjJson.lenient.decodeFromString<Document>(file.readText()) }.getOrDefault(Document())
    }
}

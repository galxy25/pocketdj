package com.levi.pocketdj.data.profile

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexSong
import java.io.File
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

/**
 * The per-profile "Pocket DJ" DATA SOURCE (iOS `ProfileSourceStore`): the user's own on-device custom audio
 * (Sampler samples + Demuxer results) as first-class catalog citizens - browsable, addable, cue-able, mixable and
 * playable in Now Playing exactly like a catalog song.
 *
 * The source DISPLAY name is the user's PROFILE name (the catalog tags `Manifest.sourceName`); each item's ARTIST is
 * the profile name too, DERIVED at synthesis time and never stored, so a rename updates every row for free. Each entry's
 * [Kind] files it into one of two DEFAULT albums ("Pocket DJ Samples" / "Pocket DJ Demuxes") that are synthesized (never
 * persisted) so they always exist as filing destinations.
 *
 * Persists to `pocketdj-profile-source.json` in the iOS document shape. NO cloud sync on Android (micro-decision): the
 * audio is device-local and the metadata is not mirrored. The decode is lenient (missing/corrupt doc => empty store).
 */
class ProfileSourceStore(
    private val file: File,
    /** Root of the app-managed audio (`profile-audio/`): originals + `stems/<songId>/`. Purged by [clear]. */
    val audioDir: File,
) {
    @Serializable
    enum class Kind(val albumId: String, val albumName: String) {
        @SerialName("sample") SAMPLE(SAMPLES_ALBUM_ID, SAMPLES_ALBUM_NAME),
        @SerialName("demux") DEMUX(DEMUXES_ALBUM_ID, DEMUXES_ALBUM_NAME),
    }

    /** METADATA only; the audio lives under [audioDir] as [fileName]. Field names are the iOS Codable keys. */
    @Serializable
    data class SongEntry(
        val songId: String,
        val title: String = "",
        val kind: Kind = Kind.DEMUX,
        val fileName: String = "",
        val durationMs: Long? = null,
        val bpm: Double? = null,
        val key: String? = null,
        val camelot: String? = null,
        val addedAtMs: Double = 0.0,
    )

    @Serializable
    internal data class Document(
        val schemaVersion: Int = 1,
        val songs: List<SongEntry> = emptyList(),
    )

    private val lock = Any()
    private var songs: List<SongEntry> = decode(file).songs.distinctBy { it.songId }

    /** Profile display name (source + artist). Blank => [DEFAULT_NAME]. */
    @Volatile private var profileNameRaw: String = DEFAULT_NAME
    private var cachedDoc: IndexJson? = null

    /** Fired (outside the lock) after the catalog-visible state changed (add/remove/clear/rename): remerge the catalog. */
    @Volatile var onChanged: (() -> Unit)? = null

    val sourceName: String get() = profileNameRaw.trim().ifEmpty { DEFAULT_NAME }

    /** Mirror the profile name in; a real change re-tags on the next catalog merge. */
    fun setProfileName(name: String) {
        val changed = synchronized(lock) {
            val next = name.trim().ifEmpty { DEFAULT_NAME }
            if (next == sourceName) { profileNameRaw = name; false } else { profileNameRaw = name; cachedDoc = null; true }
        }
        if (changed) onChanged?.invoke()
    }

    /** iOS withProvisionalSources: the profile source joins the merge only once the user has >=1 item. */
    fun syntheticDocumentsIfAny(): List<IndexJson> = if (songs().isEmpty()) emptyList() else listOf(syntheticDocument())

    fun songs(): List<SongEntry> = synchronized(lock) { songs }
    fun entry(id: String): SongEntry? = synchronized(lock) { songs.firstOrNull { it.songId == id } }

    /** Idempotent per id. Returns the NEW rows. */
    fun add(newSongs: List<SongEntry>): List<SongEntry> {
        val fresh: List<SongEntry>
        synchronized(lock) {
            val known = songs.mapTo(HashSet()) { it.songId }
            fresh = newSongs.distinctBy { it.songId }.filter { known.add(it.songId) }
            if (fresh.isEmpty()) return emptyList()
            songs = songs + fresh
            cachedDoc = null
            save()
        }
        onChanged?.invoke()
        return fresh
    }

    fun remove(songIds: Collection<String>) {
        if (songIds.isEmpty()) return
        synchronized(lock) {
            val gone = songIds.toSet()
            val next = songs.filterNot { it.songId in gone }
            if (next.size == songs.size) return
            songs = next; cachedDoc = null; save()
        }
        onChanged?.invoke()
    }

    /** Wipe every entry, the document AND the app-managed audio (originals + stems): this store owns durable media. */
    fun clear() {
        synchronized(lock) {
            songs = emptyList(); cachedDoc = null
            runCatching { file.delete() }
            runCatching { audioDir.deleteRecursively() }
        }
        onChanged?.invoke()
    }

    /** The synthetic SOURCE for the catalog merge (always both default albums). Stable instance between changes. */
    fun syntheticDocument(): IndexJson = synchronized(lock) {
        cachedDoc ?: syntheticIndex(songs, sourceName).also { cachedDoc = it }
    }

    private fun save() {
        runCatching {
            val bytes = PdjJson.lenient.encodeToString(Document(songs = songs)).toByteArray()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) { file.writeBytes(bytes); tmp.delete() }
        }
    }

    companion object {
        const val FILE_NAME = "pocketdj-profile-source.json"
        const val DEFAULT_NAME = "Pocket DJ"
        const val SAMPLES_ALBUM_ID = "pdjalb_samples"
        const val DEMUXES_ALBUM_ID = "pdjalb_demuxes"
        const val SAMPLES_ALBUM_NAME = "Pocket DJ Samples"
        const val DEMUXES_ALBUM_NAME = "Pocket DJ Demuxes"
        /** Fresh `pdj_<uuid>` per item; the trailing underscore keeps `pdjalb_` album ids from matching. */
        const val SONG_ID_PREFIX = "pdj_"

        fun isProfileSongId(id: String) = id.startsWith(SONG_ID_PREFIX)

        internal fun decode(file: File): Document =
            runCatching { PdjJson.lenient.decodeFromString(Document.serializer(), file.readText()) }
                .getOrDefault(Document())

        /** Entry -> catalog row; artist + albumId DERIVED (profile name / kind). */
        fun indexSong(e: SongEntry, profileName: String) = IndexSong(
            id = e.songId, albumId = e.kind.albumId, artist = profileName, name = e.title,
            bpm = e.bpm, key = e.key, camelot = e.camelot, length = e.durationMs,
        )

        fun indexAlbum(kind: Kind, trackIds: List<String>, profileName: String) = IndexAlbum(
            id = kind.albumId, artist = profileName, name = kind.albumName, trackList = trackIds,
        )

        fun defaultAlbums(songs: List<SongEntry>, profileName: String): List<IndexAlbum> =
            Kind.entries.map { k -> indexAlbum(k, songs.filter { it.kind == k }.map { it.songId }, profileName) }

        fun syntheticIndex(songs: List<SongEntry>, profileName: String) = IndexJson(
            manifest = IndexManifest(source = "profile-source", sourceName = profileName),
            albums = defaultAlbums(songs, profileName),
            songs = songs.map { indexSong(it, profileName) },
        )
    }
}

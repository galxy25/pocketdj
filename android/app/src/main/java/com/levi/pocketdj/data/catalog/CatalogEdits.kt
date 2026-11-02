package com.levi.pocketdj.data.catalog

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement

/*
 * Catalog edits overlay (Q115, COL-14) - the Android port of iOS `EditSchema.swift` (`AlbumEdit` / `SongEdit` /
 * `AudioTrackEdit` + `IndexAlbum.applying` / `IndexSong.applying`) and of `AppModel.buildEffective`, which overlays
 * `EditsStore`'s document onto the merged catalog. Android has no edit UI; its edits arrive by backup restore
 * (`edits.json` inside the `.pocketdj.zip`, kept in [CatalogEditsFile]) and are now applied, not only stored.
 *
 * Contract (iOS schema rules): every field is OPTIONAL and an absent/null field means "no override"; unknown keys
 * are ignored (a newer app's document degrades instead of failing); edits are keyed by the stable catalog ids.
 */

/** iOS `AudioTrackEdit`: one detected audio segment's overrides; [trackNumber] is the MATCH key, not an override. */
@Serializable
data class AudioTrackEdit(
    val trackNumber: Int? = null,
    val startMs: Long? = null,
    val endMs: Long? = null,
    val bpm: Double? = null,
    val key: String? = null,
    val camelot: String? = null,
    val keyStrength: Double? = null,
) {
    val isEmpty: Boolean
        get() = startMs == null && endMs == null && bpm == null && key == null && camelot == null && keyStrength == null
}

/** iOS `AlbumEdit`. */
@Serializable
data class AlbumEdit(
    val name: String? = null,
    val artist: String? = null,
    val genre: String? = null,
    val year: Int? = null,
    val country: String? = null,
    val audioTracks: List<AudioTrackEdit>? = null,
) {
    val isEmpty: Boolean
        get() = name == null && artist == null && genre == null && year == null && country == null &&
            (audioTracks?.all { it.isEmpty } ?: true)
}

/** iOS `SongEdit`. */
@Serializable
data class SongEdit(
    val name: String? = null,
    val artist: String? = null,
    val year: Int? = null,
    val trackNumber: Int? = null,
    val bpm: Double? = null,
    val key: String? = null,
    val camelot: String? = null,
    val explicit: Boolean? = null,
    val sentimentKeywords: List<String>? = null,
) {
    val isEmpty: Boolean
        get() = name == null && artist == null && year == null && trackNumber == null && bpm == null &&
            key == null && camelot == null && explicit == null && sentimentKeywords == null
}

/** The decoded overlay: albumId -> edit, songId -> edit. Immutable; identity changes only when the file does. */
class CatalogEdits(
    val albums: Map<String, AlbumEdit>,
    val songs: Map<String, SongEdit>,
) {
    val isEmpty: Boolean get() = albums.isEmpty() && songs.isEmpty()

    /**
     * The catalog with every edit applied (iOS `buildEffective`): albums re-sorted in browse order (an edit may
     * rename the artist/title), songs in merge order, the by-id maps rebuilt in their original order. Ids,
     * playlists and source tags are never touched. No edits => the SAME instance (no rebuild).
     */
    fun apply(catalog: MergedCatalog): MergedCatalog {
        if (isEmpty) return catalog
        val touchesAlbum = albums.keys.any { it in catalog.albumsById }
        val touchesSong = songs.keys.any { it in catalog.songsById }
        if (!touchesAlbum && !touchesSong) return catalog
        val albumsById = if (touchesAlbum) {
            catalog.albumsById.mapValuesTo(LinkedHashMap(catalog.albumsById.size)) { (id, a) -> a.applying(albums[id]) }
        } else catalog.albumsById
        val songsById = if (touchesSong) {
            catalog.songsById.mapValuesTo(LinkedHashMap(catalog.songsById.size)) { (id, s) -> s.applying(songs[id]) }
        } else catalog.songsById
        return catalog.copy(
            albums = if (touchesAlbum) albumsById.values.sortedWith(MergedCatalog.BROWSE_ORDER) else catalog.albums,
            // Keep the merge-order list (and its duplicates, if any) - only swap in the edited rows.
            songs = if (touchesSong) catalog.songs.map { songsById[it.id] ?: it } else catalog.songs,
            albumsById = albumsById,
            songsById = songsById,
        )
    }

    companion object {
        val EMPTY = CatalogEdits(emptyMap(), emptyMap())

        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        /**
         * Lenient decode of an iOS `EditsDocument` (`{schemaVersion, albums:{}, songs:{}, meta?}`): junk / absent
         * => [EMPTY]. Per ENTRY: a malformed edit is skipped (iOS would drop the whole map - Android keeps the rest),
         * and an edit that overrides nothing is dropped. Every schema version so far is additive, so no migration step.
         */
        fun decode(data: ByteArray?): CatalogEdits {
            if (data == null || data.isEmpty()) return EMPTY
            val root = runCatching { json.parseToJsonElement(String(data, Charsets.UTF_8)) }.getOrNull() as? JsonObject
                ?: return EMPTY
            fun <T> section(key: String, decodeOne: (kotlinx.serialization.json.JsonElement) -> T?): Map<String, T> {
                val o = root[key] as? JsonObject ?: return emptyMap()
                val out = LinkedHashMap<String, T>(o.size)
                for ((id, v) in o) decodeOne(v)?.let { out[id] = it }
                return out
            }
            val albums = section("albums") { el ->
                runCatching { json.decodeFromJsonElement<AlbumEdit>(el) }.getOrNull()?.takeUnless { it.isEmpty }
            }
            val songs = section("songs") { el ->
                runCatching { json.decodeFromJsonElement<SongEdit>(el) }.getOrNull()?.takeUnless { it.isEmpty }
            }
            return if (albums.isEmpty() && songs.isEmpty()) EMPTY else CatalogEdits(albums, songs)
        }
    }
}

/** iOS `IndexAlbum.applying(_:)`: set fields override, unset fields keep the index value. */
fun IndexAlbum.applying(e: AlbumEdit?): IndexAlbum {
    if (e == null) return this
    return copy(
        artist = e.artist ?: artist,
        name = e.name ?: name,
        genre = e.genre ?: genre,
        year = e.year ?: year,
        country = e.country ?: country,
        audioTracks = overlayAudio(audioTracks, e.audioTracks),
    )
}

/**
 * iOS `overlayAudio`: a `trackNumber`-keyed edit matches the segment with that number; an edit WITHOUT one matches
 * by array position. A numbered edit never leaks into a positional match. Unmatched segments pass through.
 */
internal fun overlayAudio(segs: List<AudioTrack>?, edits: List<AudioTrackEdit>?): List<AudioTrack>? {
    if (segs == null || edits.isNullOrEmpty()) return segs
    val byTrack = LinkedHashMap<Int, AudioTrackEdit>()
    for (e in edits) e.trackNumber?.let { byTrack.putIfAbsent(it, e) }
    return segs.mapIndexed { i, seg ->
        val positional = edits.getOrNull(i)?.takeIf { it.trackNumber == null }
        val m = seg.trackNumber?.let { byTrack[it] } ?: positional
        if (m == null || m.isEmpty) {
            seg
        } else {
            seg.copy(
                trackNumber = m.trackNumber ?: seg.trackNumber,
                startMs = m.startMs ?: seg.startMs,
                endMs = m.endMs ?: seg.endMs,
                bpm = m.bpm ?: seg.bpm,
                key = m.key ?: seg.key,
                camelot = m.camelot ?: seg.camelot,
                keyStrength = m.keyStrength ?: seg.keyStrength,
            )
        }
    }
}

/** iOS `IndexSong.applying(_:)`. */
fun IndexSong.applying(e: SongEdit?): IndexSong {
    if (e == null) return this
    return copy(
        artist = e.artist ?: artist,
        name = e.name ?: name,
        trackNumber = e.trackNumber ?: trackNumber,
        year = e.year ?: year,
        sentimentKeywords = e.sentimentKeywords ?: sentimentKeywords,
        explicit = e.explicit ?: explicit,
        bpm = e.bpm ?: bpm,
        key = e.key ?: key,
        camelot = e.camelot ?: camelot,
    )
}

/**
 * The on-device edits document (`filesDir/backup-edits.json`, written by the backup restore's
 * [com.levi.pocketdj.data.backup.BackupEditsStore]) decoded for the overlay. Cached by (mtime, size) so every catalog
 * merge reuses ONE [CatalogEdits] instance until the file changes (the repository compares by identity).
 */
class CatalogEditsFile(val file: java.io.File) {
    private data class Stamp(val modified: Long, val length: Long)

    @Volatile private var cached: Pair<Stamp, CatalogEdits>? = null

    @Synchronized fun current(): CatalogEdits {
        val stamp = runCatching { if (file.exists()) Stamp(file.lastModified(), file.length()) else null }.getOrNull()
            ?: return CatalogEdits.EMPTY.also { cached = null }
        cached?.let { (s, e) -> if (s == stamp) return e }
        val edits = CatalogEdits.decode(runCatching { file.readBytes() }.getOrNull())
        cached = stamp to edits
        return edits
    }

    /** Drop the cache (after a write whose mtime may not have ticked, e.g. two restores within one second). */
    @Synchronized fun invalidate() {
        cached = null
    }

    companion object {
        const val FILE_NAME = "backup-edits.json"
    }
}

package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.catalog.AlbumEdit
import com.levi.pocketdj.data.catalog.IndexAlbum

/**
 * The catalog's layout of every vinyl side, keyed by song id (iOS `SegmentOverrides`): the user's boundary edits
 * (where a song STARTS / ENDS inside its side, exact), the indexer's detected song ends, and album membership.
 * Derived from the edits document + the effective albums on every catalog publish / `reapplyEdits`, and owned by
 * `CatalogRepository` as a StateFlow so the playback layer reads it without any UI.
 */
object SegmentOverrides {
    data class Snapshot(
        /** User-edited starts / ends (exact). */
        val startMs: Map<String, Long> = emptyMap(),
        val endMs: Map<String, Long> = emptyMap(),
        /** The indexer's detected song ends (edits applied), for albums whose segments pair 1:1 with their track list. */
        val detectedEndMs: Map<String, Long> = emptyMap(),
        val albumOfSong: Map<String, String> = emptyMap(),
        val albumTracks: Map<String, Set<String>> = emptyMap(),
    ) {
        companion object { val EMPTY = Snapshot() }
    }

    /**
     * Pure: the layout an edits document + the effective (edit-overlaid) albums imply. Each album edit's segment
     * deltas are matched onto the RAW album's detected segments like the display overlay (`trackNumber` first, else
     * array position, and only when the delta has no `trackNumber`); segment `i` belongs to the album's `i`-th song in
     * track order. An album whose segment count doesn't match its song count is skipped (the pairing would be a guess).
     */
    fun derive(
        albumEdits: Map<String, AlbumEdit>,
        rawAlbum: (String) -> IndexAlbum?,
        orderedSongIds: (String) -> List<String>,
        effectiveAlbums: List<IndexAlbum> = emptyList(),
    ): Snapshot {
        val albumTracks = HashMap<String, Set<String>>()
        val albumOfSong = HashMap<String, String>()
        val detected = HashMap<String, Long>()
        for (album in effectiveAlbums) {
            val segs = album.audioTracks
            if (segs.isNullOrEmpty() || segs.size != album.trackList.size) continue
            albumTracks[album.id] = album.trackList.toSet()
            album.trackList.forEachIndexed { i, id ->
                albumOfSong[id] = album.id
                segs[i].endMs?.let { detected[id] = it }
            }
        }
        val starts = HashMap<String, Long>()
        val ends = HashMap<String, Long>()
        for ((albumId, edit) in albumEdits) {
            val deltas = edit.audioTracks
            if (deltas.isNullOrEmpty()) continue
            val segs = rawAlbum(albumId)?.audioTracks
            if (segs.isNullOrEmpty()) continue
            val songs = orderedSongIds(albumId)
            if (songs.size != segs.size) continue
            segs.forEachIndexed { i, seg ->
                val byNumber = seg.trackNumber?.let { n -> deltas.firstOrNull { it.trackNumber == n } }
                val positional = deltas.getOrNull(i)?.takeIf { it.trackNumber == null }
                val d = byNumber ?: positional ?: return@forEachIndexed
                d.startMs?.let { starts[songs[i]] = it }
                d.endMs?.let { ends[songs[i]] = it }
            }
        }
        return Snapshot(starts, ends, detected, albumOfSong, albumTracks)
    }
}

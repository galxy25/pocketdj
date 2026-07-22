package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.browse.Fmt

/**
 * Pure count + runtime helpers for containers — "how many songs, and how long,
 * is this container?" for a Playlist, a single chapter, or a Pocket. Port of
 * iOS `Models/CollectionCatalog.swift` minus the Studio seam (specs/playlists-ui.md §10).
 *
 * Definition of "songs in a container" (the FULL static membership — realize's
 * expansion minus budget sampling / autofill):
 *   song node → the song · album node → trackList expanded · pocket node →
 *   [resolvePocketSongs] (cycle-guarded, deduped) · text → nothing ·
 *   sub-sequence → recurse. The `seen` pocket set spans the WHOLE container so
 *   a pocket referenced twice counts once.
 *
 * Runtime = Σ `song.length` (ms); missing/zero lengths count 0 (a floor — never
 * the engine's 210 s realize fallback).
 */
class CollectionCatalog(
    private val songsById: Map<String, IndexSong>,
    private val albumsById: Map<String, IndexAlbum>,
    private val pocketsById: Map<String, Pocket>,
) {
    data class Stats(val count: Int = 0, val runtimeMs: Long = 0) {
        /** "12 songs · 47:31" — the standard container subtitle. */
        val summary: String
            get() = "$count song${if (count == 1) "" else "s"} · ${Fmt.duration(runtimeMs)}"
    }

    private fun runtimeOf(songs: List<IndexSong>): Long =
        songs.sumOf { song -> song.length?.takeIf { it > 0 } ?: 0L }

    private fun statsOf(songs: List<IndexSong>): Stats = Stats(songs.size, runtimeOf(songs))

    // MARK: Resolution

    private fun songsForNode(node: PlaylistNode, seenPockets: MutableSet<String>): List<IndexSong> =
        when (node.kind) {
            PlaylistNode.Kind.SONG -> node.songId?.let { songsById[it] }?.let(::listOf) ?: emptyList()
            PlaylistNode.Kind.ALBUM -> {
                val album = node.albumId?.let { albumsById[it] }
                album?.trackList?.mapNotNull { songsById[it] } ?: emptyList()
            }
            PlaylistNode.Kind.POCKET ->
                node.pocketId?.let { resolvePocketSongs(it, seenPockets) } ?: emptyList()
            PlaylistNode.Kind.TEXT -> emptyList()
            PlaylistNode.Kind.SEQUENCE ->
                node.children.orEmpty().flatMap { songsForNode(it, seenPockets) }
        }

    /** Songs contributed by a chapter's children (albums/pockets expanded). */
    fun songsInChapter(chapter: PlaylistNode): List<IndexSong> {
        val seen = HashSet<String>()
        return chapter.children.orEmpty().flatMap { songsForNode(it, seen) }
    }

    /** All songs contributed by a playlist (every chapter; pockets count once per playlist). */
    fun songsInPlaylist(playlist: Playlist): List<IndexSong> {
        val seen = HashSet<String>()
        return playlist.sequences.flatMap { seq ->
            seq.children.orEmpty().flatMap { songsForNode(it, seen) }
        }
    }

    /**
     * A pocket's effective ordered songs — own songIds, then album tracks, then
     * nested child pockets — CYCLE-GUARDED and DEDUPED by songId.
     */
    fun resolvePocketSongs(pocketId: String, seen: MutableSet<String>): List<IndexSong> {
        val out = ArrayList<IndexSong>()
        val added = HashSet<String>()
        collectPocket(pocketId, seen, out, added)
        return out
    }

    private fun collectPocket(
        pocketId: String,
        seen: MutableSet<String>,
        out: MutableList<IndexSong>,
        added: MutableSet<String>,
    ) {
        if (!seen.add(pocketId)) return // cycle / revisit guard
        val pocket = pocketsById[pocketId] ?: return
        for (songId in pocket.songIds) push(songsById[songId], out, added)
        for (albumId in pocket.albumIds) {
            val album = albumsById[albumId] ?: continue
            for (trackId in album.trackList) push(songsById[trackId], out, added)
        }
        for (childId in pocket.childPocketIds) collectPocket(childId, seen, out, added)
    }

    private fun push(song: IndexSong?, out: MutableList<IndexSong>, added: MutableSet<String>) {
        if (song == null || !added.add(song.id)) return
        out.add(song)
    }

    // MARK: Public stats

    fun statsForPlaylist(playlist: Playlist): Stats = statsOf(songsInPlaylist(playlist))

    fun statsForChapter(chapter: PlaylistNode): Stats = statsOf(songsInChapter(chapter))

    fun statsForPocket(pocketId: String): Stats {
        val seen = HashSet<String>()
        return statsOf(resolvePocketSongs(pocketId, seen))
    }
}

package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.playback.sequencer.QueueItem

/**
 * Tokenized add-search for the Now Playing panel (iOS `NowPlayingSearch`). Every whitespace token must
 * hit the name+artist haystack; matches rank exact-name > name-prefix > substring, ties in catalog
 * order, capped per section. Pure: the panel runs it off-main over catalog snapshots.
 */
object NowPlayingSearch {
    const val SONG_CAP = 25
    const val ALBUM_CAP = 10

    data class Results(val albums: List<IndexAlbum> = emptyList(), val songs: List<IndexSong> = emptyList()) {
        val isEmpty: Boolean get() = albums.isEmpty() && songs.isEmpty()
    }

    fun songs(query: String, songs: List<IndexSong>): List<IndexSong> =
        rank(query, songs, { it.name }, { it.artist }, SONG_CAP)

    fun albums(query: String, albums: List<IndexAlbum>): List<IndexAlbum> =
        rank(query, albums, { it.name }, { it.artist }, ALBUM_CAP)

    fun search(query: String, catalog: MergedCatalog): Results =
        Results(albums = albums(query, catalog.albums), songs = songs(query, catalog.songs))

    fun <T> rank(
        query: String,
        items: List<T>,
        name: (T) -> String,
        artist: (T) -> String,
        cap: Int,
    ): List<T> {
        val normalized = query.trim().lowercase()
        val tokens = normalized.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return emptyList()
        data class Scored<T>(val item: T, val score: Int, val order: Int)
        val scored = ArrayList<Scored<T>>()
        items.forEachIndexed { i, item ->
            val n = name(item).lowercase()
            val hay = "$n ${artist(item).lowercase()}"
            if (tokens.all { hay.contains(it) }) {
                val score = if (n == normalized) 2 else if (n.startsWith(normalized)) 1 else 0
                scored += Scored(item, score, i)
            }
        }
        return scored
            .sortedWith(compareByDescending<Scored<T>> { it.score }.thenBy { it.order })
            .take(cap)
            .map { it.item }
    }

    /** A queue row for a catalog song (fresh uid each call). */
    fun queueItem(song: IndexSong): QueueItem =
        QueueItem(id = song.id, title = song.name, artist = song.artist, lengthMs = song.length)

    /** The album's WHOLE tracklist in album order (fresh uids). */
    fun queueItems(album: IndexAlbum, catalog: MergedCatalog): List<QueueItem> =
        catalog.tracks(album).map(::queueItem)

    /** Debounce window before the (off-main) search runs. */
    const val DEBOUNCE_MS = 200L
}

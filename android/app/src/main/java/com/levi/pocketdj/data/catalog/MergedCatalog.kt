package com.levi.pocketdj.data.catalog

/** A source playlist tagged with the name of the source it came from. */
data class SourcePlaylist(
    val playlist: IndexPlaylist,
    val sourceName: String,
)

/**
 * The immutable, fully-derived catalog snapshot the UI renders — built once per
 * load off the main thread and swapped in as a single value so a half-built
 * catalog is never visible (specs/catalog.md §5, §7).
 */
data class MergedCatalog(
    /** Deduped albums, sorted artist → name case-insensitively (browse order). */
    val albums: List<IndexAlbum>,
    /** Deduped songs in catalog (merge) order. */
    val songs: List<IndexSong>,
    /** Source playlists, flattened + source-tagged, deduped by playlist id. */
    val playlists: List<SourcePlaylist>,
    val albumsById: Map<String, IndexAlbum>,
    val songsById: Map<String, IndexSong>,
    /** albumId → source name of the FIRST source carrying it (merge order). */
    val sourceOfAlbum: Map<String, String>,
    /** songId → source name of the FIRST source carrying it (merge order). */
    val sourceOfSong: Map<String, String>,
    /** Distinct source names in first-seen order — drives the sources rail. */
    val availableSources: List<String>,
) {
    /**
     * An album's tracks: order comes from `trackList`, ids missing from the
     * catalog are silently dropped (browse.md §8). Repeated ids are dropped too
     * (first occurrence wins) — consumers key LazyColumn rows by song id, and a
     * malformed-but-decodable document must never crash a screen.
     */
    fun tracks(album: IndexAlbum): List<IndexSong> =
        album.trackList.distinct().mapNotNull { songsById[it] }

    companion object {
        val EMPTY = MergedCatalog(
            albums = emptyList(),
            songs = emptyList(),
            playlists = emptyList(),
            albumsById = emptyMap(),
            songsById = emptyMap(),
            sourceOfAlbum = emptyMap(),
            sourceOfSong = emptyMap(),
            availableSources = emptyList(),
        )

        /**
         * Merge per-source documents in source-list order: concatenate with
         * first-occurrence-wins dedupe by id across albums, songs, and playlists
         * (specs/catalog.md §5). Each document's source name is
         * `manifest.sourceName ?? "Collection"`.
         *
         * Synthetic local sources (iOS "Discover"/"Imported") do not exist on
         * Android P1, but the merge-order seam is this parameter: append them
         * AFTER all real sources so a real source always shadows a provisional
         * twin.
         */
        fun merge(documents: List<IndexJson>): MergedCatalog {
            val albumsById = LinkedHashMap<String, IndexAlbum>()
            val songsById = LinkedHashMap<String, IndexSong>()
            val playlistsById = LinkedHashMap<String, SourcePlaylist>()
            val sourceOfAlbum = HashMap<String, String>()
            val sourceOfSong = HashMap<String, String>()
            val sourceNames = LinkedHashSet<String>()

            for (doc in documents) {
                val sourceName = doc.manifest.displayName
                var contributed = false
                for (album in doc.albums) {
                    if (albumsById.putIfAbsent(album.id, album) == null) {
                        sourceOfAlbum[album.id] = sourceName
                        contributed = true
                    }
                }
                for (song in doc.songs) {
                    if (songsById.putIfAbsent(song.id, song) == null) {
                        sourceOfSong[song.id] = sourceName
                        contributed = true
                    }
                }
                for (playlist in doc.playlists.orEmpty()) {
                    playlistsById.putIfAbsent(playlist.id, SourcePlaylist(playlist, sourceName))
                }
                if (contributed) sourceNames.add(sourceName)
            }

            val sortedAlbums = albumsById.values.sortedWith(
                compareBy(String.CASE_INSENSITIVE_ORDER, IndexAlbum::artist)
                    .thenBy(String.CASE_INSENSITIVE_ORDER, IndexAlbum::name),
            )

            return MergedCatalog(
                albums = sortedAlbums,
                songs = songsById.values.toList(),
                playlists = playlistsById.values.toList(),
                albumsById = albumsById,
                songsById = songsById,
                sourceOfAlbum = sourceOfAlbum,
                sourceOfSong = sourceOfSong,
                availableSources = sourceNames.toList(),
            )
        }
    }
}

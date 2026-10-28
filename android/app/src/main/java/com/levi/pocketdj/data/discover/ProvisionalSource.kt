package com.levi.pocketdj.data.discover

import com.levi.pocketdj.data.catalog.IndexJson

/**
 * Discover adds -> the synthetic "Discover" [IndexJson] appended AFTER every real source (iOS
 * `AppModel.withProvisionalSources`). A real row carrying the same `appleMusicId` SUPERSEDES the
 * provisional one: the provisional row is excluded from the document (never shadow-duplicated) and
 * reported as a (provisional -> indexed) pair for the collections remap.
 */
object ProvisionalSource {
    data class Result(
        /** Zero or one document: empty when nothing provisional survives. */
        val documents: List<IndexJson>,
        val supersededSongs: List<Pair<String, String>>,
        val supersededAlbums: List<Pair<String, String>>,
        val keptEntries: List<DiscoverAddsStore.Entry>,
        val keptAlbums: List<DiscoverAddsStore.AlbumEntry>,
    ) {
        val none: Boolean get() = documents.isEmpty() && supersededSongs.isEmpty() && supersededAlbums.isEmpty()
    }

    val EMPTY = Result(emptyList(), emptyList(), emptyList(), emptyList(), emptyList())

    /** Applies the provisional rows over [realDocs] (first-seen claimant per Apple Music id wins). */
    fun resolve(
        entries: List<DiscoverAddsStore.Entry>,
        albums: List<DiscoverAddsStore.AlbumEntry>,
        realDocs: List<IndexJson>,
    ): Result {
        if (entries.isEmpty() && albums.isEmpty()) return EMPTY
        val songByAm = HashMap<String, String>()
        val albumByAm = HashMap<String, String>()
        for (doc in realDocs) {
            for (s in doc.songs) s.appleMusicId?.takeIf { it.isNotEmpty() }?.let { songByAm.putIfAbsent(it, s.id) }
            for (a in doc.albums) a.appleMusicId?.takeIf { it.isNotEmpty() }?.let { albumByAm.putIfAbsent(it, a.id) }
        }
        val (keepSongs, songPairs) = DiscoverAddsStore.split(entries, songByAm)
        val (keepAlbums, albumPairs) = DiscoverAddsStore.splitAlbums(albums, albumByAm)
        // A kept song whose provisional album yielded to a real one points at the real album, never a dangling id.
        val albumRemap = albumPairs.toMap()
        val songs = if (albumRemap.isEmpty()) keepSongs else keepSongs.map { e ->
            e.albumId?.let(albumRemap::get)?.let { e.copy(albumId = it) } ?: e
        }
        val doc = if (songs.isEmpty() && keepAlbums.isEmpty()) emptyList()
        else listOf(DiscoverAddsStore.syntheticIndex(songs, keepAlbums))
        return Result(doc, songPairs, albumPairs, songs, keepAlbums)
    }
}

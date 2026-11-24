package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexJson
import com.levi.pocketdj.data.catalog.IndexManifest
import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.config.Endpoints

/**
 * The catalog fold of the user's own Apple Music library (iOS `AppleMusicLibraryStore.split/syntheticIndex` +
 * `AppModel.withProvisionalSources`, P2-LIB-3). Pure functions + a memoized [Source] the CatalogRepository
 * consumes through the same injection path as DiscoverAdds / ImportedSongs: the library becomes a synthetic
 * document named "Apple Music" (distinct from the private "Apple Music (Local)"), appended after every real
 * source so first-wins shadowing makes an indexed twin win; a library song whose `appleMusicId` an indexed
 * "Apple Music (Local)" song claims is SUPERSEDED onto it (dropped from the fold, remapped by the caller).
 */
object AppleMusicLibraryFold {
    /** Manifest `source` key of the synthetic document (iOS `"apple-music-library"`). */
    const val MANIFEST_SOURCE = "apple-music-library"

    /** Cloud-sync document key (iOS `cloudSync` key). */
    const val SYNC_KEY = "apple-music-library"

    class Split(val keep: List<AppleMusicLibraryStore.SongEntry>, val superseded: List<Pair<String, String>>)

    /**
     * iOS `split`: an entry whose Apple Music id is claimed by an INDEXED song (with a different id) yields
     * to it, returning the (library -> indexed) remap pairs. Entries without an Apple Music id always stay.
     */
    fun split(entries: List<AppleMusicLibraryStore.SongEntry>, indexedByAppleMusicId: Map<String, String>): Split {
        val keep = ArrayList<AppleMusicLibraryStore.SongEntry>(entries.size)
        val superseded = ArrayList<Pair<String, String>>()
        for (e in entries) {
            val indexed = e.appleMusicId?.takeIf { it.isNotEmpty() }?.let { indexedByAppleMusicId[it] }
            if (indexed != null && indexed != e.songId) superseded += e.songId to indexed else keep += e
        }
        return Split(keep, superseded)
    }

    /**
     * appleMusicId -> song id over the PRIVATE "Apple Music (Local)" documents only (first claimant wins).
     * Scoped by source name as defense-in-depth: a "My Vinyl" twin never eats a library row.
     */
    fun ownIndexedByAppleMusicId(real: List<IndexJson>): Map<String, String> {
        val map = HashMap<String, String>()
        for (doc in real) {
            if (doc.manifest.sourceName != Endpoints.SOURCE_NAME_APPLE_MUSIC) continue
            for (s in doc.songs) s.appleMusicId?.takeIf { it.isNotEmpty() }?.let { map.putIfAbsent(it, s.id) }
        }
        return map
    }

    fun indexSong(e: AppleMusicLibraryStore.SongEntry) = IndexSong(
        id = e.songId, albumId = e.albumId, artist = e.artist, name = e.title,
        trackNumber = e.trackNumber, year = e.year, length = e.durationMs?.toLong(),
        appleMusicId = e.appleMusicId, dateAdded = e.addedAtMs,
    )

    fun indexAlbum(e: AppleMusicLibraryStore.AlbumEntry) = IndexAlbum(
        id = e.albumId, artist = e.artist, name = e.title, coverArt = e.artworkUrl,
        genre = e.genre, year = e.year, trackList = e.trackIds,
    )

    /** The synthetic source the merge consumes; its playlists ride `IndexJson.playlists` into the catalog. */
    fun syntheticIndex(
        songs: List<AppleMusicLibraryStore.SongEntry>,
        albums: List<AppleMusicLibraryStore.AlbumEntry>,
        playlists: List<AppleMusicLibraryStore.PlaylistEntry>,
    ) = IndexJson(
        manifest = IndexManifest(source = MANIFEST_SOURCE, sourceName = AppleMusicLibraryStore.SOURCE_NAME),
        albums = albums.map(::indexAlbum),
        songs = songs.map(::indexSong),
        playlists = playlists.map { IndexPlaylist(id = it.id, name = it.name, songIds = it.songIds) },
    )

    class Resolution(val documents: List<IndexJson>, val pairs: List<Pair<String, String>>) {
        companion object { val EMPTY = Resolution(emptyList(), emptyList()) }
    }

    /**
     * Pure core (iOS `withProvisionalSources`, library branch). [supersedes] false -> nothing yields (the
     * owner gate; see [Source]). Playlist song ids that superseded are remapped onto their indexed twins so the
     * mirrors stay playable either way; albums drop superseded track ids (the twin album owns them) and an
     * album left empty is omitted.
     */
    fun fold(
        songs: List<AppleMusicLibraryStore.SongEntry>,
        albums: List<AppleMusicLibraryStore.AlbumEntry>,
        playlists: List<AppleMusicLibraryStore.PlaylistEntry>,
        real: List<IndexJson>,
        supersedes: Boolean,
    ): Resolution {
        if (songs.isEmpty() && playlists.isEmpty()) return Resolution.EMPTY
        val sp = split(songs, if (supersedes) ownIndexedByAppleMusicId(real) else emptyMap())
        if (sp.keep.isEmpty() && playlists.isEmpty()) return Resolution(emptyList(), sp.superseded)
        val remap = sp.superseded.toMap()
        val gone = remap.keys
        val foldedAlbums = if (gone.isEmpty()) albums else albums
            .map { a -> a.copy(trackIds = a.trackIds.filter { it !in gone }) }
            .filter { it.trackIds.isNotEmpty() }
        val foldedPlaylists = if (remap.isEmpty()) playlists else playlists.map { p ->
            p.copy(songIds = p.songIds.map { remap[it] ?: it })
        }
        return Resolution(listOf(syntheticIndex(sp.keep, foldedAlbums, foldedPlaylists)), sp.superseded)
    }

    /**
     * The injection source over a live [AppleMusicLibraryStore]. Memoized on the identity of the store's row
     * lists + the real documents so CatalogRepository's identity-based "same inputs" no-op check still
     * short-circuits an unchanged refresh.
     *
     * [supersedes] is the owner gate (iOS `amLibrarySupersedes`): true only when the indexed "Apple Music
     * (Local)" catalog is provably THIS user's own. Android has no owner-identity probe yet, so the graph
     * passes a setting-backed default (see the P2-LIB-3 status "Questions for Levi").
     */
    class Source(
        private val store: AppleMusicLibraryStore,
        private val supersedes: () -> Boolean = { true },
    ) {
        private class Memo(
            val songs: List<AppleMusicLibraryStore.SongEntry>,
            val albums: List<AppleMusicLibraryStore.AlbumEntry>,
            val playlists: List<AppleMusicLibraryStore.PlaylistEntry>,
            val supersedes: Boolean,
            val real: List<IndexJson>,
            val result: Resolution,
        )

        @Volatile private var memo: Memo? = null

        fun resolve(real: List<IndexJson>): Resolution {
            val songs = store.songs
            val albums = store.albums
            val playlists = store.playlists
            val sup = supersedes()
            val m = memo
            if (m != null && m.songs === songs && m.albums === albums && m.playlists === playlists &&
                m.supersedes == sup && m.real.size == real.size && m.real.indices.all { m.real[it] === real[it] }
            ) return m.result
            val r = fold(songs, albums, playlists, real, sup)
            memo = Memo(songs, albums, playlists, sup, real.toList(), r)
            return r
        }
    }
}

package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexArtist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.screens.browse.Genre

/**
 * The merged catalog projected into the shape [ZoneEngine] ranks over (port of
 * `AppModel.zoneTracks` / `zoneGenreBySongId`), built once per catalog revision.
 *
 * Rules carried over from iOS:
 *  - genre is `Genre.category(album.genre)`, with the catch-all "Other" mapped to null so the
 *    biggest bucket never acts as a similarity signal;
 *  - year falls back to the ALBUM's (the song field is absent on a slice of the vinyl index);
 *  - `genreRaw` is the album's UNCOLLAPSED label (variety, not similarity);
 *  - `genreBySongId` is derived from the SAME projection so the two can never disagree about
 *    which songs have no genre.
 */
class ZoneCatalog private constructor(
    val tracks: List<ZoneEngine.Track>,
    val genreBySongId: Map<String, String>,
) {
    /** Version identities parsed once per catalog (shared across every crate). Lazy: only the collection pass needs it. */
    val versionKeys: Map<String, RecVersionIdentity.Key> by lazy { ZoneEngine.versionKeys(tracks) }

    companion object {
        fun project(songs: List<IndexSong>, albumsById: Map<String, IndexAlbum>): ZoneCatalog {
            val tracks = ArrayList<ZoneEngine.Track>(songs.size)
            val genres = HashMap<String, String>(songs.size)
            for (s in songs) {
                val album = s.albumId?.let { albumsById[it] }
                val cat = Genre.category(album?.genre)
                val genre = if (cat == Genre.OTHER) null else cat
                tracks.add(
                    ZoneEngine.Track(
                        songId = s.id,
                        artistKey = IndexArtist.normalize(s.artist),
                        artistName = s.artist,
                        genre = genre,
                        year = s.year ?: album?.year,
                        bpm = s.bpm,
                        camelot = s.camelot,
                        appleMusicId = s.appleMusicId,
                        title = s.name,
                        lengthMs = s.length?.toInt(),
                        genreRaw = album?.genre,
                    ),
                )
                if (genre != null) genres[s.id] = genre
            }
            return ZoneCatalog(tracks, genres)
        }

        fun from(catalog: MergedCatalog): ZoneCatalog = project(catalog.songs, catalog.albumsById)
    }
}

/** Memo keyed on a catalog revision: a stale projection can never survive a catalog change. */
class ZoneCatalogCache {
    private var revision: Int? = null
    private var cached: ZoneCatalog? = null

    @Synchronized
    fun get(revision: Int, build: () -> ZoneCatalog): ZoneCatalog {
        val c = cached
        if (c != null && this.revision == revision) return c
        return build().also { cached = it; this.revision = revision }
    }
}

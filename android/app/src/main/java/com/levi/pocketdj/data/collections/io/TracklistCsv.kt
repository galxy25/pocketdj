package com.levi.pocketdj.data.collections.io

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.share.ShareText

/**
 * UNIVERSAL tracklist CSV (iOS `Support/TracklistCSV.swift`): `#, Title, Artist, Album, Year, Genre,
 * Apple Music, Spotify, YouTube`. PocketDJ-specific metadata (bpm, key, song id…) is deliberately
 * omitted. UTF-8, CRLF line endings + a trailing CRLF.
 */
object TracklistCsv {
    data class Row(
        val title: String,
        val artist: String,
        val album: String,
        val year: Int?,
        val genre: String,
        val appleMusicUrl: String = "",
        val spotifyUrl: String = "",
        val youtubeUrl: String = "",
    )

    val header: List<String> =
        listOf("#", "Title", "Artist", "Album", "Year", "Genre", "Apple Music", "Spotify", "YouTube")

    fun data(rows: List<Row>): ByteArray {
        val lines = ArrayList<String>()
        lines += header.joinToString(",")
        rows.forEachIndexed { i, r ->
            val cells = listOf(
                "${i + 1}", r.title, r.artist, r.album, r.year?.toString() ?: "", r.genre,
                r.appleMusicUrl, r.spotifyUrl, r.youtubeUrl,
            )
            lines += cells.joinToString(",") { cell(it) }
        }
        return (lines.joinToString("\r\n") + "\r\n").toByteArray(Charsets.UTF_8)
    }

    /** Quote when the cell has a comma / quote / newline; inner quotes double. */
    private fun cell(s: String): String {
        if (s.none { it == ',' || it == '"' || it == '\n' || it == '\r' }) return s
        return "\"" + s.replace("\"", "\"\"") + "\""
    }

    /**
     * Resolve ordered song ids to rows (iOS `AppModel.tracklistCSVRows`): genre + album name live on
     * the album; year prefers the song's, else the album's; ids with no catalog song drop. Link
     * columns use the same resolvers as the share text (direct link else a per-service search link).
     */
    fun rows(
        songIds: List<String>,
        songsById: Map<String, IndexSong>,
        albumsById: Map<String, IndexAlbum>,
    ): List<Row> = songIds.mapNotNull { id ->
        val s = songsById[id] ?: return@mapNotNull null
        val album = s.albumId?.let { albumsById[it] }
        Row(
            title = s.name, artist = s.artist, album = album?.name ?: "",
            year = s.year ?: album?.year, genre = album?.genre ?: "",
            appleMusicUrl = ShareText.appleMusicUrl(s.appleMusicUrl, s.appleMusicId, "song", s.name, s.artist),
            spotifyUrl = ShareText.spotifyUrl(s.spotifyUrl, s.name, s.artist),
            youtubeUrl = ShareText.youtubeUrl(s.youtubeUrl, s.name, s.artist),
        )
    }
}

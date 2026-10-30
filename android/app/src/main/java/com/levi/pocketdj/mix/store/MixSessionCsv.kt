package com.levi.pocketdj.mix.store

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.collections.io.TracklistCsv

/**
 * Mix session -> tracklist CSV (iOS `MixSessionsView.exportCSV`): the session's PLAYED tracks in
 * order, with the universal iOS columns (`#, Title, Artist, Album, Year, Genre, Apple Music,
 * Spotify, YouTube`) via the shared [TracklistCsv] encoder. File name is `<session name>.csv`
 * with filesystem-reserved characters removed and "session" when nothing is left.
 */
object MixSessionCsv {
    const val MIME = "text/csv"

    /** iOS strips `\ / : * ? " < > |` and trims; blank -> "session"; `.csv` is written explicitly. */
    fun filename(sessionName: String?): String {
        val base = (sessionName ?: "session")
            .filterNot { it in "\\/:*?\"<>|" }
            .trim()
        return (base.ifEmpty { "session" }) + ".csv"
    }

    fun bytes(
        playedSongIds: List<String>,
        songsById: Map<String, IndexSong>,
        albumsById: Map<String, IndexAlbum>,
    ): ByteArray = TracklistCsv.data(TracklistCsv.rows(playedSongIds, songsById, albumsById))
}

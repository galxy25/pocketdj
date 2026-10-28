package com.levi.pocketdj.data.share

import android.content.Context
import android.content.Intent
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong

/**
 * Shareable TEXT BLOCK for a song or album (iOS `ShareText`): a headline "Title — Artist" then one
 * line per music service. Canonical links when the catalog has them, else a search deep-link.
 * Plain text, no markup.
 */
object ShareText {

    /** Whitespace runs collapse to one space, then percent-encode everything but `-._~` + alphanumerics. */
    fun query(title: String, artist: String): String {
        val raw = "$artist $title".split(Regex("[\\s\\p{Z}]+")).filter { it.isNotEmpty() }.joinToString(" ")
        val sb = StringBuilder()
        for (b in raw.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xFF).toChar()
            if ((c in 'a'..'z') || (c in 'A'..'Z') || (c in '0'..'9') || c in "-._~") sb.append(c)
            else sb.append('%').append("%02X".format(b.toInt() and 0xFF))
        }
        return sb.toString()
    }

    fun appleMusicUrl(url: String?, id: String?, kind: String, title: String, artist: String): String = when {
        !url.isNullOrEmpty() -> url
        !id.isNullOrEmpty() -> "https://music.apple.com/$kind/$id"
        else -> "https://music.apple.com/search?term=${query(title, artist)}"
    }

    fun spotifyUrl(url: String?, title: String, artist: String): String =
        if (!url.isNullOrEmpty()) url else "https://open.spotify.com/search/results/${query(title, artist)}"

    fun youtubeUrl(url: String?, title: String, artist: String): String =
        if (!url.isNullOrEmpty()) url else "https://music.youtube.com/search?q=${query(title, artist)}"

    fun forSong(s: IndexSong): String = listOf(
        "${s.name} — ${s.artist}",
        "Apple Music: ${appleMusicUrl(s.appleMusicUrl, s.appleMusicId, "song", s.name, s.artist)}",
        "Spotify: ${spotifyUrl(s.spotifyUrl, s.name, s.artist)}",
        "YouTube: ${youtubeUrl(s.youtubeUrl, s.name, s.artist)}",
    ).joinToString("\n")

    fun forAlbum(a: IndexAlbum): String = listOf(
        "${a.name} — ${a.artist}",
        "Apple Music: ${appleMusicUrl(a.appleMusicUrl, a.appleMusicId, "album", a.name, a.artist)}",
        "Spotify: ${spotifyUrl(a.spotifyUrl, a.name, a.artist)}",
        "YouTube: ${youtubeUrl(a.youtubeUrl, a.name, a.artist)}",
    ).joinToString("\n")

    /** Several songs (multi-select share): one block each, blank-line separated. */
    fun forSongs(songs: List<IndexSong>): String = songs.joinToString("\n\n") { forSong(it) }

    /** Bare title/artist (a now-playing track that isn't in the catalog): search links only. */
    fun forTitleArtist(title: String, artist: String): String = listOf(
        "$title — $artist",
        "Apple Music: ${appleMusicUrl(null, null, "song", title, artist)}",
        "Spotify: ${spotifyUrl(null, title, artist)}",
        "YouTube: ${youtubeUrl(null, title, artist)}",
    ).joinToString("\n")

    /** ACTION_SEND chooser for [text]. */
    fun send(context: Context, text: String, subject: String? = null) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            subject?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
        }
        context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

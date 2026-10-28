package com.levi.pocketdj.screens.shazam

import com.levi.pocketdj.data.catalog.IndexSong
import java.text.Normalizer

/** The handful of fields read off a recognition hit, with no ShazamKit type (iOS ShazamHitInfo). */
data class ShazamHitInfo(
    val title: String?,
    val artist: String?,
    val artworkUrl: String?,
    /** Apple Music store id when Shazam returns one. */
    val appleMusicId: String?,
)

/** Where a recognition landed against OUR catalog (iOS ShazamMatch). */
sealed interface ShazamMatch {
    val info: ShazamHitInfo

    data class InCatalog(val song: IndexSong, override val info: ShazamHitInfo) : ShazamMatch
    data class NotInCatalog(override val info: ShazamHitInfo) : ShazamMatch
}

/** Pure matcher: normalized title + compatible artist (iOS ShazamCatalogMatch). */
object ShazamCatalogMatch {
    private val combining = Regex("\\p{M}+")
    private val paren = Regex("\\([^)]*\\)")
    private val bracket = Regex("\\[[^\\]]*\\]")
    private val dashClause = Regex(
        "\\s-\\s.*(remaster|remastered|live|mono|stereo|version|edit|mix|deluxe|anniversary).*$",
        RegexOption.IGNORE_CASE,
    )
    private val nonAlnum = Regex("[^a-z0-9 ]")
    private val spaces = Regex("\\s+")

    /**
     * lowercase + diacritic fold, drop (...)/[...] tails, drop a " - remastered/live/..." clause,
     * strip punctuation, collapse spaces.
     */
    fun norm(raw: String): String {
        var s = Normalizer.normalize(raw, Normalizer.Form.NFD).replace(combining, "").lowercase()
        s = s.replace(paren, " ").replace(bracket, " ")
        s = s.replace(dashClause, " ")
        s = s.replace(nonAlnum, " ").replace(spaces, " ")
        return s.trim()
    }

    /** True when two NORMALIZED artists are equal or one contains the other. */
    fun artistsCompatible(a: String, b: String): Boolean = a == b || a.contains(b) || b.contains(a)

    /** Equal normalized titles AND compatible artists (no hit artist = title only); first hit wins. */
    fun resolve(info: ShazamHitInfo, songs: List<IndexSong>): ShazamMatch {
        val title = info.title?.let(::norm)
        if (title.isNullOrEmpty()) return ShazamMatch.NotInCatalog(info)
        val artist = info.artist?.let(::norm)
        val hit = songs.firstOrNull { song ->
            if (norm(song.name) != title) return@firstOrNull false
            if (artist.isNullOrEmpty()) return@firstOrNull true
            artistsCompatible(norm(song.artist), artist)
        }
        return if (hit != null) ShazamMatch.InCatalog(hit, info) else ShazamMatch.NotInCatalog(info)
    }
}

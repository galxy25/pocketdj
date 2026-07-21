package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.catalog.IndexSong
import java.text.Normalizer

/**
 * Catalog-only request matching — the Android P1 cut of the iOS four-stage
 * matcher (specs/jukebox.md §4.4): normalized-exact first, then a
 * folded-contains fuzzy score. No Foundation Models, no MusicKit.
 *
 * Pure and synchronous; callers run it off the main thread (the catalog can be
 * tens of thousands of songs).
 */
object JukeboxMatcher {

    /**
     * Fold for matching: casefold, strip diacritics (NFD, marks dropped), strip
     * punctuation, collapse whitespace.
     */
    fun normalize(raw: String): String {
        val decomposed = Normalizer.normalize(raw, Normalizer.Form.NFD)
        val builder = StringBuilder(decomposed.length)
        var lastWasSpace = true
        for (ch in decomposed) {
            when {
                ch.isLetterOrDigit() -> {
                    builder.append(ch.lowercaseChar())
                    lastWasSpace = false
                }
                ch.isWhitespace() && !lastWasSpace -> {
                    builder.append(' ')
                    lastWasSpace = true
                }
                // Punctuation, symbols, and combining marks are dropped.
            }
        }
        return builder.toString().trim()
    }

    /**
     * Best catalog candidate for what the guest typed, or null. Title overlap
     * is required; the artist (when the guest gave one) disambiguates.
     */
    fun match(title: String, artist: String, songs: List<IndexSong>): IndexSong? {
        val queryTitle = normalize(title)
        if (queryTitle.isEmpty()) return null
        val queryArtist = normalize(artist)

        var best: IndexSong? = null
        var bestScore = 0
        for (song in songs) {
            val songTitle = normalize(song.name)
            var score = when {
                songTitle == queryTitle -> 4
                queryTitle.length >= MIN_CONTAINS_LENGTH &&
                    (songTitle.contains(queryTitle) || queryTitle.contains(songTitle)) -> 2
                else -> 0
            }
            if (score == 0) continue

            if (queryArtist.isNotEmpty()) {
                val songArtist = normalize(song.artist)
                score += when {
                    songArtist == queryArtist -> 3
                    queryArtist.length >= MIN_CONTAINS_LENGTH &&
                        (songArtist.contains(queryArtist) || queryArtist.contains(songArtist)) -> 2
                    // Guest named a different artist — likely a different song.
                    else -> -2
                }
            }

            if (score > bestScore) {
                bestScore = score
                best = song
                if (bestScore >= PERFECT_SCORE) break
            }
        }
        return if (bestScore >= MIN_ACCEPT_SCORE) best else null
    }

    /** Guard so one-letter queries don't `contains`-match the whole catalog. */
    private const val MIN_CONTAINS_LENGTH = 3
    private const val MIN_ACCEPT_SCORE = 2
    private const val PERFECT_SCORE = 7
}

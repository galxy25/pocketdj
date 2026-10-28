package com.levi.pocketdj.data.applemusic

import java.text.Normalizer
import java.util.Locale

/**
 * A song's IDENTITY handed to the transport so it can resolve a catalog id when the indexer never
 * minted one. [appleMusicId] is "" when unknown (the case that drives resolution); title/artist
 * are the match keys; album + duration disambiguate. Port of iOS `WriteBackSong`.
 */
data class WriteBackSong(
    val appleMusicId: String,
    val title: String,
    val artist: String,
    val album: String? = null,
    val durationMs: Int? = null,
)

/** One Apple Music catalog search result, projected so the match decision is pure. */
data class WriteBackCatalogCandidate(
    val id: String,
    val title: String,
    val artist: String,
    val album: String? = null,
    val durationSec: Double? = null,
)

/**
 * The on-device catalog-match DECISION (iOS `WriteBackMatcher`). CONSERVATIVE on purpose: adding the
 * WRONG song to the user's real Apple Music playlist is worse than not adding at all, so an
 * unconfident or ambiguous result returns null (-> the job settles UNRESOLVABLE). DETERMINISTIC:
 * two independent runs over the same candidates pick the SAME id (stable min-id tie-break).
 */
object WriteBackMatcher {

    /** Fold case + diacritics (NFD, strip combining marks), like Swift's `.folding`. */
    internal fun fold(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD)
            .filter { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }
            .lowercase(Locale.ROOT)

    /**
     * Normalize a title/artist/album for matching: fold case + diacritics, then keep only letters
     * and digits. `keepVersion = false` ALSO drops any parenthetical/bracketed span ("(feat. ...)",
     * "[Remastered]") - the LOOSE base-title key. `keepVersion = true` preserves those characters -
     * the STRICT key that tells version/part siblings apart.
     */
    fun matchKey(s: String, keepVersion: Boolean): String {
        val t = StringBuilder(fold(s))
        if (!keepVersion) {
            while (true) {
                val open = t.indexOfFirst { it == '(' || it == '[' }
                if (open < 0) break
                val close = if (t[open] == '(') ')' else ']'
                val end = t.indexOf(close.toString(), open)
                if (end >= 0) {
                    t.delete(open, end + 1)
                } else {
                    t.delete(open, t.length) // unbalanced - drop the tail
                    break
                }
            }
        }
        // Code points, not UTF-16 chars (supplementary-plane letters), and L*/N*/M* like Swift's
        // CharacterSet.alphanumerics (combining marks stay, e.g. Devanagari matras).
        val out = StringBuilder()
        t.codePoints().forEach { cp ->
            if (Character.isLetterOrDigit(cp) || isMark(cp)) out.appendCodePoint(cp)
        }
        return out.toString()
    }

    private fun isMark(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> true
        else -> false
    }

    private data class Scored(val id: String, val artist: String, val score: Int)

    /** Best catalog id to write for [song], or null when nothing is confident / the top is ambiguous. */
    fun bestMatch(song: WriteBackSong, among: List<WriteBackCatalogCandidate>): String? {
        val wantBase = matchKey(song.title, keepVersion = false)
        val wantFull = matchKey(song.title, keepVersion = true)
        val wantArtist = matchKey(song.artist, keepVersion = true)
        if (wantBase.isEmpty() || wantArtist.isEmpty()) return null
        val userHasMarker = wantFull != wantBase

        val scored = ArrayList<Scored>()
        for (c in among) {
            val cBase = matchKey(c.title, keepVersion = false)
            if (cBase != wantBase) continue
            val cFull = matchKey(c.title, keepVersion = true)
            val titleFullMatch = cFull == wantFull
            // A version/part-marked title only matches the SAME full identity ("Taylor's Version" trap).
            if (userHasMarker && !titleFullMatch) continue
            val candidateIsUnwantedVariant = (cFull != cBase) && !userHasMarker

            val cArtist = matchKey(c.artist, keepVersion = true)
            val artistExact = cArtist == wantArtist
            if (!(artistExact || cArtist.contains(wantArtist) || wantArtist.contains(cArtist))) continue

            var score = 0
            var durationCorroborated = false
            val want = song.durationMs
            if (want != null) {
                val got = c.durationSec
                if (got != null) {
                    val diffSec = kotlin.math.abs(got - want.toDouble() / 1000)
                    if (diffSec <= 4) {
                        score += 3; durationCorroborated = true
                    } else if (diffSec <= 12) {
                        score += 1; durationCorroborated = true
                    } else {
                        continue // >12 s apart - a different recording
                    }
                }
            }
            val albumMatch = run {
                val al = song.album
                if (al.isNullOrEmpty()) false
                else matchKey(c.album.orEmpty(), keepVersion = false) == matchKey(al, keepVersion = false)
            }
            if (albumMatch) score += 2
            if (artistExact) score += 2
            if (titleFullMatch && userHasMarker) score += 2

            // CONFIDENCE FLOOR: a bare title match is never enough to write to the REAL playlist.
            val strong = durationCorroborated || albumMatch
            val corroborated = if (candidateIsUnwantedVariant) strong
            else (artistExact || strong || (titleFullMatch && userHasMarker))
            if (!corroborated) continue

            scored += Scored(c.id, cArtist, score)
        }
        val topScore = scored.maxOfOrNull { it.score } ?: return null
        val top = scored.filter { it.score == topScore }
        // Ambiguous across DIFFERENT artists at the top score -> refuse to guess.
        if (top.map { it.artist }.toSet().size > 1) return null
        // Deterministic pick among same-artist editions.
        return top.minOf { it.id }
    }
}

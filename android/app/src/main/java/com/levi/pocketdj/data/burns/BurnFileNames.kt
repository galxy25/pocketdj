package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.rips.RipManifestEntry
import java.text.BreakIterator

/**
 * Pure, byte-identical port of the iOS burn file naming (CRITIC-A). The audio name carries a
 * SANITIZED descriptive prefix but ALWAYS ends in the stable id suffix + extension, which are
 * NEVER truncated. Only the prefix is capped ([PREFIX_CAP]); each token is capped ([TOKEN_CAP]).
 */
object BurnFileNames {
    const val TOKEN_CAP = 40
    const val PREFIX_CAP = 150
    val STEM_NAMES = listOf("vocals", "drums", "bass", "other")

    fun stemFileName(songId: String, stem: String) = "stem-$songId-$stem.mp3"
    fun beatgridFileName(songId: String) = "analysis-$songId.json"

    /** Characters Swift's `CharacterSet(charactersIn:"/\\:*?\"<>|-")` + control + newlines map to a space. */
    private fun isIllegal(cp: Int): Boolean {
        if ("/\\:*?\"<>|-".indexOf(cp.toChar()) >= 0 && cp < 128) return true
        if (Character.getType(cp) == Character.CONTROL.toInt()) return true
        return cp in 0x0A..0x0D || cp == 0x85 || cp == 0x2028 || cp == 0x2029
    }

    private fun isTrimWhitespace(cp: Int): Boolean =
        cp == 0x09 || Character.getType(cp) == Character.SPACE_SEPARATOR.toInt()

    /** First [n] user-perceived characters (Swift `prefix` counts grapheme clusters). */
    internal fun prefixChars(s: String, n: Int): String {
        if (s.length <= n) return s
        val it = BreakIterator.getCharacterInstance()
        it.setText(s)
        var count = 0
        var end = 0
        var b = it.next()
        while (b != BreakIterator.DONE && count < n) {
            end = b
            count++
            b = it.next()
        }
        return s.substring(0, end)
    }

    /** Strip path/illegal chars (and our own "-" separator) to spaces, collapse, cap at 40. */
    fun sanitizeToken(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        val sb = StringBuilder()
        var i = 0
        while (i < raw.length) {
            val cp = raw.codePointAt(i)
            sb.append(if (isIllegal(cp)) " " else String(Character.toChars(cp)))
            i += Character.charCount(cp)
        }
        val collapsed = sb.toString().split(' ').filter { it.isNotEmpty() }.joinToString(" ")
        // trimmingCharacters(in: .whitespaces)
        var s = 0
        var e = collapsed.length
        while (s < e && isTrimWhitespace(collapsed.codePointAt(s))) s += Character.charCount(collapsed.codePointAt(s))
        while (e > s && isTrimWhitespace(collapsed.codePointBefore(e))) e -= Character.charCount(collapsed.codePointBefore(e))
        val trimmed = collapsed.substring(s, e)
        if (trimmed.isEmpty()) return null
        return prefixChars(trimmed, TOKEN_CAP)
    }

    fun joinTokens(parts: List<String?>): String =
        parts.mapNotNull { sanitizeToken(it) }.filter { it.isNotEmpty() }.joinToString("-")

    /** "<prefix>-<idSuffix>.<ext>"; ONLY the prefix is truncated; blank prefix => "<id>.<ext>". */
    fun descriptiveName(prefix: String, idSuffix: String, ext: String): String {
        val safeId = idSuffix.ifEmpty { "audio" }
        val capped = prefixChars(prefix, PREFIX_CAP).trim { it == ' ' || it == '-' }
        return if (capped.isEmpty()) "$safeId.$ext" else "$capped-$safeId.$ext"
    }

    /** Manifest key basename without extension ("rips/alb_1.mp3" -> "alb_1"), else the songId. */
    fun idToken(entryKey: String, songId: String): String {
        val base = entryKey.substringAfterLast('/').substringBeforeLast('.', entryKey.substringAfterLast('/'))
        return base.ifEmpty { songId }
    }

    /** "Artist-Song-Album-Year-Genre-Camelot-Key-BPM" (digital per-song). */
    fun digitalSongPrefix(song: IndexSong?, album: IndexAlbum?, entry: RipManifestEntry?): String {
        val bpm = entry?.bpm ?: song?.bpm
        return joinTokens(
            listOf(
                song?.artist,
                song?.name,
                album?.name,
                (song?.year ?: album?.year)?.toString(),
                album?.genre,
                entry?.camelot ?: song?.camelot,
                entry?.musicalKey ?: song?.key,
                bpm?.let { Math.round(it).toString() },
            ),
        )
    }

    /** "Artist-Album-Year-Genre" for the ANALOG shared whole-album file. */
    fun analogAlbumPrefix(song: IndexSong?, album: IndexAlbum?): String =
        joinTokens(listOf(album?.artist ?: song?.artist, album?.name, album?.year?.toString(), album?.genre))

    data class Names(val audio: String, val sidecar: String)

    /** The burned audio + (always per-song) sidecar names. */
    fun fileNames(songId: String, entry: RipManifestEntry, song: IndexSong?, album: IndexAlbum?): Names {
        val isAnalog = entry.source == "analog"
        val idToken = idToken(entry.key, songId)
        val prefix = if (isAnalog) analogAlbumPrefix(song, album) else digitalSongPrefix(song, album, entry)
        val audio = descriptiveName(prefix, idToken, "mp3")
        val sidecar = descriptiveName(digitalSongPrefix(song, album, entry), songId, "txt")
        return Names(audio, sidecar)
    }

    /** The per-song analog cut export name (`<digital prefix>-<songId>.mp3`). */
    fun cutFileName(song: IndexSong?, album: IndexAlbum?, entry: RipManifestEntry, songId: String): String =
        descriptiveName(digitalSongPrefix(song, album, entry), songId, "mp3")

    /** Stable id token = everything after the LAST "-" of the basename (or the whole basename). */
    fun stableIdSuffix(baseName: String): String {
        val i = baseName.lastIndexOf('-')
        return if (i >= 0) baseName.substring(i + 1) else baseName
    }

    /** Pick the per-song CUT out of a dir listing (see iOS doc): ends `-<songId>.mp3` and is not the audio. */
    fun cutFileNameAmongst(names: List<String>, songId: String, audioFileName: String): String? {
        if (songId.isEmpty()) return null
        val suffix = "-$songId.mp3"
        val exact = "$songId.mp3"
        return names.firstOrNull { it != audioFileName && (it.endsWith(suffix) || it == exact) }
    }

    /** Song id embedded in an EXACT `stem-<id>-<part>.mp3` / `analysis-<id>.json` name, else null. */
    fun auxFileSongId(name: String): String? {
        if (name.startsWith("stem-") && name.endsWith(".mp3")) {
            val core = name.removePrefix("stem-").removeSuffix(".mp3")
            for (part in STEM_NAMES) {
                if (core.endsWith("-$part")) {
                    val id = core.dropLast(part.length + 1)
                    return id.ifEmpty { null }
                }
            }
            return null
        }
        if (name.startsWith("analysis-") && name.endsWith(".json")) {
            return name.removePrefix("analysis-").removeSuffix(".json").ifEmpty { null }
        }
        return null
    }

    /** Strictly a stem file — never matches `analysis-*.json`. */
    fun isStemFile(name: String): Boolean =
        name.startsWith("stem-") && name.endsWith(".mp3") && auxFileSongId(name) != null
}

package com.levi.pocketdj.assistant

import com.levi.pocketdj.data.collections.FuzzyMatch
import com.levi.pocketdj.data.collections.SongDuplicateJudge
import java.text.Normalizer

/**
 * Resolves a SPOKEN song request ("make me proud", "Make Me Proud by Drake", "make me prowd")
 * against the catalog. Port of iOS `IntentSongMatcher`; pure and JVM-testable.
 *
 * Readings: the WHOLE phrase as a title ("Stand by Me" must keep working), plus, when it holds
 * " by ", the part before the LAST " by " as title and the rest as artist (an artist that does
 * not match drops that reading for that song).
 *
 * Title tiers (best first): exact, exact without parenthetical / " - Remaster" tail, prefix,
 * whole-word substring, then OSA typo (only when nothing literal matched). An agreeing artist
 * adds score. Results are deduped by RECORDING ([SongDuplicateJudge.key]) and cut to the top tier.
 */
object IntentSongMatcher {

    /** One catalog row, pre-normalized (callers cache these per catalog identity). */
    class Row(val id: String, val name: String, val artist: String) {
        /** Alphanumerics only, case + diacritics folded ("Make Me Proud!" -> "makemeproud"). */
        val title: String = compact(name)

        /** [title] without parenthetical / bracketed spans and " - ..." version tails. */
        val base: String = compact(stripVersion(name))
        val artistKey: String = compact(artist)

        /** Space-separated folded title words, space-padded, for whole-word hits. */
        val words: String = " " + wordKey(name) + " "
    }

    data class Match(val id: String, val score: Double)

    /** Candidates within this many points of the best are "equally plausible". */
    const val TIER_BAND = 12.0

    private val combining = Regex("[\\u0300-\\u036F\\u1AB0-\\u1AFF\\u1DC0-\\u1DFF\\u20D0-\\u20FF\\uFE20-\\uFE2F]+")

    fun fold(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).replace(combining, "").lowercase().replace("&", " and ")

    private fun isAlnum(cp: Int) = Character.isLetterOrDigit(cp)

    /** Folded, alphanumerics only. */
    fun compact(s: String): String {
        val sb = StringBuilder()
        fold(s).codePoints().forEach { if (isAlnum(it)) sb.appendCodePoint(it) }
        return sb.toString()
    }

    /** Folded words separated by single spaces (punctuation becomes a break). */
    fun wordKey(s: String): String {
        val sb = StringBuilder()
        fold(s).codePoints().forEach { sb.appendCodePoint(if (isAlnum(it)) it else ' '.code) }
        return sb.toString().split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** "Song (feat. X) [Remastered] - 2011 Remaster" -> "Song". */
    fun stripVersion(s: String): String {
        var t = s
        while (true) {
            val open = t.indexOfFirst { it == '(' || it == '[' }
            if (open < 0) break
            val close = if (t[open] == '(') ')' else ']'
            val end = t.indexOf(close, open)
            if (end >= 0) {
                t = t.removeRange(open, end + 1)
            } else {
                t = t.substring(0, open)
                break
            }
        }
        val dash = t.indexOf(" - ")
        if (dash >= 0) t = t.substring(0, dash)
        return t.trim()
    }

    data class Reading(val title: String, val artist: String?)

    private val quotes = "\"“”'‘’"

    /** The readings of a request; leading filler Siri tends to pass through ("the song ...") is dropped. */
    fun readings(raw: String): List<Reading> {
        var q = raw.trim().trim { it in quotes }
        for (filler in listOf("the song ", "song ")) {
            if (q.lowercase().startsWith(filler)) {
                q = q.substring(filler.length)
                break
            }
        }
        if (q.isEmpty()) return emptyList()
        val out = arrayListOf(Reading(q, null))
        val at = q.lowercase().lastIndexOf(" by ")
        if (at >= 0) {
            val t = q.substring(0, at).trim()
            val a = q.substring(at + 4).trim()
            if (t.isNotEmpty() && a.isNotEmpty()) out += Reading(t, a)
        }
        return out
    }

    /**
     * Ranked, recording-deduplicated, top-tier matches. [prefer] breaks ties between copies of one
     * recording and lifts equally scored candidates (the playing song, one already in a collection).
     */
    fun rank(query: String, rows: List<Row>, prefer: (String) -> Boolean = { false }, limit: Int = 8): List<Match> {
        val reads = readings(query)
        if (reads.isEmpty()) return emptyList()
        val best = HashMap<Int, Double>()
        fun consider(i: Int, s: Double) {
            if (s > (best[i] ?: -1.0)) best[i] = s
        }
        for (literalOnly in listOf(true, false)) {
            for (read in reads) {
                val qt = compact(read.title)
                if (qt.isEmpty()) continue
                val qw = " " + wordKey(read.title) + " "
                val qa = read.artist?.let(::compact)
                val qChars = qt.toList()
                for ((i, row) in rows.withIndex()) {
                    var s = literalTitleScore(qt, qw, row)
                        ?: (if (!literalOnly) approximateTitleScore(qChars, row) else null)
                        ?: continue
                    if (!qa.isNullOrEmpty()) s += artistScore(qa, row.artistKey) ?: continue
                    consider(i, s)
                }
            }
            if (best.isNotEmpty()) break // the typo pass only when nothing literal hit
        }
        if (best.isEmpty()) return emptyList()

        class Pick(val i: Int, val s: Double, val pref: Boolean)
        val byRecording = HashMap<String, Pick>()
        for ((i, s) in best) {
            val row = rows[i]
            val key = SongDuplicateJudge.key(row.name, row.artist)
            val pref = prefer(row.id)
            val cur = byRecording[key]
            if (cur == null ||
                s > cur.s || (s == cur.s && pref && !cur.pref) || (s == cur.s && pref == cur.pref && i < cur.i)
            ) {
                byRecording[key] = Pick(i, s, pref)
            }
        }
        fun eff(p: Pick) = p.s + if (p.pref) 5 else 0
        val ranked = byRecording.values.sortedWith { a, b ->
            val ea = eff(a)
            val eb = eff(b)
            if (ea != eb) eb.compareTo(ea) else a.i.compareTo(b.i)
        }
        val topScore = eff(ranked.first())
        return ranked.filter { topScore - eff(it) <= TIER_BAND }.take(limit).map { Match(rows[it.i].id, it.s) }
    }

    private fun literalTitleScore(q: String, qWords: String, row: Row): Double? {
        if (row.title == q) return 100.0
        if (row.base == q) return 95.0
        val penalty = minOf(maxOf(row.title.length - q.length, 0) * 0.5, 15.0)
        if (q.length >= 3 && (row.base.startsWith(q) || row.title.startsWith(q))) return 80 - penalty
        if (q.length >= 4 && row.words.contains(qWords)) return 65 - penalty
        return null
    }

    private fun approximateTitleScore(q: List<Char>, row: Row): Double? {
        val budget = FuzzyMatch.errorBudget(q.size)
        if (budget <= 0) return null
        val target = (row.base.ifEmpty { row.title }).toList()
        // Whole-title typos only (a free-floating substring hit on a 100k catalog is noise).
        if (kotlin.math.abs(target.size - q.size) > budget) return null
        val d = FuzzyMatch.approximateDistance(q, target)
        if (d > budget) return null
        return 50.0 - d * 8
    }

    private fun artistScore(q: String, artist: String): Double? {
        if (artist.isEmpty()) return null
        if (artist == q) return 30.0
        val qNoThe = if (q.startsWith("the")) q.drop(3) else q
        val aNoThe = if (artist.startsWith("the")) artist.drop(3) else artist
        if (aNoThe == qNoThe) return 30.0
        if (q.length >= 3 && (artist.contains(q) || q.contains(artist))) return 20.0
        val budget = FuzzyMatch.errorBudget(q.length)
        if (budget > 0 && FuzzyMatch.approximateDistance(q.toList(), artist.toList()) <= budget) return 10.0
        return null
    }
}

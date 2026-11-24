package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.screens.browse.Genre
import java.util.Locale

/** Structured filters extracted from a natural-language brief (iOS `ParsedPocketBrief`). */
data class ParsedPocketBrief(
    val moods: List<String> = emptyList(),
    val genres: List<String> = emptyList(),
    val yearFrom: Int? = null,
    val yearTo: Int? = null,
    /** A length the brief asked for ("a 45 minute pocket"); null = the caller's default. */
    val minutes: Int? = null,
)

/** The words the parser may recognise beyond its built-ins: the catalog's own genre / sentiment strings. */
data class PocketVocabulary(
    val genres: Set<String> = emptySet(),
    val moods: Set<String> = emptySet(),
)

/**
 * The deterministic brief grammar (the door that works on every device): years / ranges / decades, catalog genres
 * and the Genre star-map keywords, mood words from the built-in list plus the catalog's sentiment vocabulary, and
 * an optional length. Pure JVM.
 */
object PocketBriefParser {
    private val DECADE_WORDS = mapOf(
        "twenties" to 1920, "thirties" to 1930, "forties" to 1940, "fifties" to 1950, "sixties" to 1960,
        "seventies" to 1970, "eighties" to 1980, "nineties" to 1990, "noughties" to 2000, "aughts" to 2000,
    )

    /** Built-in moods with the near-synonyms that widen the match against a song's sentiment keywords. */
    val MOOD_SYNONYMS: Map<String, List<String>> = mapOf(
        "chill" to listOf("relaxed", "mellow", "calm"),
        "mellow" to listOf("chill", "smooth", "relaxed"),
        "relaxed" to listOf("chill", "calm", "laid-back"),
        "calm" to listOf("peaceful", "relaxed", "serene"),
        "happy" to listOf("joyful", "cheerful", "upbeat"),
        "upbeat" to listOf("happy", "energetic", "optimistic"),
        "optimistic" to listOf("hopeful", "uplifting", "positive"),
        "uplifting" to listOf("optimistic", "hopeful", "inspiring"),
        "sad" to listOf("melancholy", "sorrowful", "heartbroken"),
        "melancholy" to listOf("sad", "wistful", "pensive"),
        "dark" to listOf("brooding", "moody", "ominous"),
        "moody" to listOf("brooding", "dark", "atmospheric"),
        "energetic" to listOf("upbeat", "driving", "intense"),
        "romantic" to listOf("sensual", "loving", "tender"),
        "smooth" to listOf("silky", "mellow", "sensual"),
        "dreamy" to listOf("ethereal", "hazy", "atmospheric"),
        "groovy" to listOf("funky", "rhythmic", "danceable"),
        "angry" to listOf("aggressive", "intense", "defiant"),
        "nostalgic" to listOf("wistful", "sentimental", "reflective"),
        "party" to listOf("celebratory", "danceable", "fun"),
        "sexy" to listOf("sensual", "seductive", "smooth"),
        "soulful" to listOf("emotional", "heartfelt", "passionate"),
        "sunny" to listOf("cheerful", "warm", "carefree"),
        "focus" to listOf("calm", "steady", "instrumental"),
        "sleepy" to listOf("calm", "gentle", "dreamy"),
        "aggressive" to listOf("angry", "intense", "hard"),
    )

    /** Genre-keyword stems from [Genre] that read as ordinary English / moods in a brief, so are not genre hits. */
    private val AMBIGUOUS_GENRE_WORDS = setOf(
        "romantic", "conscious", "western", "urban", "outlaw", "world", "dance", "comedy", "poetry", "chamber",
        "arena", "heartland", "golden age", "fusion", "tens", "breaks", "dub", "novelty", "garage", "cut-up/dj",
    )

    private val STOPWORDS = setOf(
        "a", "an", "the", "of", "and", "or", "with", "from", "to", "in", "on", "for", "some", "me", "my", "i", "pocket",
        "playlist", "songs", "song", "music", "tracks", "track", "create", "make", "build", "new", "called", "that",
        "is", "are", "like", "about", "mix", "set", "please", "give", "minute", "minutes", "hour", "hours", "long",
        "early", "mid", "late", "vibes", "vibe", "stuff", "bunch", "pocketdj", "all", "only", "just",
    )

    fun parse(brief: String, vocab: PocketVocabulary = PocketVocabulary()): ParsedPocketBrief {
        var s = " " + brief.lowercase(Locale.ROOT)
            .replace('–', '-').replace('—', '-').replace('’', '\'').replace('‘', '\'') + " "
        s = s.replace(" r and b ", " r&b ")

        // 1. Length: "90 minutes", "an hour", "2 hours".
        var minutes: Int? = null
        LENGTH_RE.find(s)?.let { m ->
            val n = m.groupValues[1].toIntOrNull() ?: 1
            val unit = m.groupValues[2]
            minutes = (if (unit.startsWith("h")) n * 60 else n).coerceIn(5, 600)
            s = s.replaceRange(m.range, " ")
        }
        AN_HOUR_RE.find(s)?.let { m ->
            if (minutes == null) minutes = 60
            s = s.replaceRange(m.range, " ")
        }

        // 2. Years.
        val (range, afterYears) = parseYears(s)
        s = afterYears

        // 3. Genres (longest phrase first, at word boundaries).
        val genres = LinkedHashSet<String>()
        for (phrase in genrePhrases(vocab)) {
            val re = Regex("(?<![a-z0-9&])" + Regex.escape(phrase) + "(?![a-z0-9&])")
            if (re.containsMatchIn(s)) {
                genres += phrase
                s = re.replace(s, " ")
            }
        }
        // De-dupe overlapping hits ("hip hop" and "hip-hop" both present): keep distinct normalised forms.
        val seenNorm = HashSet<String>()
        val genreList = genres.filter { seenNorm.add(normalize(it)) }

        // 4. Moods: whole words from the built-ins + the catalog sentiment vocabulary.
        val moodVocab = MOOD_SYNONYMS.keys + vocab.moods.map { it.lowercase(Locale.ROOT).trim() }.filter { it.length >= 3 }
        val words = s.split(Regex("[^a-z0-9'&-]+")).filter { it.isNotEmpty() && it !in STOPWORDS }
        val moods = LinkedHashSet<String>()
        for (w in words) if (w in moodVocab) moods += w
        val expanded = LinkedHashSet<String>(moods)
        for (m in moods) MOOD_SYNONYMS[m]?.let { expanded.addAll(it) }

        return ParsedPocketBrief(
            moods = expanded.toList(),
            genres = genreList,
            yearFrom = range?.first,
            yearTo = range?.second,
            minutes = minutes,
        )
    }

    private val LENGTH_RE = Regex("""(\d{1,3})\s*[- ]?\s*(minutes?|mins?|hours?|hrs?)\b""")
    private val AN_HOUR_RE = Regex("""\b(an|one|a)\s+hour\b""")
    private val RANGE_RE = Regex("""\b(1[89]\d\d|20[0-2]\d)\s*(?:-|to|through|thru|until)\s*(1[89]\d\d|20[0-2]\d|\d\d)\b""")
    private val DECADE_RE = Regex("""\b(early|mid|late)?\s*'?(\d{2}|(?:1[89]|20)\d0)'?s\b""")
    private val DECADE_WORD_RE = Regex("""\b(early|mid|late)?\s*(${DECADE_WORDS.keys.joinToString("|")})\b""")
    private val YEAR_RE = Regex("""\b(1[89]\d\d|20[0-2]\d)\b""")

    internal fun parseYears(input: String): Pair<Pair<Int, Int>?, String> {
        var s = input
        val spans = ArrayList<IntRange>()
        var lo = Int.MAX_VALUE
        var hi = Int.MIN_VALUE
        fun add(a: Int, b: Int) { lo = minOf(lo, a); hi = maxOf(hi, b) }

        RANGE_RE.findAll(s).toList().forEach { m ->
            val a = m.groupValues[1].toInt()
            var b = m.groupValues[2].toInt()
            if (m.groupValues[2].length == 2) b += (a / 100) * 100
            add(minOf(a, b), maxOf(a, b))
            spans += m.range
        }
        s = blank(s, spans); spans.clear()

        DECADE_RE.findAll(s).toList().forEach { m ->
            val raw = m.groupValues[2]
            val start = if (raw.length == 4) raw.toInt() else {
                val two = raw.toInt()
                if (two % 10 != 0) return@forEach
                if (two >= 30) 1900 + two else 2000 + two
            }
            decadeSpan(start, m.groupValues[1]).let { add(it.first, it.second) }
            spans += m.range
        }
        s = blank(s, spans); spans.clear()

        DECADE_WORD_RE.findAll(s).toList().forEach { m ->
            val start = DECADE_WORDS[m.groupValues[2]] ?: return@forEach
            decadeSpan(start, m.groupValues[1]).let { add(it.first, it.second) }
            spans += m.range
        }
        s = blank(s, spans); spans.clear()

        YEAR_RE.findAll(s).toList().forEach { m ->
            val y = m.groupValues[1].toInt(); add(y, y); spans += m.range
        }
        s = blank(s, spans)
        return (if (lo <= hi) lo to hi else null) to s
    }

    private fun decadeSpan(start: Int, qualifier: String): Pair<Int, Int> = when (qualifier) {
        "early" -> start to start + 4
        "mid" -> start + 3 to start + 7
        "late" -> start + 5 to start + 9
        else -> start to start + 9
    }

    private fun blank(s: String, spans: List<IntRange>): String {
        var out = s
        for (r in spans.sortedByDescending { it.first }) out = out.replaceRange(r, " ")
        return out
    }

    private fun genrePhrases(vocab: PocketVocabulary): List<String> {
        val out = LinkedHashSet<String>()
        Genre.categories.forEach { (name, kws) ->
            out += name
            kws.forEach { if (it !in AMBIGUOUS_GENRE_WORDS && it.length >= 3 && it.none { c -> c == '/' }) out += it }
        }
        // Catalog genre strings, split on "/" "," and "&"-less separators so "Hip-Hop/Rap" yields both halves.
        vocab.genres.forEach { g ->
            g.lowercase(Locale.ROOT).split('/', ',', ';').map { it.trim() }
                .filter { it.length in 3..30 && it !in AMBIGUOUS_GENRE_WORDS }.forEach { out += it }
        }
        out += "hip hop"
        return out.sortedByDescending { it.length }
    }

    /** Lowercase, separators to single spaces: "Hip-Hop/Rap" == "hip hop rap". */
    fun normalize(s: String): String =
        s.lowercase(Locale.ROOT).replace(Regex("[-_/,]+"), " ").replace(Regex("\\s+"), " ").trim()
}

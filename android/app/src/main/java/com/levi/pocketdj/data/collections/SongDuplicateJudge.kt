package com.levi.pocketdj.data.collections

import java.text.Normalizer

/**
 * Deterministic "are these two songs the same recording?" judge — a faithful port of iOS
 * `SongDuplicateJudge` (tiers 1 + 1b; the on-device LLM tie-break has no Android analogue and
 * the borderline path falls back to "not a duplicate").
 *
 * TIGHT by doctrine: version markers ("Live", "Remix", parenthetical remaster tags) stay in the
 * title so different cuts never collapse. The same-release tier (2026-10-19) loosens title +
 * artist only within ONE album.
 */
object SongDuplicateJudge {

    /** The fields the same-release tier compares. [album] is the album NAME. */
    data class Identity(
        val name: String,
        val artist: String,
        val album: String? = null,
        val appleMusicId: String? = null,
    )

    private val quoteStrip = Regex("[’'\"“”\\[\\]{}]")
    private val ws = Regex("\\s+")
    // Only true diacritics (Foundation .diacriticInsensitive): NOT every Mn, so Japanese
    // dakuten and Indic vowel signs survive.
    private val combiningMarks = Regex("[\\u0300-\\u036F\\u1AB0-\\u1AFF\\u1DC0-\\u1DFF\\u20D0-\\u20FF\\uFE20-\\uFE2F]+")

    /** CharacterSet.alphanumerics analogue: any L*, M*, N* code point. */
    private fun isAlnum(cp: Int): Boolean = when (Character.getType(cp).toByte()) {
        Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
        Character.MODIFIER_LETTER, Character.OTHER_LETTER,
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK,
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }

    private fun keepAlnum(s: String, allowSpace: Boolean): String {
        val sb = StringBuilder()
        s.codePoints().forEach { cp ->
            if (isAlnum(cp) || (allowSpace && Character.isWhitespace(cp))) sb.appendCodePoint(cp)
        }
        return sb.toString()
    }

    /** casefold + diacritic fold, quotes/brackets stripped, whitespace collapsed. Parens stay. */
    fun normalized(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD)
            .replace(combiningMarks, "")
            .let { Normalizer.normalize(it, Normalizer.Form.NFC) }
            .lowercase()
            .replace(quoteStrip, "")
            .replace(ws, " ")
            .trim()

    /** One comparable identity key; songs sharing it are the same recording. */
    fun key(name: String, artist: String): String = normalized(name) + "\u0001" + normalized(artist)

    fun isExactDuplicate(name: String, artist: String, name2: String, artist2: String): Boolean =
        key(name, artist) == key(name2, artist2)

    /** Same title, differing artist strings — the zone iOS sends to its LLM. */
    fun isBorderline(name: String, artist: String, name2: String, artist2: String): Boolean =
        normalized(name) == normalized(name2) && normalized(artist) != normalized(artist2)

    private val featInTitle = Regex(
        """\s*[\(\[]\s*(?:feat|ft|featuring|with)\b[^\)\]]*[\)\]]|\s+(?:feat|ft|featuring)\b.*$""",
        RegexOption.IGNORE_CASE,
    )
    private val featCredit = Regex(
        """[\(\[]\s*(?:feat|ft|featuring|with)\b([^\)\]]*)|\s(?:feat|ft|featuring)\b(.*)$""",
        RegexOption.IGNORE_CASE,
    )
    private val artistSeparators = Regex(
        """\s*(?:,|&|\band\b|\bx\b|\bfeat\b|\bft\b|\bfeaturing\b|\bwith\b|/|\+)\s*""",
        RegexOption.IGNORE_CASE,
    )
    private val creditSeparators = Regex("""\s*(?:,|&|\band\b|\bx\b|/|\+)\s*""", RegexOption.IGNORE_CASE)

    /** `normalized` minus everything that isn't a letter, digit or space. Unicode-aware. */
    fun loose(s: String): String =
        normalized(s)
            .let { keepAlnum(it, true) }
            .replace(ws, " ")
            .trim()

    /** Title with its feat./ft./featuring/with credit removed, loosely normalized. */
    fun baseTitle(name: String): String = loose(name.replace(featInTitle, ""))

    private fun tokens(s: String, sep: Regex): Set<String> =
        normalized(s).replace(sep, "\u0001").split('\u0001')
            .map { part -> keepAlnum(part, false) }
            .filter { it.isNotEmpty() }
            .toSet()

    private fun featCreditText(name: String): String? {
        val m = featCredit.find(name) ?: return null
        for (g in 1..2) m.groups[g]?.let { return it.value }
        return null
    }

    /** Every credited artist — the artist field plus any feat. credit in the title. */
    fun artistTokens(name: String, artist: String): Set<String> {
        val all = tokens(artist, artistSeparators).toMutableSet()
        featCreditText(name)?.let { all += tokens(it, creditSeparators) }
        return all
    }

    /** The title's feat. credits alone (null = the title credits nobody). */
    fun featTokens(name: String): Set<String>? = featCreditText(name)?.let { tokens(it, creditSeparators) }

    /** Bucket key for the same-release tier; null = not comparable (no album or empty title). */
    fun releaseKey(s: Identity): String? {
        val album = s.album?.let(::loose)
        if (album.isNullOrEmpty()) return null
        val title = baseTitle(s.name)
        if (title.isEmpty()) return null
        return title + "\u0001" + album
    }

    fun isSameReleaseDuplicate(a: Identity, b: Identity): Boolean {
        val ka = releaseKey(a) ?: return false
        if (ka != releaseKey(b)) return false
        val ia = a.appleMusicId
        val ib = b.appleMusicId
        if (!ia.isNullOrEmpty() && !ib.isNullOrEmpty() && ia != ib) return false
        if (artistTokens(a.name, a.artist).intersect(artistTokens(b.name, b.artist)).isEmpty()) return false
        val fa = featTokens(a.name)
        val fb = featTokens(b.name)
        if (fa != null && fb != null && fa.isNotEmpty() && fb.isNotEmpty() && fa.intersect(fb).isEmpty()) return false
        return true
    }

    fun isDuplicate(a: Identity, b: Identity): Boolean =
        isExactDuplicate(a.name, a.artist, b.name, b.artist) || isSameReleaseDuplicate(a, b)

    /** Running "already have this recording?" set (exact key + same-release buckets). */
    class Seen {
        private val exact = HashSet<String>()
        private val buckets = HashMap<String, MutableList<Identity>>()

        /** true = new recording (remembered); false = duplicate of one already seen. */
        fun insert(s: Identity): Boolean {
            if (!exact.add(key(s.name, s.artist))) return false
            val rk = releaseKey(s) ?: return true
            val list = buckets.getOrPut(rk) { mutableListOf() }
            if (list.any { isSameReleaseDuplicate(it, s) }) return false
            list += s
            return true
        }
    }

    /**
     * `rename` maps a group's first id → its survivor (when they differ); `drop` is every other
     * member of a twin group.
     */
    data class CollapsePlan(
        val rename: Map<String, String> = emptyMap(),
        val drop: Set<String> = emptySet(),
    ) {
        val isEmpty: Boolean get() = drop.isEmpty()
    }

    /**
     * Each twin group keeps ONE id — the first member with an Apple Music id, else the first —
     * in the group's EARLIEST slot. Ids [identity] can't resolve are never touched; a repeated
     * SAME id is a deliberate repeat, not a twin.
     */
    fun collapsePlan(ids: List<String>, identity: (String) -> Identity?): CollapsePlan {
        val groups = mutableListOf<MutableList<String>>()
        val exactGroup = HashMap<String, Int>()
        val buckets = HashMap<String, MutableList<Pair<Identity, Int>>>()
        val seenIds = HashSet<String>()
        val identities = HashMap<String, Identity>()
        for (id in ids) {
            if (!seenIds.add(id)) continue
            val s = identity(id) ?: continue
            identities[id] = s
            val ek = key(s.name, s.artist)
            val rk = releaseKey(s)
            var g = exactGroup[ek]
            if (g == null && rk != null) {
                g = buckets[rk]?.firstOrNull { isSameReleaseDuplicate(it.first, s) }?.second
            }
            if (g != null) {
                groups[g].add(id)
                if (exactGroup[ek] == null) exactGroup[ek] = g
            } else {
                groups.add(mutableListOf(id))
                exactGroup[ek] = groups.size - 1
                if (rk != null) buckets.getOrPut(rk) { mutableListOf() }.add(s to groups.size - 1)
            }
        }
        val rename = LinkedHashMap<String, String>()
        val drop = LinkedHashSet<String>()
        for (g in groups) {
            if (g.size < 2) continue
            val survivor = g.firstOrNull { !identities[it]?.appleMusicId.isNullOrEmpty() } ?: g[0]
            if (survivor != g[0]) rename[g[0]] = survivor
            drop.addAll(g.drop(1))
        }
        return CollapsePlan(rename, drop)
    }
}

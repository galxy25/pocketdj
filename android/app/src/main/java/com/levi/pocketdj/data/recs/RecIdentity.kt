package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.edition.SongVariant
import java.text.Normalizer
import java.util.Locale

/**
 * Port of RecVersionIdentity / RecVersionIndex / RecRecordingIdentity / RecMembership.
 *
 * Doctrine (kept from iOS): unknown version markers fail OPEN (`DISTINCT`), so over-suppression
 * can never silently delete music; equal artist+title alone never suppresses (signature must
 * differ).
 */
object RecVersionIdentity {

    enum class VersionClass { STANDARD, COSMETIC, DERIVATIVE, DISTINCT }

    data class Key(
        val artistKey: String,
        val base: String,
        val signature: String,
        val klass: VersionClass,
    ) {
        val bucket: String get() = artistKey + "\u0001" + base
        val isDistinct: Boolean get() = klass == VersionClass.DISTINCT
        val isUsable: Boolean get() = artistKey.isNotEmpty() && base.isNotEmpty()
    }

    data class Parsed(val base: String, val signature: String, val klass: VersionClass)

    fun key(title: String, artist: String): Key? = keyWithArtistKey(title, artistKey(artist))

    /** For callers that already normalized the artist. */
    fun keyWithArtistKey(title: String, artistKey: String): Key? {
        if (artistKey.isEmpty()) return null
        val p = parse(title)
        if (p.base.isEmpty()) return null
        return Key(artistKey, p.base, p.signature, p.klass)
    }

    fun supersedes(candidate: Key, owned: Key): Boolean {
        if (!candidate.isUsable || !owned.isUsable) return false
        if (candidate.artistKey != owned.artistKey || candidate.base != owned.base) return false
        if (candidate.isDistinct || owned.isDistinct) return false
        return candidate.signature != owned.signature
    }

    fun isDifferentVersion(
        candidateTitle: String, candidateArtist: String, ownedTitle: String, ownedArtist: String,
    ): Boolean {
        val c = key(candidateTitle, candidateArtist) ?: return false
        val o = key(ownedTitle, ownedArtist) ?: return false
        return supersedes(c, o)
    }

    /** `pop star` -> `popstar`; null when the base has no spaces. Ownership relation only. */
    fun spacelessKey(k: Key): Key? {
        val squashed = k.base.replace(" ", "")
        if (squashed == k.base || squashed.isEmpty()) return null
        return k.copy(base = squashed)
    }

    private const val MAX_CREDIT_NAMES = 12
    private val creditSplitChars = setOf(',', ';', '/')
    private val creditSplitWords = listOf(" and ", " x ", " with ", " vs ", " versus ")

    /** artistKey for the whole credit plus one per name inside it. */
    fun creditArtistKeys(raw: String): List<String> {
        val out = ArrayList<String>()
        val seen = HashSet<String>()
        fun add(k: String) {
            if (k.isEmpty() || out.size >= MAX_CREDIT_NAMES || !seen.add(k)) return
            out.add(k)
        }
        val debracketed = debracket(raw)
        val sources = if (debracketed == raw) listOf(raw) else listOf(raw, debracketed)
        for (source in sources) {
            add(artistKey(source))
            val folded = stripCreditTail(stripParenGroups(fold(source)))
            val splits = folded.any { it in creditSplitChars } || creditSplitWords.any { folded.contains(it) }
            if (!splits) continue
            for (piece in splitCredit(folded)) add(artistKey(piece))
        }
        return out
    }

    /** artistKey, except a name written entirely inside brackets is not artist-less. */
    fun ownershipArtistKey(raw: String): String {
        val k = artistKey(raw)
        return if (k.isEmpty()) artistKey(debracket(raw)) else k
    }

    private fun debracket(s: String): String =
        String(CharArray(s.length) { if ("()[]{}".indexOf(s[it]) >= 0) ' ' else s[it] })

    private fun splitCredit(folded: String): List<String> {
        var pieces = folded.split(*creditSplitChars.toCharArray()).filter { it.isNotEmpty() }
        for (word in creditSplitWords) {
            pieces = pieces.flatMap { piece ->
                val padded = " $piece "
                if (!padded.contains(word)) listOf(piece) else padded.split(word)
            }
        }
        return pieces
    }

    /** Loose artist key (am-match normArtist). NOT IndexArtist.normalize. */
    fun artistKey(raw: String): String {
        var s = fold(raw)
        s = stripParenGroups(s)
        s = stripCreditTail(s)
        val t = tokens(s).joinToString(" ")
        if (t.startsWith("the ") && t.length > 4) return t.substring(4)
        return t
    }

    fun parse(rawTitle: String): Parsed {
        val folded = fold(rawTitle)
        var outer = StringBuilder()
        val groups = ArrayList<String>()
        var depth = 0
        var current = StringBuilder()
        for (ch in folded) {
            if (ch == '(' || ch == '[' || ch == '{') {
                if (depth == 0) current = StringBuilder() else current.append(ch)
                depth += 1
                continue
            }
            if (ch == ')' || ch == ']' || ch == '}') {
                if (depth > 0) {
                    depth -= 1
                    if (depth == 0) { groups.add(current.toString()); current = StringBuilder() } else current.append(ch)
                }
                continue
            }
            if (depth > 0) current.append(ch) else outer.append(ch)
        }
        if (depth > 0 && current.isNotEmpty()) groups.add(current.toString())

        var outerStr = outer.toString()
        val dash = splitDashSuffix(outerStr)
        if (dash != null && isFullyClassified(dash.second)) {
            outerStr = dash.first
            groups.add(dash.second)
        }
        outerStr = stripCreditTail(outerStr)
        val base = tokens(outerStr).joinToString(" ")

        var klass = VersionClass.STANDARD
        val sigTokens = ArrayList<String>()
        for (g in groups) {
            val toks = tokens(g)
            if (toks.isEmpty()) continue
            val c = classify(toks) ?: continue
            sigTokens.addAll(toks)
            if (c.ordinal > klass.ordinal) klass = c
        }
        val signature = sigTokens.sorted().joinToString(" ")
        if (signature.isEmpty()) klass = VersionClass.STANDARD
        return Parsed(base, signature, klass)
    }

    // ── word lists ──────────────────────────────────────────────────────────

    private val cosmetic: Set<String> = setOf(
        "remaster", "remastered", "remasters", "deluxe", "expanded", "anniversary",
        "edition", "bonus", "track", "mono", "stereo", "explicit", "clean", "original",
        "lp", "album", "version",
        "and", "the", "a", "an", "of", "feat", "featuring", "ft", "with",
        "ep", "cd", "disc", "disk", "vinyl", "box", "set", "reissue", "release", "released",
        "super", "ultimate", "complete", "special", "limited", "collectors", "collector",
        "standard", "extra", "plus", "digital", "digitally", "tracks", "editions",
        "japanese", "japan", "uk", "us", "usa", "international", "worldwide", "tour",
        "definitive", "essential", "legacy", "platinum", "gold", "silver",
    )

    private val derivative: Set<String> = setOf(
        "mix", "mixes", "mixed", "remix", "remixes", "remixed", "remixer",
        "edit", "edits", "edited", "extended", "radio", "single", "singles",
        "club", "dub", "inch", "rework", "reworked", "refix", "vip", "bootleg",
        "sped", "slowed", "reverb", "nightcore", "megamix", "mashup",
    )

    private val distinct: Set<String> = setOf(
        "live", "acoustic", "unplugged", "session", "sessions", "take", "takes",
        "demo", "demos", "rehearsal", "soundcheck", "concert",
        "instrumental", "instrumentals", "acapella", "acappella", "cappella",
        "karaoke", "cover", "covers", "reprise", "interlude", "skit",
        "orchestral", "symphonic", "choir", "remake", "rerecorded", "rerecording",
    )

    private val creditWords: Set<String> = setOf("feat", "featuring", "ft", "with")

    private val partDesignators: Set<String> = setOf(
        "disc", "disk", "cd", "volume", "vol", "part", "pt", "side", "chapter", "act",
    )

    /** null => pure credit group, not version material. */
    private fun classify(toks: List<String>): VersionClass? {
        val joined = toks.joinToString(" ")
        if (joined == "original mix" || joined == "original version" || joined == "original recording") {
            return VersionClass.COSMETIC
        }
        if (toks.first() in creditWords) return null
        var head = toks
        val idx = toks.indexOfFirst { it in creditWords }
        if (idx >= 0) {
            head = toks.subList(0, idx)
            if (head.isEmpty()) return null
        }
        if (head.any { it in partDesignators } && head.any { isNumeric(it) || romanOrWordNumber(it) }) {
            return VersionClass.DISTINCT
        }
        if (head.any { it in distinct }) return VersionClass.DISTINCT
        if (head.any { it in derivative }) return VersionClass.DERIVATIVE
        if (head.all { it in cosmetic || isNumeric(it) }) return VersionClass.COSMETIC
        return VersionClass.DISTINCT
    }

    private fun isFullyClassified(text: String): Boolean {
        val toks = tokens(text)
        if (toks.isEmpty()) return false
        return toks.all {
            it in cosmetic || it in derivative || it in distinct || it in creditWords || isNumeric(it)
        }
    }

    // ── text plumbing ───────────────────────────────────────────────────────

    private val inchRegex = Regex("""\b(7|12)\s*(?:"|''|-?\s*inch)""")

    internal fun fold(s: String): String {
        var ascii = true
        for (c in s) if (c.code >= 128) { ascii = false; break }
        var t = if (ascii) {
            val sb = StringBuilder(s.length)
            for (c in s) sb.append(if (c in 'A'..'Z') c + 32 else c)
            sb.toString()
        } else {
            stripDiacritics(Normalizer.normalize(s, Normalizer.Form.NFD)).lowercase(Locale.ROOT).replace("ß", "ss")
        }
        if (t.indexOf('&') >= 0) t = t.replace("&", " and ")
        if (t.indexOf('"') >= 0 || t.contains("''") || t.contains("inch")) {
            t = inchRegex.replace(t, " inch ")
        }
        return t
    }

    /** Drop combining marks only after Latin/Greek/Cyrillic bases (accents), keeping Indic vowel signs etc. */
    private fun stripDiacritics(nfd: String): String {
        val sb = StringBuilder(nfd.length)
        var base: Character.UnicodeScript? = null
        var i = 0
        while (i < nfd.length) {
            val cp = nfd.codePointAt(i)
            i += Character.charCount(cp)
            val t = Character.getType(cp)
            val isMark = t == Character.NON_SPACING_MARK.toInt() || t == Character.COMBINING_SPACING_MARK.toInt() ||
                t == Character.ENCLOSING_MARK.toInt()
            if (isMark) {
                if (base == Character.UnicodeScript.LATIN || base == Character.UnicodeScript.GREEK ||
                    base == Character.UnicodeScript.CYRILLIC) continue
            } else {
                base = Character.UnicodeScript.of(cp)
            }
            sb.appendCodePoint(cp)
        }
        return sb.toString()
    }

    private fun splitDashSuffix(s: String): Pair<String, String>? {
        val i = s.lastIndexOf(" - ")
        if (i < 0) return null
        val head = s.substring(0, i)
        val tail = s.substring(i + 3)
        if (head.trim().isEmpty() || tail.trim().isEmpty()) return null
        return head to tail
    }

    private fun stripParenGroups(s: String): String {
        val out = StringBuilder()
        var depth = 0
        for (ch in s) {
            if (ch == '(' || ch == '[' || ch == '{') { depth += 1; continue }
            if (ch == ')' || ch == ']' || ch == '}') { if (depth > 0) depth -= 1; continue }
            if (depth == 0) out.append(ch)
        }
        return out.toString()
    }

    private fun stripCreditTail(s: String): String {
        val toks = tokens(s)
        val idx = toks.indexOfFirst { it in creditWords && it != "with" }
        if (idx < 0) return s
        if (idx <= 0) return s
        return toks.subList(0, idx).joinToString(" ")
    }

    internal fun tokens(s: String): List<String> {
        val out = ArrayList<String>()
        val cur = StringBuilder()
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            i += Character.charCount(cp)
            if (isWordScalar(cp)) cur.appendCodePoint(cp)
            else if (cur.isNotEmpty()) { out.add(cur.toString()); cur.setLength(0) }
        }
        if (cur.isNotEmpty()) out.add(cur.toString())
        return out
    }

    private fun isWordScalar(cp: Int): Boolean {
        if (cp < 128) return (cp in 97..122) || (cp in 48..57) || (cp in 65..90)
        if (Character.isLetterOrDigit(cp)) return true
        val t = Character.getType(cp)
        // Combining marks that survive fold() (non-Latin/Greek/Cyrillic) are part of the word.
        return t == Character.LETTER_NUMBER.toInt() || t == Character.OTHER_NUMBER.toInt() ||
            t == Character.NON_SPACING_MARK.toInt() || t == Character.COMBINING_SPACING_MARK.toInt()
    }

    private fun isNumeric(t: String): Boolean {
        val digits = t.takeWhile { Character.isDigit(it) || Character.getType(it) == Character.LETTER_NUMBER.toInt() || Character.getType(it) == Character.OTHER_NUMBER.toInt() }
        if (digits.isEmpty()) return false
        val rest = t.substring(digits.length)
        return rest.isEmpty() || rest in setOf("st", "nd", "rd", "th")
    }

    private fun romanOrWordNumber(t: String): Boolean = when (t) {
        "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" -> true
        else -> false
    }
}

/** What he already has, in version space. */
class RecVersionIndex(owned: Iterable<RecVersionIdentity.Key> = emptyList()) {
    private val byBucket: Map<String, Set<String>>
    private val distinctExact: Set<String>

    init {
        val m = HashMap<String, MutableSet<String>>()
        val d = HashSet<String>()
        for (k in owned) {
            if (!k.isUsable) continue
            if (k.isDistinct) d.add(k.bucket + "\u0001" + k.signature)
            else m.getOrPut(k.bucket) { HashSet() }.add(k.signature)
        }
        byBucket = m
        distinctExact = d
    }

    /** Nothing here can supersede anything (distinct-only indexes count as empty). */
    val isEmpty: Boolean get() = byBucket.isEmpty()

    fun supersedes(candidate: RecVersionIdentity.Key): Boolean {
        if (!candidate.isUsable || candidate.isDistinct) return false
        val owned = byBucket[candidate.bucket] ?: return false
        return owned.any { it != candidate.signature }
    }

    fun supersedes(title: String, artist: String): Boolean {
        if (byBucket.isEmpty()) return false
        val k = RecVersionIdentity.key(title, artist) ?: return false
        return supersedes(k)
    }

    /** Does he already have this record at all, regardless of edition? */
    fun hasRecord(candidate: RecVersionIdentity.Key): Boolean {
        if (!candidate.isUsable) return false
        if (candidate.isDistinct) {
            if (distinctExact.contains(candidate.bucket + "\u0001" + candidate.signature)) return true
            val sp = RecVersionIdentity.spacelessKey(candidate) ?: return false
            return distinctExact.contains(sp.bucket + "\u0001" + sp.signature)
        }
        if (byBucket.containsKey(candidate.bucket)) return true
        val squashed = RecVersionIdentity.spacelessKey(candidate) ?: return false
        return byBucket.containsKey(squashed.bucket)
    }

    fun hasRecord(title: String, artist: String): Boolean {
        if (byBucket.isEmpty() && distinctExact.isEmpty()) return false
        val k = RecVersionIdentity.keyWithArtistKey(title, RecVersionIdentity.ownershipArtistKey(artist)) ?: return false
        return hasRecord(k)
    }

    companion object {
        val EMPTY = RecVersionIndex()
    }
}

object RecRecordingIdentity {
    private const val RECORDING_PREFIX = "rec:"
    const val DURATION_TOLERANCE_MS = 5_000

    /** artist + base + (signature only for derivative/distinct). */
    fun recordingKey(v: RecVersionIdentity.Key?): String? {
        if (v == null || !v.isUsable) return null
        val sig = when (v.klass) {
            RecVersionIdentity.VersionClass.STANDARD, RecVersionIdentity.VersionClass.COSMETIC -> ""
            else -> v.signature
        }
        return RECORDING_PREFIX + v.artistKey + "\u0001" + v.base + "\u0001" + sig
    }

    data class Identity(
        val baseId: String,
        val adHocStoreKey: String? = null,
        val resolvedStoreKey: String? = null,
        val recordingKey: String? = null,
        val lengthMs: Int? = null,
    ) {
        val storeKeys: List<String> get() = listOfNotNull(adHocStoreKey, resolvedStoreKey)
    }

    fun identity(
        songId: String,
        appleMusicId: String? = null,
        version: RecVersionIdentity.Key? = null,
        lengthMs: Int? = null,
    ): Identity {
        val adHoc = RecMembership.adHocStoreId(songId)?.let { RecMembership.storeKey(it) }
        var resolved = appleMusicId?.let { RecMembership.validStoreKey(it) }
        if (resolved == adHoc) resolved = null
        return Identity(
            baseId = SongVariant.baseId(songId),
            adHocStoreKey = adHoc,
            resolvedStoreKey = resolved,
            recordingKey = recordingKey(version),
            lengthMs = if ((lengthMs ?: 0) > 0) lengthMs else null,
        )
    }

    fun identityKeys(
        songId: String, appleMusicId: String? = null, version: RecVersionIdentity.Key? = null,
    ): List<String> {
        val id = identity(songId, appleMusicId, version)
        return listOf(id.baseId) + id.storeKeys + listOfNotNull(id.recordingKey)
    }

    fun resolvesToStreamableAudio(appleMusicId: String?): Boolean =
        appleMusicId != null && RecMembership.validStoreKey(appleMusicId) != null

    data class Candidate(
        val id: String,
        val identity: Identity,
        val tier: Int = 0,
        val score: Double = 0.0,
        val playable: Boolean = false,
    )

    /** Union-find collapse; `true` = keep. Strong id, then recording key + duration, then store id. */
    fun keepMask(candidates: List<Candidate>): List<Boolean> {
        val n = candidates.size
        if (n <= 1) return List(n) { true }
        val parent = IntArray(n) { it }
        fun find(x: Int): Int {
            var root = x
            while (parent[root] != root) root = parent[root]
            var i = x
            while (parent[i] != i) { val next = parent[i]; parent[i] = root; i = next }
            return root
        }
        val groupRec = Array<String?>(n) { candidates[it].identity.recordingKey }
        val groupRecMixed = BooleanArray(n)
        val groupLo = Array<Int?>(n) { candidates[it].identity.lengthMs }
        val groupHi = groupLo.copyOf()

        fun durationsContradict(a: Int, b: Int): Boolean {
            val aLo = groupLo[a]; val aHi = groupHi[a]; val bLo = groupLo[b]; val bHi = groupHi[b]
            if (aLo == null || aHi == null || bLo == null || bHi == null) return false
            return aLo - bHi > DURATION_TOLERANCE_MS || bLo - aHi > DURATION_TOLERANCE_MS
        }
        fun recordingsContradict(a: Int, b: Int): Boolean {
            val x = groupRec[a]; val y = groupRec[b]
            if (x == null || y == null || groupRecMixed[a] || groupRecMixed[b]) return false
            return x != y
        }
        fun fuse(i: Int, j: Int) {
            val a = find(i); val b = find(j)
            if (a == b) return
            val x = groupRec[a]; val y = groupRec[b]
            var mixed = groupRecMixed[a] || groupRecMixed[b]
            val rec: String? = when {
                x != null && y != null -> { if (x != y) mixed = true; x }
                x != null -> x
                else -> y
            }
            val lo = listOfNotNull(groupLo[a], groupLo[b]).minOrNull()
            val hi = listOfNotNull(groupHi[a], groupHi[b]).maxOrNull()
            val root = minOf(a, b); val merged = maxOf(a, b)
            parent[merged] = root
            groupRec[root] = rec
            groupRecMixed[root] = mixed
            groupLo[root] = lo
            groupHi[root] = hi
        }

        val byBaseId = HashMap<String, Int>()
        for ((i, c) in candidates.withIndex()) {
            val j = byBaseId[c.identity.baseId]
            if (j != null) fuse(i, j) else byBaseId[c.identity.baseId] = i
        }

        val byRecording = HashMap<String, Int>()
        for ((i, c) in candidates.withIndex()) {
            val key = c.identity.recordingKey ?: continue
            val j = byRecording[key]
            if (j == null) { byRecording[key] = i; continue }
            val a = find(i); val b = find(j)
            if (a == b || durationsContradict(a, b)) continue
            fuse(a, b)
        }

        val byStore = HashMap<String, Pair<Int, Boolean>>()
        for ((i, c) in candidates.withIndex()) {
            for ((key, owned) in listOf(c.identity.adHocStoreKey to true, c.identity.resolvedStoreKey to false)) {
                if (key == null) continue
                val prior = byStore[key]
                if (prior == null) { byStore[key] = i to owned; continue }
                val a = find(i); val b = find(prior.first)
                if (a == b || durationsContradict(a, b)) continue
                if (!(owned || prior.second || !recordingsContradict(a, b))) continue
                fuse(a, b)
            }
        }

        val best = HashMap<Int, Int>()
        for (i in 0 until n) {
            val root = find(i)
            val b = best[root]
            if (b == null) best[root] = i
            else if (prefers(candidates[i], candidates[b])) best[root] = i
        }
        return List(n) { best[find(it)] == it }
    }

    private fun prefers(a: Candidate, b: Candidate): Boolean {
        if (a.tier != b.tier) return a.tier > b.tier
        if (a.playable != b.playable) return a.playable
        if (a.score != b.score) return a.score > b.score
        return a.id < b.id
    }
}

class RecMembership private constructor(
    private val keys: Set<String>,
    private val versions: RecVersionIndex,
) {
    data class TitleArtist(val title: String, val artist: String)

    constructor(
        memberIds: Iterable<String>,
        appleMusicId: (String) -> String? = { null },
        titleArtist: (String) -> TitleArtist? = { null },
    ) : this(build(memberIds, appleMusicId, titleArtist))

    private constructor(p: Pair<Set<String>, RecVersionIndex>) : this(p.first, p.second)

    val isEmpty: Boolean get() = keys.isEmpty() && versions.isEmpty

    fun containsOtherVersion(title: String, artist: String): Boolean = versions.supersedes(title, artist)

    fun contains(
        songId: String, appleMusicId: String? = null, version: RecVersionIdentity.Key? = null,
    ): Boolean = identityKeys(songId, appleMusicId, version).any { it in keys }

    fun excluding(
        ids: List<String>,
        appleMusicId: (String) -> String? = { null },
        titleArtist: (String) -> TitleArtist? = { null },
    ): List<String> {
        if (isEmpty) return ids
        return ids.filter { id ->
            val vk = titleArtist(id)?.let { RecVersionIdentity.key(it.title, it.artist) }
            if (contains(id, appleMusicId(id), vk)) return@filter false
            if (!versions.isEmpty && vk != null && versions.supersedes(vk)) return@filter false
            true
        }
    }

    companion object {
        val EMPTY = RecMembership(emptySet(), RecVersionIndex.EMPTY)

        private fun build(
            memberIds: Iterable<String>,
            appleMusicId: (String) -> String?,
            titleArtist: (String) -> TitleArtist?,
        ): Pair<Set<String>, RecVersionIndex> {
            val keys = HashSet<String>()
            val vks = ArrayList<RecVersionIdentity.Key>()
            for (id in memberIds) {
                val vk = titleArtist(id)?.let { RecVersionIdentity.key(it.title, it.artist) }
                keys.addAll(identityKeys(id, appleMusicId(id), vk))
                if (vk != null) vks.add(vk)
            }
            return keys to RecVersionIndex(vks)
        }

        fun identityKeys(
            songId: String, appleMusicId: String? = null, version: RecVersionIdentity.Key? = null,
        ): List<String> = RecRecordingIdentity.identityKeys(songId, appleMusicId, version)

        /** `amrec_<digits>` -> digits. */
        fun adHocStoreId(songId: String): String? {
            if (!songId.startsWith("amrec_")) return null
            val raw = songId.substring("amrec_".length)
            return if (raw.isNotEmpty() && raw.all { it.isDigit() }) raw else null
        }

        fun storeKey(storeId: String): String = "am:$storeId"

        /** >=4 digits, not all zeros. */
        fun validStoreKey(raw: String): String? {
            if (raw.length < 4 || !raw.all { it.isDigit() } || raw.all { it == '0' }) return null
            return storeKey(raw)
        }
    }
}

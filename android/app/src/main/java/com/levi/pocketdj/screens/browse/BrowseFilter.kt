package com.levi.pocketdj.screens.browse

import java.util.Locale
import java.util.UUID

/**
 * Filter model — a faithful port of iOS `Browse/BrowseModel.swift`
 * (`Fields` · `Clause` · `FilterEngine`, lines 108-300). Pure: no Android, no
 * Compose, so the whole engine is JVM-testable.
 */

enum class FieldKind { STRING, NUMBER, BOOL, STRING_ARRAY }

/** The five filter operators; [id] is the wire string shared with iOS. */
enum class FilterOp(val id: String, val label: String) {
    EQ("eq", "is"),
    NEQ("neq", "is not"),
    IN_LIST("inList", "any of"),
    NOT_IN_LIST("notInList", "none of"),
    BETWEEN("between", "between");

    companion object {
        val byId: Map<String, FilterOp> = entries.associateBy { it.id }
    }
}

/** One typed value pulled from a row for a field. */
sealed interface FieldValue {
    data class Str(val v: String) : FieldValue
    data class Num(val v: Double) : FieldValue
    data class Flag(val v: Boolean) : FieldValue
    data class Strs(val v: List<String>) : FieldValue
    data object None : FieldValue
}

data class Field(
    val id: String,
    val label: String,
    val kind: FieldKind,
    val numeric: Boolean,
    val sortable: Boolean,
    val appliesTo: Set<BrowseKind>,
    val ops: List<FilterOp>,
    /** Closed value set drives a multi-select instead of free text. */
    val hasOptions: Boolean,
    /** Only meaningful in History mode (Last played); hidden from the Browser sheets. */
    val historyOnly: Boolean = false,
)

object Fields {
    private val A = BrowseKind.ALBUMS
    private val S = BrowseKind.SONGS
    private val R = BrowseKind.ARTISTS

    private val strOps = listOf(FilterOp.EQ, FilterOp.NEQ, FilterOp.IN_LIST)
    private val numOps = listOf(FilterOp.EQ, FilterOp.NEQ, FilterOp.IN_LIST, FilterOp.BETWEEN)
    private val countOps = listOf(FilterOp.EQ, FilterOp.NEQ, FilterOp.BETWEEN)

    /**
     * Registry order IS the order of the sort/filter sheets — identical to iOS
     * `Fields.all` (playCount deliberately placed high, lastPlayedAt history-only).
     */
    val all: List<Field> = listOf(
        Field("artist", "Artist", FieldKind.STRING, false, true, setOf(A, S, R), strOps, false),
        Field("albumCount", "Albums", FieldKind.NUMBER, true, true, setOf(R), countOps, false),
        Field("songCount", "Songs", FieldKind.NUMBER, true, true, setOf(R), countOps, false),
        Field("name", "Title", FieldKind.STRING, false, true, setOf(A, S), strOps, false),
        Field("year", "Year", FieldKind.NUMBER, true, true, setOf(A, S), numOps, false),
        Field("playCount", "Plays", FieldKind.NUMBER, true, true, setOf(S), listOf(FilterOp.BETWEEN), false),
        Field(
            "genre", "Genre", FieldKind.STRING, false, true, setOf(A, S),
            listOf(FilterOp.EQ, FilterOp.NEQ, FilterOp.IN_LIST, FilterOp.NOT_IN_LIST), true,
        ),
        Field("fileType", "File type", FieldKind.STRING, false, true, setOf(A, S), strOps, true),
        Field("source", "Source", FieldKind.STRING, false, true, setOf(A, S), strOps, true),
        Field("country", "Country", FieldKind.STRING, false, true, setOf(A), strOps, true),
        Field("trackCount", "Track count", FieldKind.NUMBER, true, true, setOf(A), numOps, false),
        Field("trackNumber", "Track #", FieldKind.NUMBER, true, true, setOf(S), numOps, false),
        Field("length", "Length", FieldKind.NUMBER, true, true, setOf(S), numOps, false),
        Field("bpm", "BPM", FieldKind.NUMBER, true, true, setOf(S), numOps, false),
        Field("key", "Key", FieldKind.STRING, false, true, setOf(S), strOps, true),
        Field("camelot", "Key (Camelot)", FieldKind.STRING, false, true, setOf(S), strOps, true),
        Field("explicit", "Explicit", FieldKind.BOOL, false, true, setOf(S), listOf(FilterOp.EQ), false),
        Field(
            "sentiment", "Sentiment", FieldKind.STRING_ARRAY, false, false, setOf(S),
            listOf(FilterOp.IN_LIST, FilterOp.EQ, FilterOp.NEQ), true,
        ),
        Field("dateAdded", "Date added", FieldKind.NUMBER, true, true, setOf(S), listOf(FilterOp.BETWEEN), false),
        Field(
            "lastPlayedAt", "Last played", FieldKind.NUMBER, true, true, setOf(S),
            listOf(FilterOp.BETWEEN), false, historyOnly = true,
        ),
    )

    val byId: Map<String, Field> = all.associateBy { it.id }

    /** Fields for a kind; History includes the history-only ones, Browser does not. */
    fun forKind(kind: BrowseKind, includeHistory: Boolean = false): List<Field> =
        all.filter { kind in it.appliesTo && (includeHistory || !it.historyOnly) }

    /**
     * Value extractor — a field that doesn't exist on the row's kind reads
     * [FieldValue.None]. `playCounts` is the one value living outside the row
     * (a device-local store), threaded in as a plain snapshot map.
     */
    fun value(row: BrowseRow, fieldId: String, playCounts: Map<String, Int> = emptyMap()): FieldValue {
        if (fieldId == "source") return row.source?.let { FieldValue.Str(it) } ?: FieldValue.None
        if (fieldId == "playCount") {
            val n = (row as? SongRow)?.let { playCounts[it.song.id] }
            return if (n != null && n > 0) FieldValue.Num(n.toDouble()) else FieldValue.None
        }
        return when (row) {
            is AlbumRow -> {
                val a = row.album
                when (fieldId) {
                    "artist" -> FieldValue.Str(a.artist)
                    "name" -> FieldValue.Str(a.name)
                    "year" -> num(a.year)
                    "genre" -> FieldValue.Str(row.genreCategory)
                    "fileType" -> str(a.fileType)
                    "country" -> str(a.country)
                    "trackCount" -> FieldValue.Num(a.trackList.size.toDouble())
                    else -> FieldValue.None
                }
            }
            is SongRow -> {
                val s = row.song
                when (fieldId) {
                    "artist" -> FieldValue.Str(s.artist)
                    "name" -> FieldValue.Str(s.name)
                    "year" -> num(s.year)
                    "genre" -> FieldValue.Str(row.genreCategory)
                    "fileType" -> str(s.fileType)
                    "trackNumber" -> num(s.trackNumber)
                    "length" -> s.length?.let { FieldValue.Num(it.toDouble()) } ?: FieldValue.None
                    "bpm" -> s.bpm?.let { FieldValue.Num(it) } ?: FieldValue.None
                    "key" -> str(s.key)
                    "camelot" -> str(s.camelot)
                    "explicit" -> FieldValue.Flag(s.explicit ?: false)
                    "sentiment" -> FieldValue.Strs(s.sentimentKeywords.orEmpty())
                    "dateAdded" -> row.dateAdded?.let { FieldValue.Num(it) } ?: FieldValue.None
                    "lastPlayedAt" -> row.playedAt?.let { FieldValue.Num(it) } ?: FieldValue.None
                    else -> FieldValue.None
                }
            }
            is ArtistRow -> when (fieldId) {
                "artist", "name" -> FieldValue.Str(row.artist.name)
                "albumCount" -> FieldValue.Num(row.artist.albumCount.toDouble())
                "songCount" -> FieldValue.Num(row.artist.songCount.toDouble())
                else -> FieldValue.None
            }
        }
    }

    private fun str(v: String?): FieldValue = v?.let { FieldValue.Str(it) } ?: FieldValue.None
    private fun num(v: Int?): FieldValue = v?.let { FieldValue.Num(it.toDouble()) } ?: FieldValue.None
}

/**
 * One filter clause. [id] is UI identity only — it never enters the results
 * memo key (two logically identical clauses must share a cache entry).
 */
data class Clause(
    val field: String,
    val op: FilterOp,
    val value: String = "",
    val values: Set<String> = emptySet(),
    val min: Double? = null,
    val max: Double? = null,
    val id: String = UUID.randomUUID().toString(),
) {
    val isIncomplete: Boolean
        get() = when (op) {
            FilterOp.EQ, FilterOp.NEQ -> value.isEmpty() && values.isEmpty()
            FilterOp.IN_LIST, FilterOp.NOT_IN_LIST -> values.isEmpty()
            FilterOp.BETWEEN -> min == null && max == null
        }
}

object FilterEngine {
    private fun norm(s: String): String = s.trim { it.isWhitespace() && it != '\n' && it != '\r' }.lowercase(Locale.ROOT)

    fun matches(row: BrowseRow, c: Clause, playCounts: Map<String, Int> = emptyMap()): Boolean {
        val field = Fields.byId[c.field] ?: return true
        if (c.isIncomplete) return true
        if (row.browseKind !in field.appliesTo) return true
        val raw = Fields.value(row, c.field, playCounts)

        when (field.kind) {
            FieldKind.STRING_ARRAY -> {
                val arr = (raw as? FieldValue.Strs)?.v?.map(::norm).orEmpty()
                return when (c.op) {
                    FilterOp.IN_LIST -> c.values.isEmpty() || c.values.map(::norm).any { it in arr }
                    FilterOp.EQ -> norm(c.value) in arr
                    FilterOp.NEQ -> norm(c.value) !in arr
                    else -> true
                }
            }
            FieldKind.BOOL -> {
                val b = (raw as? FieldValue.Flag)?.v ?: false
                return if (c.op == FilterOp.EQ) b == (c.value == "true") else true
            }
            FieldKind.NUMBER -> {
                val n = (raw as? FieldValue.Num)?.v
                return when (c.op) {
                    FilterOp.EQ -> n != null && n == c.value.toDoubleOrNull()
                    // not-equal keeps rows with no value
                    FilterOp.NEQ -> n == null || n != c.value.toDoubleOrNull()
                    FilterOp.IN_LIST -> n != null && c.values.mapNotNull(String::toDoubleOrNull).contains(n)
                    FilterOp.NOT_IN_LIST -> n == null || !c.values.mapNotNull(String::toDoubleOrNull).contains(n)
                    FilterOp.BETWEEN -> {
                        if (n == null) false
                        else n >= (c.min ?: Double.NEGATIVE_INFINITY) && n <= (c.max ?: Double.POSITIVE_INFINITY)
                    }
                }
            }
            FieldKind.STRING -> {
                val ns = norm((raw as? FieldValue.Str)?.v.orEmpty())
                return when (c.op) {
                    FilterOp.EQ -> ns == norm(c.value)
                    FilterOp.NEQ -> ns != norm(c.value)
                    FilterOp.IN_LIST -> c.values.map(::norm).contains(ns)
                    // none-of keeps an empty value (symmetric with NEQ)
                    FilterOp.NOT_IN_LIST -> !c.values.map(::norm).contains(ns)
                    FilterOp.BETWEEN -> true
                }
            }
        }
    }

    /** AND-compose every clause; no clauses → the input list untouched. */
    fun <T : BrowseRow> apply(
        rows: List<T>,
        clauses: List<Clause>,
        playCounts: Map<String, Int> = emptyMap(),
    ): List<T> {
        val active = clauses.filter { !it.isIncomplete && Fields.byId.containsKey(it.field) }
        if (active.isEmpty()) return rows
        return rows.filter { row -> active.all { matches(row, it, playCounts) } }
    }
}

/** Distinct values present for an options-backed field (drives "any of" pickers). */
object FieldOptions {
    fun of(
        fieldId: String,
        rows: List<BrowseRow>,
        availableSources: List<String>,
    ): List<String> {
        // Source options come from the catalog's distinct sources (first-seen order).
        if (fieldId == "source") return availableSources
        val set = LinkedHashSet<String>()
        for (row in rows) {
            when (val v = Fields.value(row, fieldId)) {
                is FieldValue.Str -> if (v.v.isNotEmpty()) set.add(v.v)
                is FieldValue.Strs -> v.v.forEach { if (it.isNotEmpty()) set.add(it) }
                else -> Unit
            }
        }
        val list = set.toList()
        return when (fieldId) {
            "camelot" -> list.sortedBy { Camelot.rank(it) ?: 99 }
            "genre" -> list.sortedBy { Genre.order(it) }
            else -> list.sortedWith(String.CASE_INSENSITIVE_ORDER)
        }
    }
}

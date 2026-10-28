package com.levi.pocketdj.screens.browse

/**
 * Multi-key browse sort — ported from iOS `Browse/BrowseModel.swift:283-351`
 * (specs/browse.md §6.4). Stable (input index is the final tiebreak), nulls last
 * regardless of direction (null = a missing value OR an empty string), camelot
 * sorts by wheel rank as a number, strings compare case-insensitively, bools
 * false < true. No keys → catalog order (albums arrive artist › title already).
 */

/**
 * A sortable field from the registry (§6.1). Entry order mirrors [Fields.all]
 * (iOS `Fields.all`), so [forKind] and the "Add key" list match; applicability
 * is read from the registry so there is one source of truth.
 */
enum class SortField(val id: String, val label: String) {
    ARTIST("artist", "Artist"),
    ALBUM_COUNT("albumCount", "Albums"),
    SONG_COUNT("songCount", "Songs"),
    NAME("name", "Title"),
    YEAR("year", "Year"),
    PLAY_COUNT("playCount", "Plays"),
    GENRE("genre", "Genre"),
    FILE_TYPE("fileType", "File type"),
    SOURCE("source", "Source"),
    COUNTRY("country", "Country"),
    TRACK_COUNT("trackCount", "Track count"),
    TRACK_NUMBER("trackNumber", "Track #"),
    LENGTH("length", "Length"),
    BPM("bpm", "BPM"),
    KEY("key", "Key"),
    CAMELOT("camelot", "Key (Camelot)"),
    EXPLICIT("explicit", "Explicit"),
    DATE_ADDED("dateAdded", "Date added"),
    LAST_PLAYED_AT("lastPlayedAt", "Last played");

    val kinds: Set<BrowseKind> get() = Fields.byId.getValue(id).appliesTo
    val historyOnly: Boolean get() = Fields.byId.getValue(id).historyOnly

    /**
     * Sort value for any row — `null` when the field doesn't exist on the row's
     * kind or is missing (nulls last). Camelot sorts by wheel rank as a number
     * (unparseable → null); a missing `explicit` reads as false (a Flag, never
     * null). Genre sorts ALPHABETICALLY on the collapsed category.
     */
    fun value(row: BrowseRow, playCounts: Map<String, Int> = emptyMap()): SortVal? {
        val raw = Fields.value(row, id, playCounts)
        if (this == CAMELOT) {
            val code = (raw as? FieldValue.Str)?.v
            return Camelot.rank(code)?.let { SortVal.Num(it.toDouble()) }
        }
        return when (raw) {
            is FieldValue.Str -> SortVal.Str(raw.v)
            is FieldValue.Num -> SortVal.Num(raw.v)
            is FieldValue.Flag -> SortVal.Flag(raw.v)
            is FieldValue.Strs, FieldValue.None -> null
        }
    }

    companion object {
        val byId: Map<String, SortField> = entries.associateBy { it.id }

        /** Sortable fields for a kind, in registry order (drives the sort sheet). */
        fun forKind(kind: BrowseKind, includeHistory: Boolean = false): List<SortField> =
            entries.filter {
                kind in it.kinds && (includeHistory || !it.historyOnly)
            }
        // DATE_ADDED is offered (COL-13): BrowseRows / collection rows carry IndexSong.dateAdded;
        // songs without one sort last in either direction.
    }
}

/** One typed sort value; the comparison type is homogeneous per field. */
sealed interface SortVal {
    data class Num(val v: Double) : SortVal
    data class Str(val v: String) : SortVal
    data class Flag(val v: Boolean) : SortVal
}

/** A single sort key: a field and a direction (primary key first in the list). */
data class SortKey(val field: SortField, val ascending: Boolean = true)

/** The multi-key stable sort (§6.4). Public entry points per kind below. */
object BrowseSort {

    fun albums(rows: List<AlbumRow>, keys: List<SortKey>): List<AlbumRow> = sorted(rows, keys)

    fun songs(
        rows: List<SongRow>,
        keys: List<SortKey>,
        playCounts: Map<String, Int> = emptyMap(),
    ): List<SongRow> = sorted(rows, keys, playCounts)

    fun artists(rows: List<ArtistRow>, keys: List<SortKey>): List<ArtistRow> = sorted(rows, keys)

    /** Generic entry point: any row kind, with the play-count snapshot for `playCount`. */
    fun <T : BrowseRow> sorted(
        rows: List<T>,
        keys: List<SortKey>,
        playCounts: Map<String, Int> = emptyMap(),
    ): List<T> = apply(rows, keys) { field, row -> field.value(row, playCounts) }

    private class Decorated<T>(val item: T, val index: Int, val vals: List<SortVal?>)

    private fun <T> apply(
        items: List<T>,
        keys: List<SortKey>,
        valueOf: (SortField, T) -> SortVal?,
    ): List<T> {
        if (keys.isEmpty()) return items
        // Decorate once in input order (`index` is the stable tiebreak); resolve
        // every key's value up front so the comparator never re-extracts.
        val decorated = items.mapIndexed { index, item ->
            Decorated(item, index, keys.map { valueOf(it.field, item) })
        }
        return decorated.sortedWith(comparator(keys)).map { it.item }
    }

    private fun <T> comparator(keys: List<SortKey>): Comparator<Decorated<T>> =
        Comparator { a, b ->
            for (k in keys.indices) {
                val av = a.vals[k]
                val bv = b.vals[k]
                val aNull = isNull(av)
                val bNull = isNull(bv)
                if (aNull && bNull) continue
                if (aNull) return@Comparator 1 // nulls last, regardless of direction
                if (bNull) return@Comparator -1
                val cmp = compare(av!!, bv!!)
                if (cmp != 0) return@Comparator if (keys[k].ascending) cmp else -cmp
            }
            a.index - b.index // stable tiebreak
        }

    /** Missing value OR empty string sorts last (§6.4). */
    private fun isNull(v: SortVal?): Boolean =
        v == null || (v is SortVal.Str && v.v.isEmpty())

    private fun compare(a: SortVal, b: SortVal): Int = when {
        a is SortVal.Num && b is SortVal.Num -> a.v.compareTo(b.v)
        a is SortVal.Flag && b is SortVal.Flag -> a.v.compareTo(b.v) // false < true
        else -> text(a).compareTo(text(b), ignoreCase = true)
    }

    private fun text(v: SortVal): String = if (v is SortVal.Str) v.v else ""
}

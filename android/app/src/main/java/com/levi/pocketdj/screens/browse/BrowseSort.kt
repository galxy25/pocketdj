package com.levi.pocketdj.screens.browse

/**
 * Multi-key browse sort — ported from iOS `Browse/BrowseModel.swift:283-351`
 * (specs/browse.md §6.4). Stable (input index is the final tiebreak), nulls last
 * regardless of direction (null = a missing value OR an empty string), camelot
 * sorts by wheel rank as a number, strings compare case-insensitively, bools
 * false < true. No keys → catalog order (albums arrive artist › title already).
 */

/** A sortable field from the registry (§6.1) — the subset that applies to a kind. */
enum class SortField(
    val id: String,
    val label: String,
    val kinds: Set<BrowseKind>,
) {
    // Order mirrors iOS `Fields.all` so `forKind` (and the "Add key" list) match.
    ARTIST("artist", "Artist", setOf(BrowseKind.ALBUMS, BrowseKind.SONGS)),
    NAME("name", "Title", setOf(BrowseKind.ALBUMS, BrowseKind.SONGS)),
    YEAR("year", "Year", setOf(BrowseKind.ALBUMS, BrowseKind.SONGS)),
    GENRE("genre", "Genre", setOf(BrowseKind.ALBUMS, BrowseKind.SONGS)),
    FILE_TYPE("fileType", "File type", setOf(BrowseKind.ALBUMS, BrowseKind.SONGS)),
    SOURCE("source", "Source", setOf(BrowseKind.ALBUMS, BrowseKind.SONGS)),
    COUNTRY("country", "Country", setOf(BrowseKind.ALBUMS)),
    TRACK_COUNT("trackCount", "Track count", setOf(BrowseKind.ALBUMS)),
    TRACK_NUMBER("trackNumber", "Track #", setOf(BrowseKind.SONGS)),
    LENGTH("length", "Length", setOf(BrowseKind.SONGS)),
    BPM("bpm", "BPM", setOf(BrowseKind.SONGS)),
    KEY("key", "Key", setOf(BrowseKind.SONGS)),
    CAMELOT("camelot", "Key (Camelot)", setOf(BrowseKind.SONGS)),
    EXPLICIT("explicit", "Explicit", setOf(BrowseKind.SONGS));

    /** Sort value for an album row — `null` for song-only fields (nulls last). */
    fun value(row: AlbumRow): SortVal? = when (this) {
        ARTIST -> str(row.album.artist)
        NAME -> str(row.album.name)
        YEAR -> num(row.album.year)
        // Genre collapses to the top-tier category (a plain string sort — iOS
        // compares `.string(Genre.category(...))` case-insensitively, so genre
        // sorts ALPHABETICALLY, not by the options-list priority order).
        GENRE -> str(row.genreCategory)
        FILE_TYPE -> str(row.album.fileType)
        SOURCE -> str(row.source)
        COUNTRY -> str(row.album.country)
        TRACK_COUNT -> SortVal.Num(row.album.trackList.size.toDouble())
        else -> null
    }

    /** Sort value for a song row — `null` for album-only fields (nulls last). */
    fun value(row: SongRow): SortVal? = when (this) {
        ARTIST -> str(row.song.artist)
        NAME -> str(row.song.name)
        YEAR -> num(row.song.year)
        GENRE -> str(row.genreCategory)
        FILE_TYPE -> str(row.song.fileType)
        SOURCE -> str(row.source)
        TRACK_NUMBER -> num(row.song.trackNumber)
        LENGTH -> row.song.length?.let { SortVal.Num(it.toDouble()) }
        BPM -> row.song.bpm?.let { SortVal.Num(it) }
        KEY -> str(row.song.key)
        // Camelot is a numeric field here — sort by wheel rank, unparseable → null.
        CAMELOT -> Camelot.rank(row.song.camelot)?.let { SortVal.Num(it.toDouble()) }
        // Missing explicit reads as false (iOS `s.explicit ?? false`); a bool is
        // never null, so it never falls to the nulls-last bucket.
        EXPLICIT -> SortVal.Flag(row.song.explicit ?: false)
        else -> null
    }

    private fun str(value: String?): SortVal? = value?.let { SortVal.Str(it) }
    private fun num(value: Int?): SortVal? = value?.let { SortVal.Num(it.toDouble()) }

    companion object {
        val byId: Map<String, SortField> = entries.associateBy { it.id }

        /** Sortable fields for a kind, in registry order (drives the sort sheet). */
        fun forKind(kind: BrowseKind): List<SortField> = entries.filter { kind in it.kinds }
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

    fun albums(rows: List<AlbumRow>, keys: List<SortKey>): List<AlbumRow> =
        apply(rows, keys) { field, row -> field.value(row) }

    fun songs(rows: List<SongRow>, keys: List<SortKey>): List<SongRow> =
        apply(rows, keys) { field, row -> field.value(row) }

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

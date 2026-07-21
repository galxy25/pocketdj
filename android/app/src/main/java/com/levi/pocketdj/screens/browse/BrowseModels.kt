package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.settings.AppSettingsStore
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/** The two P1 browse kinds (Artists is an allowed later add, specs/browse.md §11). */
enum class BrowseKind { ALBUMS, SONGS }

/** Album results render as a grid or a list (specs/browse.md §6.5 toolbar toggle). */
enum class AlbumLayout { GRID, LIST }

/**
 * On-device local filter vs. online OpenSearch (specs/browse.md §4.2, §7). The
 * online pipeline is not built in P1, but the mode is modelled + persisted so
 * the snapshot is spec-shaped and forward-compatible (discover is excluded on
 * Android). Defaults to [DEVICE].
 */
enum class SearchMode { DEVICE, ONLINE }

/** One precomputed album row: source tag + collapsed genre + folded search key. */
data class AlbumRow(
    val album: IndexAlbum,
    val source: String?,
    val genreCategory: String,
    val searchKey: String,
)

/** One precomputed song row (genre = owning album's collapsed category, §3). */
data class SongRow(
    val song: IndexSong,
    val albumName: String?,
    val source: String?,
    val genreCategory: String,
    val searchKey: String,
)

/**
 * The P1 filter set (task-locked cut of the full clause registry:
 * genre / bpm / key(Camelot) / source — specs/browse.md §6.5). Semantics follow
 * §6.2: clauses AND-compose; a clause whose field doesn't apply to the row's
 * kind passes the row; a missing bpm fails a between; between bounds are
 * inclusive with open ends.
 */
data class BrowseFilters(
    val genres: Set<String> = emptySet(),
    val bpmMin: Double? = null,
    val bpmMax: Double? = null,
    val camelots: Set<String> = emptySet(),
    val sources: Set<String> = emptySet(),
) {
    val activeCount: Int
        get() = (if (genres.isNotEmpty()) 1 else 0) +
            (if (bpmMin != null || bpmMax != null) 1 else 0) +
            (if (camelots.isNotEmpty()) 1 else 0) +
            (if (sources.isNotEmpty()) 1 else 0)

    fun matchesAlbum(row: AlbumRow): Boolean {
        if (genres.isNotEmpty() && row.genreCategory !in genres) return false
        if (sources.isNotEmpty() && (row.source == null || row.source !in sources)) return false
        // bpm/camelot are song fields — they pass album rows (§6.2).
        return true
    }

    fun matchesSong(row: SongRow): Boolean {
        if (genres.isNotEmpty() && row.genreCategory !in genres) return false
        if (sources.isNotEmpty() && (row.source == null || row.source !in sources)) return false
        if (camelots.isNotEmpty()) {
            val code = row.song.camelot?.trim()?.uppercase(Locale.ROOT)
            if (code == null || code !in camelots) return false
        }
        if (bpmMin != null || bpmMax != null) {
            val bpm = row.song.bpm ?: return false // missing value fails between
            if (bpm < (bpmMin ?: Double.NEGATIVE_INFINITY)) return false
            if (bpm > (bpmMax ?: Double.POSITIVE_INFINITY)) return false
        }
        return true
    }
}

/**
 * Precomputed base rows + filter options for one catalog snapshot. Built once
 * per catalog off the main thread (a naive per-keystroke rebuild over ~90k rows
 * was a shipped iOS hang — specs/browse.md §13).
 */
class BrowseRows(catalog: MergedCatalog) {
    val albumRows: List<AlbumRow> = catalog.albums.map { album ->
        val category = Genre.category(album.genre)
        AlbumRow(
            album = album,
            source = catalog.sourceOfAlbum[album.id],
            genreCategory = category,
            searchKey = Fmt.fold("${album.name}\n${album.artist}\n$category"),
        )
    }

    val songRows: List<SongRow> = catalog.songs.map { song ->
        val album = song.albumId?.let(catalog.albumsById::get)
        SongRow(
            song = song,
            albumName = album?.name,
            source = catalog.sourceOfSong[song.id],
            genreCategory = Genre.category(album?.genre),
            searchKey = Fmt.fold("${song.name}\n${song.artist}\n${album?.name.orEmpty()}"),
        )
    }

    /** Distinct collapsed genres over both kinds, category-priority order (§6.1). */
    val genreOptions: List<String> =
        (albumRows.asSequence().map { it.genreCategory } +
            songRows.asSequence().map { it.genreCategory })
            .distinct()
            .sortedBy(Genre::order)
            .toList()

    /** Distinct camelot codes over songs, wheel-rank order (§6.1). */
    val camelotOptions: List<String> = songRows
        .mapNotNull { it.song.camelot?.trim()?.uppercase(Locale.ROOT)?.takeIf(String::isNotEmpty) }
        .distinct()
        .sortedBy { Camelot.rank(it) ?: Int.MAX_VALUE }

    companion object {
        @Volatile
        private var cached: Pair<MergedCatalog, BrowseRows>? = null

        /** One BrowseRows per catalog instance (identity-keyed memo). */
        fun of(catalog: MergedCatalog): BrowseRows =
            cached?.takeIf { it.first === catalog }?.second
                ?: BrowseRows(catalog).also { cached = catalog to it }
    }
}

/** Filtered album results for (query, filters) — run on Dispatchers.Default. */
fun BrowseRows.filteredAlbums(query: String, filters: BrowseFilters): List<AlbumRow> {
    // Strip newlines from the query so it can't match across field boundaries (§4.1).
    val folded = Fmt.fold(query).replace("\n", "")
    return albumRows.filter { row ->
        (folded.isEmpty() || row.searchKey.contains(folded)) && filters.matchesAlbum(row)
    }
}

/** Filtered song results for (query, filters) — run on Dispatchers.Default. */
fun BrowseRows.filteredSongs(query: String, filters: BrowseFilters): List<SongRow> {
    val folded = Fmt.fold(query).replace("\n", "")
    return songRows.filter { row ->
        (folded.isEmpty() || row.searchKey.contains(folded)) && filters.matchesSong(row)
    }
}

/**
 * Process-retained browse UI state so kind/layout/filters/sort survive
 * navigating into album detail and tab switches, AND across process death via
 * [attach] (specs/browse.md §7, iOS "pdj.browse.v1"). The query is transient by
 * doctrine — session-retained in memory but never persisted.
 */
object BrowseSession {
    val kind = MutableStateFlow(BrowseKind.ALBUMS)
    val layout = MutableStateFlow(AlbumLayout.GRID)
    val query = MutableStateFlow("")
    val filters = MutableStateFlow(BrowseFilters())
    val sortKeys = MutableStateFlow<List<SortKey>>(emptyList())
    val searchMode = MutableStateFlow(SearchMode.DEVICE)

    private val attached = AtomicBoolean(false)

    /** Snapshot state to the live flows (the current session as a value). */
    private fun currentState(): BrowseSessionState = BrowseSessionState(
        kind = kind.value,
        layout = layout.value,
        searchMode = searchMode.value,
        filters = filters.value,
        sortKeys = sortKeys.value,
    )

    /**
     * Restore the persisted snapshot into the flows, then persist every later
     * change (debounced, so a burst of BPM keystrokes is one write). Idempotent
     * and process-scoped — wired once from the composition root. The restore
     * runs first and its resulting combined emission is dropped, so hydration
     * never immediately re-writes the same doc.
     */
    @OptIn(FlowPreview::class)
    fun attach(store: AppSettingsStore, scope: CoroutineScope) {
        if (!attached.compareAndSet(false, true)) return
        scope.launch {
            val restored = store.currentBrowseSnapshot().toSessionState()
            kind.value = restored.kind
            layout.value = restored.layout
            searchMode.value = restored.searchMode
            filters.value = restored.filters
            sortKeys.value = restored.sortKeys

            combine(kind, layout, searchMode, filters, sortKeys) { _, _, _, _, _ ->
                currentState()
            }
                .drop(1) // the just-restored state — nothing new to write
                .debounce(WRITE_DEBOUNCE_MS)
                .collectLatest { store.setBrowseSnapshot(it.toSnapshot()) }
        }
    }

    private const val WRITE_DEBOUNCE_MS = 400L
}

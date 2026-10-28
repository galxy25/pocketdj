package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.artists.Artist
import com.levi.pocketdj.data.catalog.IndexAlbum
import com.levi.pocketdj.data.favorites.FavoriteFilter
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
import com.levi.pocketdj.data.settings.BrowseSnapshot
import kotlinx.coroutines.sync.withLock

/**
 * Browse kinds. Album, Song, Artist — order matches iOS `ShowTab`
 * (specs/artists.md §2.1). ARTISTS is the additive slice on top of the shipped
 * P1 Albums/Songs surface.
 */
enum class BrowseKind { ALBUMS, SONGS, ARTISTS }

/** Album results render as a grid or a list (specs/browse.md §6.5 toolbar toggle). */
enum class AlbumLayout { GRID, LIST }

/**
 * On-device local filter vs. online OpenSearch (specs/browse.md §4.2, §7). The
 * online pipeline is not built in P1, but the mode is modelled + persisted so
 * the snapshot is spec-shaped and forward-compatible (discover is excluded on
 * Android). Defaults to [DEVICE].
 */
enum class SearchMode { DEVICE, ONLINE }

/** Any row the filter/sort engine can run over: album, song (incl. History) or artist. */
sealed interface BrowseRow {
    val browseKind: BrowseKind
    val source: String?
}

/** One precomputed album row: source tag + collapsed genre + folded search key. */
data class AlbumRow(
    val album: IndexAlbum,
    override val source: String?,
    val genreCategory: String,
    val searchKey: String,
) : BrowseRow {
    override val browseKind: BrowseKind get() = BrowseKind.ALBUMS
}

/**
 * One precomputed song row (genre = owning album's collapsed category, §3).
 * [dateAdded] (epoch ms) is null until the catalog carries it; [playedAt]
 * (epoch ms) is set only on History rows (the `lastPlayedAt` field).
 */
data class SongRow(
    val song: IndexSong,
    val albumName: String?,
    override val source: String?,
    val genreCategory: String,
    val searchKey: String,
    val dateAdded: Double? = null,
    val playedAt: Double? = null,
) : BrowseRow {
    override val browseKind: BrowseKind get() = BrowseKind.SONGS
}

/** An Artists-kind row wrapping the derived [Artist] (albumCount / songCount sortable). */
data class ArtistRow(val artist: Artist) : BrowseRow {
    override val browseKind: BrowseKind get() = BrowseKind.ARTISTS
    override val source: String? get() = null
    val searchKey: String get() = artist.searchKey
}

/**
 * The live filter set: an AND-composed list of [Clause]s over the full field
 * registry (iOS `BrowseState.clauses`). Incomplete clauses are no-ops and are
 * not counted. The helper accessors below back the quick Sources rail and the
 * legacy genre/bpm/key/source sheet by reading/writing the matching clause.
 */
data class BrowseFilters(
    val clauses: List<Clause> = emptyList(),
    /**
     * Favorite tri-state (song mode only). TRANSIENT like iOS: never in [BrowseSnapshot] — its
     * truth lives in FavoritesStore and moves independently. Applied by the engine at read
     * time ([BrowseRows.filteredSongs]) against the live ♥ set, never memoized.
     */
    val favorite: FavoriteFilter = FavoriteFilter.ANY,
    /** Collection-membership SHOW/HIDE (song mode only). TRANSIENT; read-time; never persisted. */
    val membership: MembershipFilter = MembershipFilter(),
    /** History-only Hide-skips lens. TRANSIENT; applied at History base build. */
    val hideSkips: Boolean = false,
) {
    fun withMembership(m: MembershipFilter) = copy(membership = m)
    fun withHideSkips(v: Boolean) = copy(hideSkips = v)

    /** Clear All: clauses + favorite + hide-skips. Membership has its own "Clear membership". */
    fun clearedAll() = copy(clauses = emptyList(), favorite = FavoriteFilter.ANY, hideSkips = false)

    /** Membership is song-mode only. */
    fun membershipActive(kind: BrowseKind): Boolean = kind == BrowseKind.SONGS && membership.active

    /** Toolbar glyph lit: counted filters OR a membership constraint. */
    fun glyphLit(kind: BrowseKind, historyMode: Boolean = false): Boolean =
        activeCount(kind, historyMode) > 0 || membershipActive(kind)

    /** True when the favorite filter constrains anything. */
    val favoriteActive: Boolean get() = favorite != FavoriteFilter.ANY

    fun withFavorite(v: FavoriteFilter) = copy(favorite = v)

    val activeCount: Int get() = clauses.count { !it.isIncomplete }

    /** Kind-gated count (iOS): the favorite constraint is song-mode only. */
    fun activeCount(kind: BrowseKind, historyMode: Boolean = false): Int =
        activeCount + (if (kind == BrowseKind.SONGS && favoriteActive) 1 else 0) +
            (if (historyMode && hideSkips) 1 else 0)

    /** Does the current sort/filter state read play counts (memo-key gate)? */
    fun usesPlayCounts(sortKeys: List<SortKey>): Boolean =
        sortKeys.any { it.field == SortField.PLAY_COUNT } ||
            clauses.any { !it.isIncomplete && it.field == "playCount" }

    private fun listValues(field: String): Set<String> =
        clauses.firstOrNull { it.field == field && it.op == FilterOp.IN_LIST }?.values.orEmpty()

    private fun withList(field: String, values: Set<String>): BrowseFilters {
        val rest = clauses.filterNot { it.field == field && it.op == FilterOp.IN_LIST }
        return if (values.isEmpty()) copy(clauses = rest)
        else copy(clauses = rest + Clause(field, FilterOp.IN_LIST, values = values))
    }

    private fun between(field: String): Clause? =
        clauses.firstOrNull { it.field == field && it.op == FilterOp.BETWEEN }

    val genres: Set<String> get() = listValues("genre")
    val camelots: Set<String> get() = listValues("camelot")
    val sources: Set<String> get() = listValues("source")
    val bpmMin: Double? get() = between("bpm")?.min
    val bpmMax: Double? get() = between("bpm")?.max

    fun withGenres(v: Set<String>) = withList("genre", v)
    fun withCamelots(v: Set<String>) = withList("camelot", v)
    fun withSources(v: Set<String>) = withList("source", v)
    fun withBpm(min: Double?, max: Double?): BrowseFilters {
        val rest = clauses.filterNot { it.field == "bpm" && it.op == FilterOp.BETWEEN }
        return if (min == null && max == null) copy(clauses = rest)
        else copy(clauses = rest + Clause("bpm", FilterOp.BETWEEN, min = min, max = max))
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

    /** Parallel search-key arrays for [BrowseEngine.filterSort] (built once per catalog). */
    val albumKeys: List<String> = albumRows.map { it.searchKey }
    val songKeys: List<String> = songRows.map { it.searchKey }

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
fun BrowseRows.filteredAlbums(query: String, filters: BrowseFilters): List<AlbumRow> =
    BrowseEngine.filterSort(albumRows, albumKeys, query, filters.clauses, emptyList())

/** Filtered song results for (query, filters) — run on Dispatchers.Default. */
fun BrowseRows.filteredSongs(
    query: String,
    filters: BrowseFilters,
    playCounts: Map<String, Int> = emptyMap(),
    /** The live ♥ set (FavoritesStore.favoriteIds); consulted only while the filter is active. */
    favoriteIds: Set<String> = emptySet(),
): List<SongRow> {
    val rows = BrowseEngine.filterSort(songRows, songKeys, query, filters.clauses, emptyList(), playCounts)
    return BrowseEngine.applyFavorites(rows, filters.favorite, favoriteIds)
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
    @Volatile internal var restored = false

    internal fun currentState(): BrowseSessionState = BrowseSessionState(
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
            this@BrowseSession.restored = true

            combine(kind, layout, searchMode, filters, sortKeys) { _, _, _, _, _ ->
                currentState()
            }
                .drop(1) // the just-restored state — nothing new to write
                .debounce(WRITE_DEBOUNCE_MS)
                .collectLatest { persist { snap -> store.setBrowseSnapshot(snap) } }
        }
    }

    /** One serialized writer for the debounced collector and the lifecycle flush. */
    private val writeLock = kotlinx.coroutines.sync.Mutex()

    /**
     * Writes the LIVE state (read inside the lock), so a slow older write can never commit
     * after a newer one and leave a stale snapshot behind.
     */
    internal suspend fun persist(write: suspend (BrowseSnapshot) -> Unit) {
        writeLock.withLock { write(currentState().toSnapshot()) }
    }

    private const val WRITE_DEBOUNCE_MS = 400L
}

/**
 * The production SONGS pipeline (query → clauses → sort, then ♥ layer). BrowseScreen passes FavoriteFilter.ANY
 * and applies favorites via ReadTimeFilters instead.
 */
fun BrowseRows.songResults(
    query: String,
    filters: BrowseFilters,
    sortKeys: List<SortKey>,
    playCounts: Map<String, Int>,
    favoriteIds: Set<String>,
): List<SongRow> = BrowseEngine.applyFavorites(
    BrowseEngine.filterSort(songRows, songKeys, query, filters.clauses, sortKeys, playCounts),
    filters.favorite,
    favoriteIds,
)

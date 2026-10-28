package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.settings.BrowseSnapshot
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc
import com.levi.pocketdj.data.settings.ClauseDoc

/**
 * The persistable slice of [BrowseSession] and its pure mapping to/from the
 * on-disk [BrowseSnapshot] (specs/browse.md §7). Split out from the UI so the
 * round-trip — including lenient decode of an older/corrupt/future doc — is a
 * plain unit test with no DataStore or Compose.
 *
 * Not persisted: the query text and the membership/favorite filters (§7).
 */
data class BrowseSessionState(
    val kind: BrowseKind,
    val layout: AlbumLayout,
    val searchMode: SearchMode,
    val filters: BrowseFilters,
    val sortKeys: List<SortKey>,
)

/** Session → doc: enums lower-cased to their wire strings, sets to lists. */
fun BrowseSessionState.toSnapshot(): BrowseSnapshot = BrowseSnapshot(
    kind = kind.name.lowercase(),
    layout = layout.name.lowercase(),
    searchMode = searchMode.name.lowercase(),
    // Clauses are the source of truth; the legacy fields are left empty so the
    // next write retires them (one-way migration).
    clauses = filters.clauses.map(Clause::toDoc),
    sortKeys = sortKeys.map { BrowseSortKeyDoc(it.field.id, it.ascending) },
)

/**
 * Doc → session, leniently: an unknown `kind`/`layout`/`searchMode` string falls
 * to the safe default, and a sort key naming a field this build doesn't know
 * (removed/renamed/future) is dropped — mirrors iOS `compactMap { Fields.byID[…] }`.
 */
fun BrowseSnapshot.toSessionState(): BrowseSessionState = BrowseSessionState(
    kind = parseKind(kind),
    layout = parseLayout(layout),
    searchMode = parseSearchMode(searchMode),
    filters = BrowseFilters(
        // A doc with clauses wins; unknown field/op ids drop (iOS compactMap).
        clauses = clauses?.mapNotNull(ClauseDoc::toClause) ?: legacyClauses(),
    ),
    sortKeys = sortKeys.mapNotNull { doc ->
        SortField.byId[doc.field]?.let { SortKey(it, doc.ascending) }
    },
)

private fun parseKind(value: String): BrowseKind = when (value.lowercase()) {
    "songs" -> BrowseKind.SONGS
    "artists" -> BrowseKind.ARTISTS
    // Unknown/older/newer strings stay safe on ALBUMS (iron law, specs/artists.md §2.2).
    else -> BrowseKind.ALBUMS
}

private fun parseLayout(value: String): AlbumLayout =
    if (value.lowercase() == "list") AlbumLayout.LIST else AlbumLayout.GRID

private fun parseSearchMode(value: String): SearchMode =
    when (value.lowercase()) {
        "online" -> SearchMode.ONLINE
        "discover" -> SearchMode.DISCOVER
        else -> SearchMode.DEVICE
    }

/**
 * Pre-clause snapshot (genres / bpm range / camelots / sources) → the equivalent
 * clauses: the same shape the old sheet produced, so the filtered results and
 * the active-filter count are unchanged by the upgrade.
 */
internal fun BrowseSnapshot.legacyClauses(): List<Clause> = BrowseFilters()
    .withGenres(genres.toSet())
    .withBpm(bpmMin, bpmMax)
    .withCamelots(camelots.toSet())
    .withSources(sources.toSet())
    .clauses

internal fun Clause.toDoc(): ClauseDoc =
    ClauseDoc(id, field, op.id, value, values.sorted(), min, max)

internal fun ClauseDoc.toClause(): Clause? {
    if (Fields.byId[field] == null) return null
    val filterOp = FilterOp.byId[op] ?: return null
    return Clause(
        field = field,
        op = filterOp,
        value = value,
        values = values.toSet(),
        min = min,
        max = max,
        id = id.ifEmpty { java.util.UUID.randomUUID().toString() },
    )
}

/**
 * Lifecycle flush: writes the live session immediately so a change inside the 400 ms debounce
 * window survives a background + kill. Skipped until the restore has run (never clobber the
 * persisted doc with defaults). Contributed via BrowseGraph.flushables.
 */
class BrowseSessionFlushable(
    private val write: suspend (BrowseSnapshot) -> Unit,
) : com.levi.pocketdj.shell.Flushable {
    override suspend fun flush() {
        if (!BrowseSession.restored) return
        BrowseSession.persist(write)
    }
}

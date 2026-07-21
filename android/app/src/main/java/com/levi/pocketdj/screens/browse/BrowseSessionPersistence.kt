package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.settings.BrowseSnapshot
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc

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
    genres = filters.genres.toList(),
    bpmMin = filters.bpmMin,
    bpmMax = filters.bpmMax,
    camelots = filters.camelots.toList(),
    sources = filters.sources.toList(),
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
        genres = genres.toSet(),
        bpmMin = bpmMin,
        bpmMax = bpmMax,
        camelots = camelots.toSet(),
        sources = sources.toSet(),
    ),
    sortKeys = sortKeys.mapNotNull { doc ->
        SortField.byId[doc.field]?.let { SortKey(it, doc.ascending) }
    },
)

private fun parseKind(value: String): BrowseKind =
    if (value.lowercase() == "songs") BrowseKind.SONGS else BrowseKind.ALBUMS

private fun parseLayout(value: String): AlbumLayout =
    if (value.lowercase() == "list") AlbumLayout.LIST else AlbumLayout.GRID

private fun parseSearchMode(value: String): SearchMode =
    if (value.lowercase() == "online") SearchMode.ONLINE else SearchMode.DEVICE

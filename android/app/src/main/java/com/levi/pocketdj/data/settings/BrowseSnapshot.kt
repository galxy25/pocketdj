package com.levi.pocketdj.data.settings

import kotlinx.serialization.Serializable

/**
 * The persisted Browse view-state (specs/browse.md §7 — iOS UserDefaults key
 * `"pdj.browse.v1"`). One lenient JSON doc under its own DataStore key. Kept as
 * primitives (no UI enums) so the data layer stays independent of `screens.*`;
 * the browse layer maps to/from its live types.
 *
 * Iron law: every field is optional with a default, so a corrupt or older/newer
 * doc decodes to sane values instead of wiping the save. The transient query
 * text and the membership/favorite filters are deliberately NOT here (§7).
 */
@Serializable
data class BrowseSnapshot(
    val kind: String = "albums",
    val layout: String = "grid",
    val searchMode: String = "device",
    val genres: List<String> = emptyList(),
    val bpmMin: Double? = null,
    val bpmMax: Double? = null,
    val camelots: List<String> = emptyList(),
    val sources: List<String> = emptyList(),
    val sortKeys: List<BrowseSortKeyDoc> = emptyList(),
)

/** One persisted sort key: a field id (registry id) + direction (§6.4). */
@Serializable
data class BrowseSortKeyDoc(
    val field: String,
    val ascending: Boolean = true,
)

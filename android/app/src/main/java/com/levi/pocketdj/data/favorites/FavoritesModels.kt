package com.levi.pocketdj.data.favorites

import kotlinx.serialization.Serializable

/**
 * Per-profile song favorites models (iOS `FavoritesStore.Entry` / `Document`, Android parity
 * COL-10). Shape-compatible with iOS `pocketdj-favorites.json` so a backup zip round-trips.
 *
 * `favorited = false` is a TOMBSTONE (an explicit un-heart), NOT a deletion: absence means
 * "never touched", which is what seeding and Apple Music pulls are allowed to fill.
 */
@Serializable
data class FavoriteEntry(
    val songId: String,
    val favorited: Boolean,
    /** Epoch ms of the last toggle — the reconcile tie-break (newer local edit wins). */
    val atMs: Double,
    /** Apple Music catalog id captured at toggle time (null for vinyl/digital/studio). */
    val appleMusicId: String? = null,
    /** Set once this state has been mirrored upstream; null/older than [atMs] ⇒ push owed. */
    val pushedAtMs: Double? = null,
)

/** The on-disk document. Every field defaulted; unknown keys ignored (additive-optional). */
@Serializable
data class FavoritesDocument(
    val schemaVersion: Int = 1,
    val entries: List<FavoriteEntry> = emptyList(),
    /** Highest seed version already applied. Optional for forward/back compat. */
    val seedVersion: Int? = null,
)

/**
 * Browse favorite tri-state (iOS `BrowseState.FavoriteFilter` any/only/exclude). Song mode
 * only; TRANSIENT — never persisted in the Browse snapshot because its truth lives in
 * [FavoritesStore] and changes independently.
 */
enum class FavoriteFilter { ANY, FAVORITE, NOT }

/**
 * The playback-facing favorite contract (shape of the PB-2 `FavoriteSeam`: isFavorite/toggle by
 * songId). [FavoritesStore] implements it so the lock-screen ♥ can bind through CollectionsGraph.
 */
interface FavoritesAccess {
    fun isFavorite(songId: String): Boolean

    /** Flip and return the NEW state. [appleMusicId] null keeps a previously-known id. */
    fun toggle(songId: String, appleMusicId: String? = null): Boolean
}

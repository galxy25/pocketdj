package com.levi.pocketdj.data.activity

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Collection-activity document models (specs/activity-favorites.md §2) — the
 * append-only log of user collection acts powering History's Activity segment.
 * Shape-compatible with iOS `pocketdj-collection-activity.json`.
 *
 * ALL FOUR kinds are defined now even though P2 emits only add/remove — the
 * schema is the future-proof part; a later favorites slice plumbs heart/unheart
 * straight in with zero store changes.
 */

/** What happened. Raw tokens are the persisted values — never rename. */
@Serializable
enum class ActivityKind(val token: String) {
    @SerialName("add")
    ADD("add"),

    @SerialName("heart")
    HEART("heart"),

    @SerialName("unheart")
    UNHEART("unheart"),

    @SerialName("remove")
    REMOVE("remove"),
}

/**
 * One activity event. `itemTitle`/`collectionName` are SNAPSHOTS at record time
 * so a row stays readable after the item leaves the catalog or the collection
 * is renamed/deleted. The three collection fields are null for heart/unheart.
 * `id` travels verbatim (exact-string dedupe — never case-normalize).
 */
@Serializable
data class ActivityEvent(
    val id: String,
    /** Epoch ms of the event. */
    val at: Double,
    val kind: ActivityKind,
    val itemId: String,
    val itemTitle: String? = null,
    val collectionId: String? = null,
    /** AddTarget.Kind raw token ("pocket" / "playlist"). */
    val collectionKind: String? = null,
    val collectionName: String? = null,
)

/**
 * The on-disk document. Additive-optional iron law: every field defaulted,
 * unknown keys ignored — an empty or forward-version file loads degraded rather
 * than resetting the store. `installId` is the merge attribution key.
 */
@Serializable
data class ActivityDocument(
    val schemaVersion: Int = COLLECTION_ACTIVITY_SCHEMA_VERSION,
    val installId: String = "",
    /** Append-only, oldest → newest. */
    val events: List<ActivityEvent> = emptyList(),
)

const val COLLECTION_ACTIVITY_SCHEMA_VERSION = 1

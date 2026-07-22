package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.activity.ActivityKind
import com.levi.pocketdj.data.catalog.MergedCatalog

/**
 * One derived Activity row (specs/activity-favorites.md §5). Pure — extracted
 * from the composable so the wording/order/tap contract is unit-testable.
 */
internal data class ActivityRowUi(
    val eventId: String,
    val kind: ActivityKind,
    val headline: String,
    val atMs: Long,
    /** Non-null only when the item resolves to a live catalog SONG (tappable). */
    val songId: String?,
)

/**
 * Rows NEWEST FIRST from the oldest→newest log. Display-title precedence: live
 * catalog song name → live catalog album name → the event's `itemTitle`
 * snapshot (if non-empty) → raw `itemId`. Resolved/snapshot titles wrap in
 * curly quotes; the raw-id fallback is unquoted.
 *
 * [query] (blank = keep all) filters on the resolved item title OR the
 * collection name (case-insensitive) — the iOS `activitySearchKey` contract used
 * by the unified + Collection History views.
 */
internal fun buildActivityRows(
    events: List<ActivityEvent>,
    catalog: MergedCatalog,
    query: String = "",
): List<ActivityRowUi> {
    val needle = query.trim()
    return events.asReversed().mapNotNull { event ->
        val liveSong = catalog.songsById[event.itemId]
        val liveSongName = liveSong?.name
        val liveAlbumName = catalog.albumsById[event.itemId]?.name
        if (needle.isNotEmpty()) {
            val title = liveSongName
                ?: liveAlbumName
                ?: event.itemTitle?.takeIf { it.isNotEmpty() }
                ?: event.itemId
            val coll = event.collectionName.orEmpty()
            if (!title.contains(needle, ignoreCase = true) &&
                !coll.contains(needle, ignoreCase = true)
            ) {
                return@mapNotNull null
            }
        }
        ActivityRowUi(
            eventId = event.id,
            kind = event.kind,
            headline = activityHeadline(
                event = event,
                liveSongName = liveSongName,
                liveAlbumName = liveAlbumName,
            ),
            atMs = event.at.toLong(),
            songId = liveSong?.id,
        )
    }
}

/** Headline wording per kind — copy is exact (iOS `HistoryView.swift:153-164`). */
internal fun activityHeadline(
    event: ActivityEvent,
    liveSongName: String?,
    liveAlbumName: String?,
): String {
    val title = liveSongName ?: liveAlbumName ?: event.itemTitle?.takeIf { it.isNotEmpty() }
    val item = if (title != null) "“$title”" else event.itemId
    val coll = event.collectionName ?: "a collection"
    return when (event.kind) {
        ActivityKind.ADD -> "Added $item to $coll"
        ActivityKind.HEART -> "Hearted $item"
        ActivityKind.UNHEART -> "Removed heart from $item"
        ActivityKind.REMOVE -> "Removed $item from $coll"
    }
}

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
 */
internal fun buildActivityRows(
    events: List<ActivityEvent>,
    catalog: MergedCatalog,
): List<ActivityRowUi> = events.asReversed().map { event ->
    val liveSong = catalog.songsById[event.itemId]
    ActivityRowUi(
        eventId = event.id,
        kind = event.kind,
        headline = activityHeadline(
            event = event,
            liveSongName = liveSong?.name,
            liveAlbumName = catalog.albumsById[event.itemId]?.name,
        ),
        atMs = event.at.toLong(),
        songId = liveSong?.id,
    )
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

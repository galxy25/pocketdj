package com.levi.pocketdj.screens.history

import com.levi.pocketdj.data.activity.ActivityEvent
import com.levi.pocketdj.data.catalog.MergedCatalog
import com.levi.pocketdj.data.history.PlayEvent
import com.levi.pocketdj.data.history.PlaySource

/**
 * One derived Playback-timeline row (specs/history.md §5): identity is the EVENT
 * id — a song played three times is three rows. Title/artist resolve live-catalog
 * first, event snapshot second, so history outlives the catalog.
 */
internal data class HistoryRow(
    val eventId: String,
    val songId: String,
    val title: String,
    val artist: String,
    val artUrl: String?,
    val source: PlaySource,
    val contextName: String?,
    val playedAtMs: Long,
    /** Total plays of this song in the log (badge shows only when > 1). */
    val playCount: Int,
)

/**
 * Playback rows with live-catalog-first, snapshot-second resolution, filtered by
 * the search [query] (title or artist, case-folded) and the played-between range
 * ([rangeStartMs] inclusive, [rangeEndMs] exclusive), sorted by playedAt in the
 * requested direction (§6.4). [playCountOf] resolves a song's total play count
 * (injected so the pure builder needs no store — the unified view and tests reuse
 * it directly).
 */
internal fun buildRows(
    events: List<PlayEvent>,
    catalog: MergedCatalog,
    playCountOf: (songId: String) -> Int,
    query: String,
    newestFirst: Boolean,
    rangeStartMs: Long?,
    rangeEndMs: Long?,
): List<HistoryRow> {
    val needle = query.trim()
    val ordered = if (newestFirst) events.asReversed() else events
    return ordered.mapNotNull { event ->
        val playedAtMs = event.playedAt.toLong()
        if (rangeStartMs != null && playedAtMs < rangeStartMs) return@mapNotNull null
        if (rangeEndMs != null && playedAtMs >= rangeEndMs) return@mapNotNull null
        val song = catalog.songsById[event.songId]
        val title = song?.name ?: event.title ?: event.songId
        val artist = song?.artist ?: event.artist ?: ""
        if (needle.isNotEmpty() &&
            !title.contains(needle, ignoreCase = true) &&
            !artist.contains(needle, ignoreCase = true)
        ) {
            return@mapNotNull null
        }
        val album = song?.albumId?.let { catalog.albumsById[it] }
        HistoryRow(
            eventId = event.id,
            songId = event.songId,
            title = title,
            artist = artist,
            artUrl = album?.artCandidates()?.firstOrNull(),
            source = event.source,
            contextName = event.contextName,
            playedAtMs = playedAtMs,
            playCount = playCountOf(event.songId),
        )
    }
}

/**
 * One entry in the UNIFIED History timeline (iOS `HistoryView.HistoryEntry`):
 * either a song play or a collection-activity event, each carrying its own
 * epoch-ms timestamp for the merge sort. Ids are namespaced (`p:` / `a:`) so a
 * play event and an activity event can never collide on a LazyColumn key.
 */
internal sealed interface HistoryEntry {
    val id: String
    val atMs: Long

    data class Play(val row: HistoryRow) : HistoryEntry {
        override val id get() = "p:${row.eventId}"
        override val atMs get() = row.playedAtMs
    }

    data class Activity(val row: ActivityRowUi) : HistoryEntry {
        override val id get() = "a:${row.eventId}"
        override val atMs get() = row.atMs
    }
}

/**
 * The merged Unified timeline (iOS `buildUnified`): song plays and collection
 * activity interleaved NEWEST FIRST, both filtered by the search [query]
 * (title/artist for plays; item title + collection name for activity). The
 * date-range filter is deliberately NOT applied here — Unified honours only the
 * shared search query; sort/range stay Playback-only.
 */
internal fun buildUnified(
    playEvents: List<PlayEvent>,
    activityEvents: List<ActivityEvent>,
    catalog: MergedCatalog,
    playCountOf: (songId: String) -> Int,
    query: String,
): List<HistoryEntry> {
    val plays = buildRows(
        events = playEvents,
        catalog = catalog,
        playCountOf = playCountOf,
        query = query,
        newestFirst = true,
        rangeStartMs = null,
        rangeEndMs = null,
    ).map { HistoryEntry.Play(it) }
    val acts = buildActivityRows(activityEvents, catalog, query)
        .map { HistoryEntry.Activity(it) }
    // Stable descending sort keeps the per-stream newest-first order on ties.
    return (plays + acts).sortedByDescending { it.atMs }
}

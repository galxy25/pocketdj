package com.levi.pocketdj.playback

import com.levi.pocketdj.data.collections.CollectionMembership
import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.data.rips.PlayAction

/**
 * Pure setlist-queue planning (specs/realize-play.md §6.2–§6.3) — everything
 * about turning ordered queue entries into a playable Media3 item list that
 * does NOT need a player:
 *
 * - resolve every id at queue-BUILD time; keep `PlayAction.Stream` hits (with
 *   their analog clip windows), SKIP metadata-only / rip-required rows (P2 cut:
 *   no per-row rip-on-demand inside a setlist run) and surface the skip count;
 * - per-item repeatCount is NOT native to Media3 — expand a repeated entry into
 *   `normalizedRepeat` CONSECUTIVE queue items (keeps ExoPlayer's gapless
 *   preload, needs no custom advance logic); History's 30 s same-song window
 *   collapses the repeats;
 * - unbounded-analog rows (no manifest duration) keep clip-start only and run
 *   to the album file's natural end — NO queue truncation here (that P1 rule is
 *   album-up-next-specific; in a setlist the next row is usually another file).
 */
object QueuePlan {
    /** One ordered row of a wanted queue (a setlist track, pre-resolution). */
    data class QueueEntry(
        val songId: String,
        /** Total plays before advance; null ⇒ once. */
        val repeatCount: Int? = null,
    )

    /** One playable Media3 slot (repeat expansion already applied). */
    data class PlannedItem(
        /** Index of the originating entry in the input list (repeats share it). */
        val entryIndex: Int,
        val songId: String,
        val action: PlayAction.Stream,
    )

    data class Plan(
        val items: List<PlannedItem>,
        /** Entries that resolved playable. */
        val playableEntryCount: Int,
        /** Entries skipped (metadata-only / rip-required / empty id). */
        val skippedEntryCount: Int,
        val requestedEntryCount: Int,
    ) {
        val isEmpty: Boolean get() = items.isEmpty()

        /** "Playing m of n — k not playable on Android" seam for the UI. */
        val skippedSummary: String?
            get() = if (skippedEntryCount == 0) {
                null
            } else {
                "Playing $playableEntryCount of $requestedEntryCount — " +
                    "$skippedEntryCount not playable on Android"
            }
    }

    /** Resolve + repeat-expand an ordered entry list into a queue plan. */
    fun build(entries: List<QueueEntry>, resolve: (String) -> PlayAction): Plan {
        val items = ArrayList<PlannedItem>()
        var playable = 0
        var skipped = 0
        entries.forEachIndexed { index, entry ->
            if (entry.songId.isEmpty()) {
                skipped++
                return@forEachIndexed
            }
            when (val action = resolve(entry.songId)) {
                is PlayAction.Stream -> {
                    playable++
                    repeat(CollectionMembership.normalizedRepeat(entry.repeatCount)) {
                        items.add(PlannedItem(index, entry.songId, action))
                    }
                }
                else -> skipped++
            }
        }
        return Plan(
            items = items,
            playableEntryCount = playable,
            skippedEntryCount = skipped,
            requestedEntryCount = entries.size,
        )
    }

    /**
     * A setlist's queue rows (specs/realize-play.md §6.1): text cues and empty
     * songIds filtered, repeatCount carried. Frozen order preserved.
     */
    fun entriesForSetlist(setlist: Setlist): List<QueueEntry> =
        setlist.tracks
            .filter { it.isText != true && it.songId.isNotEmpty() }
            .map { QueueEntry(songId = it.songId, repeatCount = it.repeatCount) }
}

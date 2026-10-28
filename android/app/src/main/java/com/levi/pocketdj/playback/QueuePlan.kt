package com.levi.pocketdj.playback

import com.levi.pocketdj.data.collections.Setlist
import com.levi.pocketdj.playback.sequencer.QueueItem

/**
 * Pure setlist -> sequencer queue mapping. Since PB-1 nothing is resolved at queue-BUILD time:
 * the [com.levi.pocketdj.playback.sequencer.SetlistSequencer] resolves each row fresh at its turn
 * (a rip may land between build and play), skips the unplayable ones with a log line, and loops a
 * row `repeatCount` times on natural end (no consecutive-duplicate expansion).
 *
 * Mapping is 1:1 with the entries, so an entry index IS a queue index.
 */
object QueuePlan {
    /** One ordered row of a wanted queue. */
    data class QueueEntry(
        val songId: String,
        /** Total plays before advance; null = once. */
        val repeatCount: Int? = null,
        val title: String? = null,
        val artist: String? = null,
        val lengthMs: Long? = null,
    )

    /** Entries -> queue rows. [meta] fills title/artist/length from the catalog when the entry has none. */
    fun items(
        entries: List<QueueEntry>,
        meta: (String) -> Triple<String?, String?, Long?> = { Triple(null, null, null) },
    ): List<QueueItem> =
        entries.filter { it.songId.isNotEmpty() }.map { e ->
            val (t, a, l) = meta(e.songId)
            QueueItem(
                id = e.songId,
                title = e.title?.takeIf { it.isNotEmpty() } ?: t ?: e.songId,
                artist = e.artist?.takeIf { it.isNotEmpty() } ?: a,
                lengthMs = e.lengthMs ?: l,
                repeatCount = e.repeatCount,
            )
        }

    /** Index of the queue row for an ORIGINAL entry index (empty-id entries are dropped). */
    fun queueIndexForEntry(entries: List<QueueEntry>, entryIndex: Int): Int =
        entries.take(entryIndex.coerceAtLeast(0)).count { it.songId.isNotEmpty() }
            .coerceAtMost((entries.count { it.songId.isNotEmpty() } - 1).coerceAtLeast(0))

    /**
     * A setlist's queue rows (specs/realize-play.md 6.1): text cues and empty songIds filtered,
     * repeatCount and the frozen title/artist/length carried. Frozen order preserved.
     */
    fun entriesForSetlist(setlist: Setlist): List<QueueEntry> =
        setlist.tracks
            .filter { it.isText != true && it.songId.isNotEmpty() }
            .map {
                QueueEntry(
                    songId = it.songId,
                    repeatCount = it.repeatCount,
                    title = it.name,
                    artist = it.artist,
                    lengthMs = it.lengthMs,
                )
            }
}

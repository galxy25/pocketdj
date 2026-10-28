package com.levi.pocketdj.screens.nowplaying

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.shell.ShellRoute

/**
 * Pure helpers behind the live-queue panel (iOS `NowPlayingPanel` Up Next). Everything that turns a
 * GESTURE into a sequencer call lives here so the uid-safety rules are unit-testable: positions are
 * only ever a hint, the row's uid is the identity, and the live queue is re-read at gesture END.
 */
object QueueReorder {
    /** Up Next renders at most this many rows (the iOS `upNextShown` window); offsets stay 1:1 with the full tail. */
    const val WINDOW = 200

    fun window(upcoming: List<QueueItem>): List<QueueItem> = upcoming.take(WINDOW)

    fun countHeader(total: Int): String = "Up next ($total)"

    fun playedHeader(total: Int): String = "Previously played ($total)"

    /** A resolved reorder: [fromOffset] and the SwiftUI-`onMove` style [toOffset] (pre-move index space). */
    data class Move(val fromOffset: Int, val toOffset: Int)

    /**
     * Turn "row [uid] was dragged by [rowsMoved] rows" into a sequencer move against the LIVE tail
     * ([liveUids] = `sequencer.state.upcoming.map { it.uid }` read NOW). A row that is no longer
     * upcoming (it started playing / was removed while the finger was down) yields null - a safe no-op.
     * The final slot is clamped to the live tail.
     */
    fun resolveMove(liveUids: List<String>, uid: String, rowsMoved: Int): Move? {
        val from = liveUids.indexOf(uid)
        if (from < 0 || rowsMoved == 0) return null
        val finalIndex = (from + rowsMoved).coerceIn(0, liveUids.lastIndex)
        if (finalIndex == from) return null
        // moveUpcoming's destination is expressed in the PRE-move list (onMove): moving down needs +1.
        return Move(from, if (finalIndex > from) finalIndex + 1 else finalIndex)
    }

    /** Whole rows covered by a drag of [dragPx] with rows [rowPx] tall (round-to-nearest, sign kept). */
    fun rowsForDrag(dragPx: Float, rowPx: Float): Int {
        if (rowPx <= 0f) return 0
        return Math.round(dragPx / rowPx)
    }

    /** Is [uid] still an upcoming row? Gate for taps/menu actions that may have raced an advance. */
    fun stillUpcoming(liveUids: List<String>, uid: String): Boolean = uid in liveUids

    /** Expanded Now Playing layout (platter centre, played left, up-next right): >=600dp wide or landscape. */
    fun useExpandedLayout(widthDp: Int, landscape: Boolean): Boolean = widthDp >= 600 || landscape

    /**
     * The origin pill: (source token, collection id) captured by the sequencer -> a shell route.
     * Unknown tokens yield null (no button).
     */
    fun originRoute(origin: Pair<String, String>?): ShellRoute? {
        val (token, id) = origin ?: return null
        if (id.isBlank()) return null
        return when (token) {
            "playlist" -> ShellRoute.Playlist(id)
            "pocket" -> ShellRoute.Pocket(id)
            "album" -> ShellRoute.Album(id)
            "artist" -> ShellRoute.Artist(id)
            "setlist" -> ShellRoute.Setlist(id)
            else -> null
        }
    }

    /**
     * "Open set list": the real setlist when [sourceSetlistId] still exists in collections, else the
     * live queue must be materialized as the reserved Now Playing setlist first.
     */
    fun needsMaterialize(sourceSetlistId: String?, setlistExists: (String) -> Boolean): Boolean =
        sourceSetlistId == null || !setlistExists(sourceSetlistId)
}

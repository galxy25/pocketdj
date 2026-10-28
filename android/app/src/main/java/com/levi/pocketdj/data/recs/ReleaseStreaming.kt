package com.levi.pocketdj.data.recs

import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * One track of a release, flattened out of whichever expansion answered. A plain value with no network
 * types, so the mapping below - the part that decides what actually gets queued - is exercised by the
 * unit suite rather than only by driving the UI.
 */
data class ReleaseStreamTrack(
    val storeId: String,
    val title: String,
    val artist: String,
    val lengthMs: Long? = null,
)

/**
 * **New is playable** (port of iOS `ReleaseStreaming`): the equivalent of cloud mode for a collection.
 *
 * The New tile lists releases by artists he plays that he does NOT own - which is exactly why the ordinary
 * door is closed to it: `CollectionsStore.playNow` DROPS every id the catalog cannot resolve, and no track
 * of an unowned release resolves. So this uses the OTHER, already-shipped door for Apple-Music-only audio:
 * queue items carrying the namespaced `am:<storeId>` id, handed straight to the sequencer, which routes
 * that namespace to the Apple Music backend (the same shape the Jukebox and Music with Friends queue).
 *
 * DEGRADE, NEVER STALL: a release with no store id is never offered by the feed, a release whose expansion
 * is empty contributes nothing, a track with a blank store id is dropped here, and a queued row whose audio
 * cannot be resolved at play time is skipped forward by the sequencer. A dead row can never park the queue.
 */
object ReleaseStreaming {
    /** How many releases one play expands. Each is one network round trip: a latency ceiling. */
    const val MAX_RELEASES = 25
    /** Expansions in flight at once (a burst of unbounded requests earns a 429). */
    const val CONCURRENCY = 4

    /**
     * The `sourceSetlistId` a New run is tagged with. Nothing in the collections store resolves it (a New
     * queue is not a collection), which is fine: it is IDENTITY, so the New screen knows a
     * device-queue-unplayable signal belongs to it. Deliberately not `puzzle_`-prefixed.
     */
    const val RUN_TAG = "foryou_new"

    /** ONE string, because the tile card and the New screen both start this queue. */
    const val EMPTY_EXPANSION_MESSAGE =
        "Apple Music didn’t return a track list for these releases. " +
            "Check your connection (or your Apple Music sign-in in Settings) and try again."

    fun namespacedSongId(storeId: String): String = "am:$storeId"

    /**
     * Expanded tracks -> queue items.
     *  - A blank store id is DROPPED (it can never resolve to audio).
     *  - A track the local catalog already claims plays under its OWN song id, so device mode can reach its
     *    burned file and history/stats key the real song. Everything else plays as `am:<storeId>`.
     *  - Duplicates collapse (an artist can appear twice in the feed; a single is also an album track).
     */
    fun items(tracks: List<ReleaseStreamTrack>, catalogSongId: (String) -> String? = { null }): List<QueueItem> {
        val seen = HashSet<String>()
        val out = ArrayList<QueueItem>()
        for (t in tracks) {
            val storeId = t.storeId.trim()
            if (storeId.isEmpty()) continue
            val id = catalogSongId(storeId) ?: namespacedSongId(storeId)
            if (!seen.add(id)) continue
            out += QueueItem(id = id, title = t.title, artist = t.artist, lengthMs = t.lengthMs)
        }
        return out
    }

    /**
     * Expand releases IN ORDER, [CONCURRENCY] at a time, capped at [MAX_RELEASES]. Order is preserved
     * because a queue built from "newest release first" that came back in completion order would shuffle
     * itself differently on every tap. [expand] returns empty on failure; that release is dropped.
     */
    suspend fun tracks(
        releaseIds: List<String>,
        expand: suspend (String) -> List<ReleaseStreamTrack>,
    ): List<ReleaseStreamTrack> {
        val wanted = releaseIds.take(MAX_RELEASES)
        if (wanted.isEmpty()) return emptyList()
        val sem = Semaphore(CONCURRENCY)
        return coroutineScope {
            wanted.map { id -> async { sem.withPermit { runCatching { expand(id) }.getOrElse { if (it is kotlinx.coroutines.CancellationException) throw it else emptyList() } } } }
                .awaitAll()
                .flatten()
        }
    }

    /** Releases that ▶/🔀 queue: out-now only (a pre-order has no audio), minus the thumbed-down tail. */
    fun playableReleaseIds(liveOutNow: List<ReleaseFeedItem>): List<String> =
        liveOutNow.filter { it.status == ReleaseStatus.OUT_NOW }.mapNotNull { it.entry.releaseId }.filter { it.isNotBlank() }
}

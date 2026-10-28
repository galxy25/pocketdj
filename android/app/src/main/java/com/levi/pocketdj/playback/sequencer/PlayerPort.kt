package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlayContext

/** Everything the player needs to start ONE row. */
data class PlayRequest(
    val item: QueueItem,
    val source: RowSource,
    /** Captured ONCE at play(); with the item's runTag folded in. */
    val context: PlayContext,
    /** Origin collection id when the run is `set_now_playing`; History attribution. */
    val originCollectionId: String?,
    /** Restore-resume only: start mid-song. */
    val resumeAtMs: Long?,
    val index: Int,
    val count: Int,
)

/** An arbitrary stream (jukebox Tune-In). */
data class UrlRequest(
    val title: String,
    val artist: String?,
    val url: String,
    val seekMs: Long,
)

/**
 * The thin seam between the sequencer and the audio engine. The Media3 adapter loads ONLY the
 * current row (ExoPlayer is not the queue). Natural end / failure come back through
 * [SetlistSequencer.handleEnded] / [SetlistSequencer.handleFailed] with the id of the row that
 * ended, so an ended foreign single can never advance the set.
 *
 * [load] may suspend while the row prepares; it should throw on a dead source. The sequencer
 * guards every post-await state write by its own generation.
 */
interface PlayerPort {
    suspend fun load(request: PlayRequest)
    suspend fun loadUrl(request: UrlRequest)

    /**
     * Restart the item the engine already holds for [songId] from 0 (repeat pass / duplicate row)
     * WITHOUT a new load. Returns false when the engine does not hold that row anymore, in which
     * case the sequencer falls back to a normal load.
     */
    suspend fun replay(songId: String): Boolean
    suspend fun pause()
    suspend fun resume()
    suspend fun seekTo(positionMs: Long)
    suspend fun stop()
}

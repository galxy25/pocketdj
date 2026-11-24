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
    /** Q21: a retry-in-place wants a FRESH rip resolution (re-POST) instead of joining one in flight. */
    val reResolve: Boolean = false,
    /** Sequencer play generation that issued this request (trace + duplicate-load guard). */
    val generation: Long = -1,
    /**
     * P2-ALB-4: set when this row is part of an in-order run of its shared album file. The engine then loads ONE item
     * clipped `[plan.clipStartMs, END_OF_SOURCE)` (instead of the song's own window) and arms [PlayerPort.armBoundary]
     * at `plan.boundaryFileMs`. Null = the row keeps its own clip window.
     */
    val albumRun: com.levi.pocketdj.playback.album.AlbumRun.Plan? = null,
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

    /**
     * PB-10: keep exactly the given row in engine window slot 1 behind the current one (replacing
     * whatever was there), or empty the slot when [request] is null. Returns true when the engine
     * now matches the ask. Default: engines without a preload window do nothing.
     */
    suspend fun preloadNext(request: PlayRequest?): Boolean = false

    // ---- P2-ALB-4: album runs (one engine item per vinyl side) ------------------------------------------------------

    /**
     * Arm (or, with [fileMs] null, disarm) the end-of-song boundary of the loaded run item: when the playhead reaches
     * [fileMs] (absolute ms in the shared file) the engine reports [songId]'s natural end through
     * [SetlistSequencer.handleEnded]. [clipStartMs] is the item's clip start (so the engine can map file time to item
     * time). Exact (a player message) with a 250 ms poll fallback in the Media3 engine. Default: no-op.
     */
    fun armBoundary(songId: String, fileMs: Long?, clipStartMs: Long) {}

    /** What the engine holds when it holds a run item (a shared album file played as one item); null otherwise. */
    fun albumFileState(): AlbumFileState? = null

    /**
     * Seek the loaded run item to absolute file position [fileMs] (item time = file time - clip start). Always call this
     * BEFORE re-arming the boundary so a tick carrying the old position can never fire the new song's end. False when
     * the engine cannot (nothing loaded / the position lies before the item's clip start).
     */
    fun seekInFile(fileMs: Long): Boolean = false

    /**
     * Move the loaded run item's identity onto [item] without touching the audio (same URI + clip, new metadata and
     * media id; title/artist from the CURRENT catalog). When [startPlayback] the deck plays afterwards (a skip while
     * paused starts playback, exactly as a reload would). False when the engine did not retarget.
     */
    suspend fun retargetInPlace(item: QueueItem, startPlayback: Boolean): Boolean = false
    suspend fun pause()
    suspend fun resume()
    suspend fun seekTo(positionMs: Long)
    suspend fun stop()
}

/** The engine's view of a loaded run item (see [PlayerPort.albumFileState]). */
data class AlbumFileState(
    /** Media id of the loaded item (the song it is currently retitled to). */
    val mediaId: String,
    /** The item's clip start inside the shared file. */
    val clipStartMs: Long,
    /** The playhead as an absolute position in the shared file. */
    val fileMs: Long,
    /** The deck is audibly playing (not paused / buffering-idle). */
    val playing: Boolean,
)

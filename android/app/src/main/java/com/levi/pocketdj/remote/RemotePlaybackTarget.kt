package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.TransitionCause

/**
 * The local player a Remote session drives on a SPEAKER (iOS `RemotePlaybackTarget`) - an interface so the reconciler
 * is testable without audio. Production is [SequencerRemoteTarget]; tests and the showcase seed use
 * [InMemoryRemoteTarget].
 *
 * Reads are cheap by contract: [queueGeneration] changes on ANY queue mutation (so a 0.5 s observation tick can skip
 * the row walk when nothing moved), and rows are read one at a time. Rows are addressed by [QueueItem.uid].
 */
interface RemotePlaybackTarget {
    val queueGeneration: Long
    val queueCount: Int
    val currentIndex: Int
    val isRunning: Boolean
    fun item(at: Int): QueueItem
    val isPlaying: Boolean

    /** Song-relative position of the current row (ms). */
    val positionMs: Long
    val repeatMode: RepeatMode
    val shuffleEnabled: Boolean

    /** A track start / stall is in flight: play-state reads are not user intent right now. */
    val isTransitioning: Boolean

    /** Position reads are coarse (Apple Music's clock): drift needs a wider threshold. */
    val hasCoarsePosition: Boolean

    /** The SYSTEM silenced the audio (noisy, permanent focus loss, a transient loss that never resumed). A speaker must not resume it on its own. */
    val isSystemPaused: Boolean

    /** Bumped on every current-row change / restart, with WHY: only [TransitionCause.USER] is the listener's intent. */
    val transitionSeq: Long
    val lastTransitionCause: TransitionCause

    /** [transitionSeq] of the last USER transition. */
    val lastUserTransitionSeq: Long

    /** Bumped on every ▶/⏸ the listener pressed, with the state they asked for. */
    val userPlayIntentSeq: Long
    val lastUserPlayIntent: Boolean

    /** Start a fresh run ON [startIndex], [atMs] into that song; loaded PAUSED (nothing sounds) when [startPaused]. */
    fun play(items: List<QueueItem>, startIndex: Int, atMs: Long, startPaused: Boolean)

    /** Jump onto an upcoming row, starting it [atMs] in (the start cue travels with the jump). */
    fun jumpToUpcoming(uid: String, atMs: Long)

    /** Replace the first [count] upcoming rows with [items]; rows after them are kept. */
    fun replaceUpcoming(count: Int, items: List<QueueItem>)

    /** Insert [items] before the upcoming row [beforeUid] (null = append). */
    fun insertUpcoming(items: List<QueueItem>, beforeUid: String?)
    fun appendToQueue(items: List<QueueItem>)
    fun setPlaying(on: Boolean)
    fun seek(toMs: Long)
    fun setRepeatMode(mode: RepeatMode)
    fun setShuffle(on: Boolean)

    /** This device became a CONTROLLER: silence it and keep it silent (cancel any start in flight). */
    fun silenceForController()
}

val RemotePlaybackTarget.currentItem: QueueItem?
    get() = if (isRunning && currentIndex in 0 until queueCount) item(currentIndex) else null

/** The upcoming rows, capped (the session window never needs more). */
fun RemotePlaybackTarget.upcomingItems(limit: Int): List<QueueItem> {
    if (!isRunning) return emptyList()
    val lo = currentIndex + 1
    val hi = minOf(queueCount, lo + limit)
    return if (lo < hi) (lo until hi).map { item(it) } else emptyList()
}

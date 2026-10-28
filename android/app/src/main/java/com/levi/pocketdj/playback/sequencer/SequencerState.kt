package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.playback.PlayContext

/** Immutable snapshot of the sequencer, published after every mutation. */
data class SequencerState(
    val queue: List<QueueItem> = emptyList(),
    val index: Int = 0,
    val isRunning: Boolean = false,
    /** Restored session waiting for the first explicit play (no audio, no card). */
    val isHeldForResume: Boolean = false,
    val sourceSetlistId: String? = null,
    /** PB-4: the run's durable identity (`pses_...`); null while idle. */
    val sessionId: String? = null,
    val capturedContext: PlayContext? = null,
    /** (source token, collection id) of the run's navigable origin. */
    val capturedOrigin: Pair<String, String>? = null,
    val repeatMode: RepeatMode = RepeatMode.OFF,
    val shuffleEnabled: Boolean = false,
    /** User-visible one-shot message (e.g. device queue unplayable). */
    val playbackNotice: String? = null,
    /** The current row is a live capture with no natural end (scrubber disabled, "Next" offered). */
    val waitingForLive: Boolean = false,
    /** The cascade breaker halted the run: paused on the current row until the listener acts. */
    val pausedByCascade: Boolean = false,
    val playGeneration: Long = 0,
    /** A device-mode run ended having loaded no on-device file (one-shot banner signal). */
    val deviceQueueUnplayable: Boolean = false,
    val deviceUnplayableSourceId: String? = null,
) {
    val current: QueueItem? get() = if (isRunning) queue.getOrNull(index) else null

    /** `queue[index].id` while running, else null. */
    val currentSongId: String? get() = current?.id

    /** The not-yet-played tail (empty when idle or on the last track). */
    val upcoming: List<QueueItem>
        get() = if (isRunning && index + 1 < queue.size) queue.subList(index + 1, queue.size) else emptyList()

    /** The already-played head, oldest first. */
    val played: List<QueueItem>
        get() = if (isRunning && index > 0) queue.subList(0, minOf(index, queue.size)) else emptyList()
}

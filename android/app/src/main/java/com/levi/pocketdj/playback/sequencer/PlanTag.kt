package com.levi.pocketdj.playback.sequencer

/**
 * A Pocket Wheel run row's provenance (iOS `SetlistPlayer.PlanTag`): which run placed the row, at which slot, for
 * which collection, with what score - and whether the listener has since MOVED it ([pinned]). Rows with no plan
 * (the listener's own) or a pinned plan are NEVER replaced by a re-plan. [runId] is the UUID string the durable
 * snapshot stores.
 */
data class PlanTag(
    val runId: String,
    val slot: Int,
    val collectionId: String? = null,
    val score: Double = 0.0,
    val pinned: Boolean = false,
)

/** Run-tag prefix of a Pocket Wheel run's source id (iOS `PocketWheelIds.runTagPrefix`). */
const val POCKET_WHEEL_RUN_PREFIX = "pwr_"

/** Seconds of the current track that must remain for `queue[index + 1]` to be replaceable (iOS 30). */
const val REPLACE_NEXT_MIN_RUNWAY_SECONDS = 30.0

/** How many rows after the current one the prefetch / preload window covers (iOS `prefetchAhead`). */
const val PREFETCH_AHEAD = 3

/** A run row a re-plan may consider, with the facts the planner needs (iOS `ReplaceableRow`). */
data class ReplaceableRow(
    val uid: String,
    val songId: String,
    val slot: Int,
    val collectionId: String?,
    /** A rip is in flight for it: only an instant / on-device replacement may take its place. */
    val requiresInstant: Boolean,
    val prevSongId: String?,
    val nextSongId: String?,
)

/** A local transport a Remote-session CONTROLLER refuses and forwards instead of sounding here (iOS `RemoteRedirect`). */
sealed interface TransportRedirect {
    data object PlayPause : TransportRedirect
    data class SetPlaying(val on: Boolean) : TransportRedirect
    data object SkipNext : TransportRedirect
    data object SkipPrevious : TransportRedirect
    data class Play(val items: List<QueueItem>, val startIndex: Int) : TransportRedirect
    data class PlayNow(val item: QueueItem) : TransportRedirect
    data class Jump(val uid: String) : TransportRedirect

    /** An internal (re)start of the current row (cascade retry, stray reclaim): refused while a controller, never forwarded. */
    data object LocalStart : TransportRedirect
}

package com.levi.pocketdj.playback.sequencer

import java.util.UUID

/**
 * One row of the sequencer's queue (iOS `SetlistPlayer.Item`). [uid] is the per-INSTANCE
 * identity (a song can repeat in a set) that every live-queue edit addresses; [id] is the song.
 */
data class QueueItem(
    val id: String,
    val title: String = id,
    val artist: String? = null,
    val lengthMs: Long? = null,
    /** Total plays before advance; null = once. */
    val repeatCount: Int? = null,
    /** Edition variant token when the edition decider substituted one (e.g. "clean"). */
    val variant: String? = null,
    /** The user picked this edition explicitly - the decider must not substitute it. */
    val editionLocked: Boolean = false,
    /** Storage id actually resolved (a variant id, e.g. `sng_x_clean`); defaults to [id]. */
    val resolveId: String = id,
    /**
     * Clean-only collection + an explicit song with NO clean edition (Q94): the row stays in the queue
     * (indexes, Up Next, stall hops unchanged) but is never resolved, loaded or preloaded - the
     * sequencer advances past it (UNPLAYABLE_HERE).
     */
    val cleanOnlySkip: Boolean = false,
    /** Tag for rows appended by a game run; carried into the play's [com.levi.pocketdj.playback.PlayContext]. */
    val runTag: String? = null,
    val uid: String = UUID.randomUUID().toString(),
    /**
     * Pocket Wheel run provenance (iOS `Item.plan`); null for every row the listener added by hand. Excluded from
     * equality like iOS. Rows with no plan, or a pinned one, are never replaced by a re-plan.
     */
    val plan: PlanTag? = null,
    /**
     * DJ Mode: the LISTENER put this row in the NEXT-UP slot (Play Next, a drag to the top, a landing at next).
     * Only ever meaningful on `index + 1`; spent when the row plays. Rides the snapshot (`Row.djUserNext`).
     * Excluded from equality like [plan].
     */
    val djUserNext: Boolean = false,
    /**
     * DJ Mode AGING (iOS `Item.djDeferrals`): how many re-plans pushed this row later. In memory only (not in the
     * snapshot), like iOS. Excluded from equality.
     */
    val djDeferrals: Int = 0,
) {
    /** The listener has since moved this run row (iOS `plan.pinned`): a re-plan never touches it. */
    val pinned: Boolean get() = plan?.pinned == true

    /** This row with its plan (if any) pinned - the listener's claim on it. A planless row is unchanged. */
    fun pinnedCopy(): QueueItem = if (plan == null || plan.pinned) this else copy(plan = plan.copy(pinned = true))

    // Identity-bearing fields only: [plan] and [djUserNext] are provenance flags (iOS excludes them from ==).
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is QueueItem) return false
        return id == other.id && title == other.title && artist == other.artist && lengthMs == other.lengthMs &&
            repeatCount == other.repeatCount && variant == other.variant && editionLocked == other.editionLocked &&
            resolveId == other.resolveId && cleanOnlySkip == other.cleanOnlySkip && runTag == other.runTag &&
            uid == other.uid
    }

    override fun hashCode(): Int {
        var h = id.hashCode()
        h = 31 * h + title.hashCode()
        h = 31 * h + (artist?.hashCode() ?: 0)
        h = 31 * h + (lengthMs?.hashCode() ?: 0)
        h = 31 * h + (repeatCount ?: 0)
        h = 31 * h + (variant?.hashCode() ?: 0)
        h = 31 * h + editionLocked.hashCode()
        h = 31 * h + resolveId.hashCode()
        h = 31 * h + cleanOnlySkip.hashCode()
        h = 31 * h + (runTag?.hashCode() ?: 0)
        h = 31 * h + uid.hashCode()
        return h
    }

    /** Is [observedId] this row (its song id OR its substituted storage id)? */
    fun matches(observedId: String): Boolean = observedId == id || observedId == resolveId

    /** A fresh copy with a NEW uid (play-now of a played row must not duplicate an instance identity). */
    fun freshInstance(): QueueItem = copy(uid = UUID.randomUUID().toString())
}

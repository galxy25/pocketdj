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
    /** Tag for rows appended by a game run; carried into the play's [com.levi.pocketdj.playback.PlayContext]. */
    val runTag: String? = null,
    val uid: String = UUID.randomUUID().toString(),
) {
    /** Is [observedId] this row (its song id OR its substituted storage id)? */
    fun matches(observedId: String): Boolean = observedId == id || observedId == resolveId

    /** A fresh copy with a NEW uid (play-now of a played row must not duplicate an instance identity). */
    fun freshInstance(): QueueItem = copy(uid = UUID.randomUUID().toString())
}

package com.levi.pocketdj.mix.engine

import com.levi.pocketdj.data.jukebox.JukeboxDecisionAction
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.Deck
import com.levi.pocketdj.mix.model.LoadedTrack
import com.levi.pocketdj.mix.model.MixLoadable

/**
 * Jukebox Hero seams over a running auto mix. While a jukebox BROADCAST rides an auto-mix the
 * setlist is the shared concept: guests see the on-air track + the queue's tail, and accepted
 * requests are INSERTED into the auto queue. In-mix actions always take precedence: inserts never
 * land before [committedBound] (the first index no deck has committed to), so a track already
 * loaded/preloaded on a deck is never displaced, and shuffle/remove/move only touch uncommitted rows.
 */

/** The first queue index NO deck has committed to yet (clamped to the queue). */
internal val AutoDj.committedBound: Int
    get() = minOf(maxOf(nextToLoad, livePos + 1), queue.size)

/** What's ON AIR for jukebox guests: the live deck's track, else whichever deck is audibly playing, else null. */
val AutoDj.onAirTrack: LoadedTrack?
    get() {
        if (isMixing) return engine.loaded(liveDeck)
        if (engine.isPlaying(Deck.A)) return engine.loaded(Deck.A)
        if (engine.isPlaying(Deck.B)) return engine.loaded(Deck.B)
        return null
    }

/**
 * STREAMING: is the on-air audio waiting for downloaded bytes? The deck [onAirTrack] reads is
 * buffering, or, mid-transition, the INCOMING deck the mix is fading into is still waiting with
 * play intent. Drives the "Buffering..." indicator on the remote surfaces and the Mix banner.
 */
val AutoDj.onAirBuffering: Boolean
    get() {
        if (isMixing) {
            if (engine.streamHeld(liveDeck)) return true
            val incoming = liveDeck.other
            return autoTransitioning && engine.streamHeld(incoming) && engine.isPlaying(incoming)
        }
        return Deck.entries.any { engine.isPlaying(it) && engine.streamHeld(it) }
    }

/** The queue's not-yet-reached tail (position order): the guests' "up next". Empty unless auto-mixing. */
val AutoDj.autoUpcoming: List<MixLoadable>
    get() = if (!isMixing || livePos + 1 >= queue.size) emptyList()
    else queue.subList(livePos + 1, queue.size).map { it.loadable }

/** [autoUpcoming] with per-row provenance (the crate the track came from). */
val AutoDj.autoUpcomingDetailed: List<Pair<MixLoadable, String?>>
    get() = if (!isMixing || livePos + 1 >= queue.size) emptyList()
    else queue.subList(livePos + 1, queue.size).map { it.loadable to it.sourceLabel }

/** The queue's consumed head, NEWEST FIRST: the "previously played" list. Empty unless auto-mixing. */
val AutoDj.autoPlayed: List<MixLoadable>
    get() = if (!isMixing || livePos <= 0) emptyList()
    else queue.subList(0, minOf(livePos, queue.size)).map { it.loadable }.reversed()

val AutoDj.autoPlayedDetailed: List<Pair<MixLoadable, String?>>
    get() = if (!isMixing || livePos <= 0) emptyList()
    else queue.subList(0, minOf(livePos, queue.size)).map { it.loadable to it.sourceLabel }.reversed()

/** How many of [autoUpcoming]'s leading rows are COMMITTED (a deck holds them) and so cannot move/vanish. */
val AutoDj.autoUpcomingLockedCount: Int
    get() = if (!isMixing) 0 else maxOf(0, minOf(nextToLoad, queue.size) - (livePos + 1))

/** Shuffle the not-yet-committed tail. The in-flight transition and the preloaded on-deck track always win. */
fun AutoDj.autoQueueShuffleUpcoming() {
    if (!isMixing) return
    val lo = committedBound
    if (queue.size - lo <= 1) return
    val tail = queue.subList(lo, queue.size)
    tail.shuffle(shuffleRandom)
    prefetchUpcoming()
    refreshStatus()
    engine.persist()
}

/** Remove a not-yet-committed upcoming row (offset into [autoUpcoming]). No-op for committed / out-of-range rows. */
fun AutoDj.autoQueueRemoveUpcoming(offset: Int) {
    if (!isMixing) return
    val idx = livePos + 1 + offset
    if (idx < committedBound || idx >= queue.size) return
    queue.removeAt(idx)
    prefetchUpcoming()
    refreshStatus()
    engine.persist()
}

/** Move a not-yet-committed upcoming row to NEXT (right after the committed head) or END. */
fun AutoDj.autoQueueMoveUpcoming(offset: Int, toEnd: Boolean) {
    if (!isMixing) return
    val idx = livePos + 1 + offset
    val lo = committedBound
    if (idx < lo || idx >= queue.size) return
    val item = queue.removeAt(idx)
    queue.add(if (toEnd) queue.size else lo, item)
    prefetchUpcoming()
    refreshStatus()
    engine.persist()
}

/**
 * Insert a track into the RUNNING auto queue for the jukebox request line. The low bound is
 * [committedBound]. `slot` picks the RANDOM position within `lo..size`. No-op when not auto-mixing
 * or when the decision is a denial.
 */
fun AutoDj.autoQueueInsert(
    item: AutoMixItem,
    placement: JukeboxDecisionAction,
    slot: (IntRange) -> Int = { it.random(shuffleRandom) },
) {
    if (!isMixing) return
    val lo = committedBound
    val at = when (placement) {
        JukeboxDecisionAction.NEXT -> lo
        JukeboxDecisionAction.END -> queue.size
        JukeboxDecisionAction.RANDOM -> slot(lo..queue.size).coerceIn(lo, queue.size)
        JukeboxDecisionAction.DENIED -> return
    }
    queue.add(at, item)
    prefetchUpcoming()
    refreshStatus()   // the "x / count" readout grew by one
    engine.persist()  // a guest's accepted request must survive a force-quit
}

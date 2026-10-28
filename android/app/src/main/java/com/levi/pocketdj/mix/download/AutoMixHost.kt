package com.levi.pocketdj.mix.download

import com.levi.pocketdj.mix.model.AutoMixItem

/** Where a late arrival lands in a running auto queue (iOS `autoQueueInsert(placement:)`). */
enum class AutoPlacement { END, RANDOM }

/**
 * The slice of the Mix engine + stream loader the collection downloader drives. An interface so
 * the downloader is JVM-testable without audio, and so the Auto-DJ package (which owns
 * `startAutoMix` / `autoQueueInsert`) can implement it over the real engine.
 */
interface AutoMixHost {
    /** An auto mix exists (running or suspended). */
    val autoMixing: Boolean
    /** The last auto mix ran out of queue; armed until any manual deck activity. */
    val autoEndedExhausted: Boolean
    /** A deck is sounding. */
    val isRunning: Boolean
    /** Monotonic count of manual deck gestures (load/play). */
    val deckGestureGeneration: Int
    /** The crate label of the live auto mix (ownership check). */
    val autoSourceLabel: String?
    /** Song ids the running mix will play, in order (live slot onward). */
    val autoUpcomingSongIds: List<String>

    fun autoQueueInsert(item: AutoMixItem, placement: AutoPlacement)
    fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?)

    // ---- streaming seam (MixStreamLoader)
    fun isStreaming(songId: String): Boolean
    fun cancelStreams(songIds: List<String>)
    /** Streamed-byte deltas (count toward the ETA window). Null clears. */
    fun setStreamHooks(onBytes: ((String, Long) -> Unit)?, onFailed: ((String) -> Unit)?)
}

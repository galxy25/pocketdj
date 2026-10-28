package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.studio.model.StudioCue
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.map

/**
 * The deck's view of a track's positional cue points (Performance > Cues, keyed by songId). A seam so
 * the deck UI never depends on the Studio store directly and a JVM test can fake it.
 */
interface CuePointsProvider {
    fun cues(songId: String): List<StudioCue>

    /** Drop a cue at [positionMs] into [slot]; false when the store refused (all slots taken). */
    fun setCue(songId: String, slot: Int, positionMs: Int): Boolean

    /** Emits whenever any cue changes (any deck, or the Studio Cues editor); the deck row re-reads on each. */
    val changes: Flow<Any?> get() = emptyFlow()

    object None : CuePointsProvider {
        override fun cues(songId: String) = emptyList<StudioCue>()
        override fun setCue(songId: String, slot: Int, positionMs: Int) = false
    }
}

/** Production adapter over the app-scoped [StudioStore]. */
class StudioCuePoints(private val store: () -> StudioStore) : CuePointsProvider {
    override val changes: Flow<Any?> get() = store().state.map { it.cues }
    override fun cues(songId: String): List<StudioCue> = store().cues(songId)
    override fun setCue(songId: String, slot: Int, positionMs: Int): Boolean =
        store().setCue(songId, slot, positionMs) != null

    /** Lowest free slot, or null when all 8 are taken (shared with the Studio Cues tab). */
    fun dropAtNextFree(songId: String, positionMs: Int): StudioCue? {
        val taken = cues(songId).map { it.slot }.toSet()
        val free = (0 until StudioCue.MAX_SLOTS).firstOrNull { it !in taken } ?: return null
        return store().setCue(songId, free, positionMs)
    }
}

/** Stable per-slot chip color (matches the Studio Cues tab palette order). */
object CueSlotColors {
    private val palette = longArrayOf(
        0xFFFF453A, 0xFFFF9F0A, 0xFFFFD60A, 0xFF30D158, 0xFF64D2FF, 0xFF0A84FF, 0xFFBF5AF2, 0xFFFF375F,
    )

    fun argb(slot: Int): Long = palette[((slot % palette.size) + palette.size) % palette.size]
}

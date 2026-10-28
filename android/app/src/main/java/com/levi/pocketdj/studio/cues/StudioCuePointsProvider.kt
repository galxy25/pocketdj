package com.levi.pocketdj.studio.cues

import com.levi.pocketdj.screens.mix.CuePointsProvider
import com.levi.pocketdj.studio.model.StudioCue
import com.levi.pocketdj.studio.store.StudioStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * The Mix deck's cue-jump row and the Studio Cues tab share ONE store: a cue dropped on a deck shows in the
 * Cues editor and vice versa. [setCue] refuses (false) when the store refuses; [dropAtNextFree] picks the
 * lowest free slot and returns null when all 8 are taken.
 */
class StudioCuePointsProvider(private val store: () -> StudioStore) : CuePointsProvider {
    override val changes: Flow<Any?> get() = store().state.map { it.cues }
    override fun cues(songId: String): List<StudioCue> = store().cues(songId)
    override fun setCue(songId: String, slot: Int, positionMs: Int): Boolean =
        store().setCue(songId, slot, positionMs) != null

    fun dropAtNextFree(songId: String, positionMs: Int): StudioCue? {
        val free = (0 until StudioCue.MAX_SLOTS).firstOrNull { s -> cues(songId).none { it.slot == s } } ?: return null
        return store().setCue(songId, free, positionMs)
    }
}

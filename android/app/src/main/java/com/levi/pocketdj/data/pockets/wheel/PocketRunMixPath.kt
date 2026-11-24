package com.levi.pocketdj.data.pockets.wheel

import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable

/**
 * W7 (iOS `PocketRunStore.playThroughMix` + `PocketDJApp` closure): the pure rules for playing a Mix-mode pocket
 * run through Mix Auto-DJ. The run goes through Mix only when at least [MIN_LOADABLE] of its songs can be loaded on
 * the decks; below that the regular player takes it (with [fallbackCaption]). Every song the Mix plays is tagged back
 * to its run row by (songId, label) through `PocketRunStore.mixTag`.
 */
object PocketRunMixPath {
    const val MIN_LOADABLE = 10
    /** iOS fallback when a song has no known length. */
    const val FALLBACK_DURATION_MS = 180_000

    fun shouldPlayViaMix(loadable: Int): Boolean = loadable >= MIN_LOADABLE

    fun songIds(rows: List<PocketRunPlanner.Row>): List<String> = rows.map { it.songId }

    /** songId -> slot (first row wins on a duplicate id, like the planner's uniqueness). */
    fun slots(rows: List<PocketRunPlanner.Row>): Map<String, Int> {
        val m = LinkedHashMap<String, Int>()
        for (r in rows) m.putIfAbsent(r.songId, r.slot)
        return m
    }

    /** songId -> the row's collection id (rows without one are omitted). */
    fun collections(rows: List<PocketRunPlanner.Row>): Map<String, String> {
        val m = LinkedHashMap<String, String>()
        for (r in rows) r.collectionId?.let { m.putIfAbsent(r.songId, it) }
        return m
    }

    /**
     * Auto-DJ items for [loadables] (already deck-loadable, in run order), each stamped with [label] and its row's
     * origin collection. A loadable not in [songIds] is dropped; order follows [songIds], not [loadables].
     */
    fun items(
        songIds: List<String>, label: String, originCollections: Map<String, String>, loadables: List<MixLoadable>,
    ): List<AutoMixItem> {
        val byId = loadables.associateBy { it.songId }
        val seen = HashSet<String>()
        return songIds.mapNotNull { id ->
            val l = byId[id] ?: return@mapNotNull null
            if (!seen.add(id)) return@mapNotNull null
            AutoMixItem(l, l.lengthMs ?: FALLBACK_DURATION_MS, label, originCollections[id])
        }
    }

    fun fallbackCaption(loadable: Int): String =
        "Only $loadable of this run's songs are ready for the decks (need $MIN_LOADABLE), so it plays in the regular player."
}

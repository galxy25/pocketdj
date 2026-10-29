package com.levi.pocketdj.data.edition

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.playback.sequencer.EditionDecider
import com.levi.pocketdj.playback.sequencer.QueueItem

/**
 * The sequencer's real [EditionDecider] (iOS `editionDecider = EditionPolicy.decide(...)`): stamps `variant` /
 * `resolveId` on a queued row when the collection is clean-only or the global "Prefer explicit versions"
 * tri-state asks for the other edition. Always active (the clean-only flag is per run, unknown to the O(1) probe).
 */
class PolicyEditionDecider(
    private val preferExplicit: () -> Boolean?,
    private val song: (String) -> IndexSong?,
    private val isStored: (String) -> Boolean,
    private val ready: () -> Boolean = { true },
) : EditionDecider {
    override fun isActive(): Boolean = true
    override fun isReady(): Boolean = ready()

    override fun decide(item: QueueItem, cleanOnly: Boolean): QueueItem {
        val base = SongVariant.baseId(item.id)
        // Q94: a clean-only run never plays an explicit row that has no clean cut. Stamp, never remove.
        if (cleanOnly && EditionPolicy.isSkipped(song(base))) return item.copy(cleanOnlySkip = true)
        val d = EditionPolicy.decide(song(base), cleanOnly, preferExplicit())
        val edition = d.edition ?: return item
        val stored = EditionPolicy.resolveStored(base, d, isStored)
        // Wanted edition on disk, or (no stored copy at all) rip-on-demand under the wanted variant id.
        val id = when {
            stored == null -> if (d.catalogId.isNullOrEmpty()) return item else SongVariant.variantId(base, edition)
            stored.isWanted -> stored.id
            else -> return item   // global preference may degrade onto the stored primary cut
        }
        return item.copy(variant = edition.raw, resolveId = id)
    }
}

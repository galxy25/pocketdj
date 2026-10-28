package com.levi.pocketdj.data.discover

/**
 * Settlement state of a fanned-out album add (iOS `DiscoverAlbumAddState`, pure).
 *
 * An album is SETTLED once every track reached a TERMINAL state - ready (in the rips manifest) OR
 * failed (its rip job exhausted retries -> phase error). A settled album with fewer ready than total
 * tracks is PARTIAL: one track that never lands must not pin the row's spinner forever.
 */
sealed interface DiscoverAddState {
    /** Work still in flight (non-terminal tracks remain). */
    data class Adding(val ready: Int, val total: Int) : DiscoverAddState

    /** Settled, but some tracks failed - surface n/m. */
    data class Partial(val ready: Int, val total: Int) : DiscoverAddState

    /** Every track ready (or nothing to wait on). */
    data object Added : DiscoverAddState

    companion object {
        /**
         * [readyIds] = tracks present in the manifest; [erroredIds] = tracks whose rip job is in a
         * terminal error phase. Empty [trackIds] -> [Added] (a legacy album with no recorded tracks).
         */
        fun of(trackIds: List<String>, readyIds: Set<String>, erroredIds: Set<String>): DiscoverAddState {
            val total = trackIds.size
            val ready = trackIds.count { it in readyIds }
            val settled = trackIds.all { it in readyIds || it in erroredIds }
            if (settled && ready >= total) return Added
            if (settled) return Partial(ready, total)
            return Adding(ready, total)
        }

        /**
         * The state of a RECORDED album add. An add that never asked for copies has nothing to wait on
         * (`preparedCopies == false`), so it reads [Added] at once - otherwise a library-only add would
         * spin at 0/n forever. A null `preparedCopies` (a pre-split document) keeps the readout.
         */
        fun of(entry: DiscoverAddsStore.AlbumEntry, readyIds: Set<String>, erroredIds: Set<String>): DiscoverAddState {
            if (entry.preparedCopies == false) return Added
            return of(entry.trackIds.orEmpty(), readyIds, erroredIds + entry.failedTrackIds.orEmpty())
        }
    }
}

package com.levi.pocketdj.data.discover

import com.levi.pocketdj.data.discover.DiscoverAddState.Added
import com.levi.pocketdj.data.discover.DiscoverAddState.Adding
import com.levi.pocketdj.data.discover.DiscoverAddState.Partial
import org.junit.Assert.assertEquals
import org.junit.Test

class DiscoverAddStateTest {
    private val ids = listOf("a", "b", "c")

    @Test fun addingWhileAnyTrackIsNonTerminal() {
        assertEquals(Adding(0, 3), DiscoverAddState.of(ids, emptySet(), emptySet()))
        assertEquals(Adding(2, 3), DiscoverAddState.of(ids, setOf("a", "b"), emptySet()))
        // One failed, one still working -> still adding (not settled).
        assertEquals(Adding(1, 3), DiscoverAddState.of(ids, setOf("a"), setOf("b")))
    }

    @Test fun addedWhenEveryTrackReady() {
        assertEquals(Added, DiscoverAddState.of(ids, setOf("a", "b", "c"), emptySet()))
    }

    @Test fun partialWhenSettledWithAFailure() {
        assertEquals(Partial(2, 3), DiscoverAddState.of(ids, setOf("a", "b"), setOf("c")))
        assertEquals(Partial(0, 3), DiscoverAddState.of(ids, emptySet(), ids.toSet()))
    }

    @Test fun emptyTrackListHasNothingToWaitOn() {
        assertEquals(Added, DiscoverAddState.of(emptyList(), emptySet(), emptySet()))
    }

    @Test fun libraryOnlyAddsNeverSpin() {
        val e = DiscoverAddsStore.AlbumEntry(albumId = "al", appleMusicId = "1", trackIds = ids, preparedCopies = false)
        assertEquals(Added, DiscoverAddState.of(e, emptySet(), emptySet()))
    }

    @Test fun preparedAndLegacyAlbumsKeepTheProgressReadout() {
        val prepared = DiscoverAddsStore.AlbumEntry(albumId = "al", appleMusicId = "1", trackIds = ids, preparedCopies = true)
        val legacy = prepared.copy(preparedCopies = null) // written before add/download were split
        assertEquals(Adding(1, 3), DiscoverAddState.of(prepared, setOf("a"), emptySet()))
        assertEquals(Adding(1, 3), DiscoverAddState.of(legacy, setOf("a"), emptySet()))
        assertEquals(Partial(1, 3), DiscoverAddState.of(legacy, setOf("a"), setOf("b", "c")))
    }
}

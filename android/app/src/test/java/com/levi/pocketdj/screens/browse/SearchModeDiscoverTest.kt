package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.settings.BrowseSnapshot
import org.junit.Assert.assertEquals
import org.junit.Test

class SearchModeDiscoverTest {
    @Test fun discover_roundTripsThroughSnapshotString() {
        val state = BrowseSnapshot(searchMode = "discover").toSessionState()
        assertEquals(SearchMode.DISCOVER, state.searchMode)
        assertEquals("discover", state.toSnapshot().searchMode)
    }

    @Test fun unknownAndLegacyStrings_fallToDevice_onlineStaysOnline() {
        assertEquals(SearchMode.DEVICE, BrowseSnapshot(searchMode = "weird").toSessionState().searchMode)
        assertEquals(SearchMode.ONLINE, BrowseSnapshot(searchMode = "online").toSessionState().searchMode)
    }

    @Test fun discoverIsNotABrowseKind() {
        assertEquals(listOf("ALBUMS", "SONGS", "ARTISTS"), BrowseKind.entries.map { it.name })
    }
}

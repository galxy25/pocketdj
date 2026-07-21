package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.settings.BrowseSnapshot
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Round-trip of the persisted Browse snapshot (specs/browse.md §7) and the iron
 * law: an older/newer/corrupt doc decodes to sane values, never a wipe. The
 * DataStore layer is covered in AppSettingsStoreTest; this is the pure mapping +
 * serialization boundary.
 */
class BrowseSessionPersistenceTest {

    private val json: Json = PdjJson.lenient

    @Test
    fun roundTrip_preservesEveryPersistedField() {
        val state = BrowseSessionState(
            kind = BrowseKind.SONGS,
            layout = AlbumLayout.LIST,
            searchMode = SearchMode.ONLINE,
            filters = BrowseFilters(
                genres = setOf("hip-hop", "jazz"),
                bpmMin = 90.0,
                bpmMax = 140.0,
                camelots = setOf("8A", "3B"),
                sources = setOf("My Vinyl"),
            ),
            sortKeys = listOf(
                SortKey(SortField.BPM, ascending = false),
                SortKey(SortField.ARTIST, ascending = true),
            ),
        )
        // Through the JSON encode/decode boundary as well as the mapping.
        val encoded = json.encodeToString(BrowseSnapshot.serializer(), state.toSnapshot())
        val decoded = json.decodeFromString(BrowseSnapshot.serializer(), encoded).toSessionState()

        assertEquals(BrowseKind.SONGS, decoded.kind)
        assertEquals(AlbumLayout.LIST, decoded.layout)
        assertEquals(SearchMode.ONLINE, decoded.searchMode)
        assertEquals(setOf("hip-hop", "jazz"), decoded.filters.genres)
        assertEquals(90.0, decoded.filters.bpmMin!!, 0.0)
        assertEquals(140.0, decoded.filters.bpmMax!!, 0.0)
        assertEquals(setOf("8A", "3B"), decoded.filters.camelots)
        assertEquals(setOf("My Vinyl"), decoded.filters.sources)
        // Sort keys preserve order + direction.
        assertEquals(listOf(SortField.BPM, SortField.ARTIST), decoded.sortKeys.map { it.field })
        assertEquals(listOf(false, true), decoded.sortKeys.map { it.ascending })
    }

    @Test
    fun emptySnapshot_decodesToDefaults() {
        val state = BrowseSnapshot().toSessionState()
        assertEquals(BrowseKind.ALBUMS, state.kind)
        assertEquals(AlbumLayout.GRID, state.layout)
        assertEquals(SearchMode.DEVICE, state.searchMode)
        assertEquals(BrowseFilters(), state.filters)
        assertTrue(state.sortKeys.isEmpty())
    }

    @Test
    fun unknownEnumStrings_fallBackToSafeDefaults() {
        // A future/other build wrote kinds/modes this build doesn't understand.
        val snap = BrowseSnapshot(kind = "artists", layout = "carousel", searchMode = "discover")
        val state = snap.toSessionState()
        assertEquals(BrowseKind.ALBUMS, state.kind)
        assertEquals(AlbumLayout.GRID, state.layout)
        assertEquals(SearchMode.DEVICE, state.searchMode)
    }

    @Test
    fun unknownSortField_isDropped_knownKeysSurvive() {
        // "lastPlayedAt" is a real iOS field but not in the Android registry;
        // "totallyMadeUp" is nonsense. Both drop; "bpm" survives (iOS compactMap).
        val snap = BrowseSnapshot(
            sortKeys = listOf(
                BrowseSortKeyDoc("lastPlayedAt", true),
                BrowseSortKeyDoc("bpm", false),
                BrowseSortKeyDoc("totallyMadeUp", true),
            ),
        )
        val state = snap.toSessionState()
        assertEquals(listOf(SortField.BPM), state.sortKeys.map { it.field })
        assertEquals(false, state.sortKeys.single().ascending)
    }

    @Test
    fun oldDoc_missingNewerFields_decodesLeniently() {
        // An older build persisted only kind + layout (no sortKeys/searchMode/filters).
        val oldJson = """{"kind":"songs","layout":"list"}"""
        val snap = json.decodeFromString(BrowseSnapshot.serializer(), oldJson)
        val state = snap.toSessionState()
        assertEquals(BrowseKind.SONGS, state.kind)
        assertEquals(AlbumLayout.LIST, state.layout)
        assertEquals(SearchMode.DEVICE, state.searchMode) // defaulted
        assertTrue(state.sortKeys.isEmpty())
        assertEquals(BrowseFilters(), state.filters)
    }

    @Test
    fun futureDoc_withUnknownFields_ignoresThemAndKeepsKnown() {
        val futureJson = """
            {"kind":"songs","layout":"grid","searchMode":"device",
             "sortKeys":[{"field":"bpm","ascending":false,"weight":3}],
             "favoriteFilter":"only","brandNewField":{"x":1}}
        """.trimIndent()
        val snap = json.decodeFromString(BrowseSnapshot.serializer(), futureJson)
        val state = snap.toSessionState()
        assertEquals(BrowseKind.SONGS, state.kind)
        assertEquals(listOf(SortField.BPM), state.sortKeys.map { it.field })
        assertEquals(false, state.sortKeys.single().ascending)
    }
}

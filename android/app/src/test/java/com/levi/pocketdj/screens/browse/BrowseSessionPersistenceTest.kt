package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.settings.BrowseSnapshot
import com.levi.pocketdj.data.settings.BrowseSortKeyDoc
import com.levi.pocketdj.data.settings.ClauseDoc
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
            filters = BrowseFilters()
                .withGenres(setOf("hip-hop", "jazz"))
                .withBpm(90.0, 140.0)
                .withCamelots(setOf("8A", "3B"))
                .withSources(setOf("My Vinyl")),
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
        val snap = BrowseSnapshot(kind = "zzz", layout = "carousel", searchMode = "discover")
        val state = snap.toSessionState()
        assertEquals(BrowseKind.ALBUMS, state.kind)
        assertEquals(AlbumLayout.GRID, state.layout)
        assertEquals(SearchMode.DEVICE, state.searchMode)
    }

    @Test
    fun artistsKind_roundTrips() {
        // Widening the kind value space is additive (specs/artists.md §2.2): the
        // Artists kind writes "artists" and reads back ARTISTS.
        val encoded = BrowseSessionState(
            kind = BrowseKind.ARTISTS,
            layout = AlbumLayout.GRID,
            searchMode = SearchMode.DEVICE,
            filters = BrowseFilters(),
            sortKeys = emptyList(),
        ).toSnapshot()
        assertEquals("artists", encoded.kind)
        assertEquals(BrowseKind.ARTISTS, encoded.toSessionState().kind)
    }

    @Test
    fun unknownSortField_isDropped_knownKeysSurvive() {
        // "futureField" is not in this build's registry; "totallyMadeUp" is nonsense.
        // Both drop; "bpm" survives (iOS compactMap).
        val snap = BrowseSnapshot(
            sortKeys = listOf(
                BrowseSortKeyDoc("futureField", true),
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

    // ---- BRW-1: clauses ------------------------------------------------------

    @Test
    fun legacyFields_migrateToEquivalentClauses() {
        val legacy = BrowseSnapshot(
            genres = listOf("jazz", "rock"),
            bpmMin = 90.0,
            bpmMax = 140.0,
            camelots = listOf("8A"),
            sources = listOf("My Vinyl"),
        )
        val f = legacy.toSessionState().filters
        assertEquals(4, f.activeCount)
        assertEquals(setOf("jazz", "rock"), f.genres)
        assertEquals(setOf("8A"), f.camelots)
        assertEquals(setOf("My Vinyl"), f.sources)
        assertEquals(90.0, f.bpmMin!!, 0.0)
        assertEquals(140.0, f.bpmMax!!, 0.0)
        val bpm = f.clauses.single { it.field == "bpm" }
        assertEquals(FilterOp.BETWEEN, bpm.op)
        val genre = f.clauses.single { it.field == "genre" }
        assertEquals(FilterOp.IN_LIST, genre.op)
        // Open-ended legacy bpm keeps its open end.
        val openEnd = BrowseSnapshot(bpmMin = 100.0).toSessionState().filters.clauses.single()
        assertEquals(100.0, openEnd.min!!, 0.0)
        assertEquals(null, openEnd.max)
    }

    @Test
    fun legacyDocFromJson_decodesAndMigrates() {
        val old = """{"kind":"songs","genres":["jazz"],"bpmMin":120.0,"sources":["My Digital"]}"""
        val state = json.decodeFromString(BrowseSnapshot.serializer(), old).toSessionState()
        assertEquals(3, state.filters.activeCount)
        assertEquals(setOf("jazz"), state.filters.genres)
    }

    @Test
    fun clausesWin_overLegacyFieldsWhenPresent() {
        val snap = BrowseSnapshot(
            genres = listOf("jazz"),
            clauses = listOf(ClauseDoc("id1", "year", "between", min = 1988.0, max = 1994.0)),
        )
        val f = snap.toSessionState().filters
        assertEquals(1, f.clauses.size)
        assertEquals("year", f.clauses.single().field)
    }

    @Test
    fun explicitEmptyClauses_meansNoFilters_notLegacyMigration() {
        val snap = BrowseSnapshot(genres = listOf("jazz"), clauses = emptyList())
        assertEquals(0, snap.toSessionState().filters.activeCount)
    }

    @Test
    fun unknownFieldAndOpClauses_areDropped() {
        val snap = BrowseSnapshot(
            clauses = listOf(
                ClauseDoc("1", "futureField", "eq", value = "x"),
                ClauseDoc("2", "year", "wibble", value = "1990"),
                ClauseDoc("3", "bpm", "between", min = 100.0),
            ),
        )
        val clauses = snap.toSessionState().filters.clauses
        assertEquals(listOf("bpm"), clauses.map { it.field })
        assertEquals("3", clauses.single().id)
    }

    @Test
    fun clauses_roundTripThroughJson_andRetireLegacyFields() {
        val filters = BrowseFilters(
            listOf(
                Clause("year", FilterOp.BETWEEN, min = 1988.0, max = 1994.0),
                Clause("genre", FilterOp.NOT_IN_LIST, values = setOf("pop")),
                Clause("name", FilterOp.EQ, value = "x"),
                Clause("playCount", FilterOp.BETWEEN), // incomplete survives persistence (iOS parity)
            ),
        )
        val state = BrowseSessionState(
            BrowseKind.SONGS, AlbumLayout.GRID, SearchMode.DEVICE, filters,
            listOf(SortKey(SortField.PLAY_COUNT, false)),
        )
        val snap = state.toSnapshot()
        assertTrue(snap.genres.isEmpty() && snap.camelots.isEmpty() && snap.sources.isEmpty() && snap.bpmMin == null)
        val encoded = json.encodeToString(BrowseSnapshot.serializer(), snap)
        val back = json.decodeFromString(BrowseSnapshot.serializer(), encoded).toSessionState()
        assertEquals(filters.clauses, back.filters.clauses) // ids included
        assertEquals(3, back.filters.activeCount)
        assertEquals(listOf(SortField.PLAY_COUNT), back.sortKeys.map { it.field })
    }

    @Test
    fun iosShapedClauseJson_decodes() {
        val ios = """{"kind":"song","clauses":[{"id":"7E0C","field":"genre","op":"notInList","value":"","values":["Pop"]},
            {"id":"9A","field":"year","op":"between","value":"","values":[],"min":1988,"max":1994}]}"""
        val f = json.decodeFromString(BrowseSnapshot.serializer(), ios).toSessionState().filters
        assertEquals(FilterOp.NOT_IN_LIST, f.clauses[0].op)
        assertEquals(setOf("Pop"), f.clauses[0].values)
        assertEquals(1994.0, f.clauses[1].max!!, 0.0)
    }
}

package com.levi.pocketdj.data.search

import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.FilterOp
import com.levi.pocketdj.screens.browse.SortField
import com.levi.pocketdj.screens.browse.SortKey
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FilterQueryTranslationTest {
    private fun translate(vararg c: Clause): Pair<List<String>, List<String>> {
        val f = mutableListOf<JsonObject>()
        val n = mutableListOf<JsonObject>()
        c.forEach { FilterQuery.append(it, f, n) }
        return f.map { it.toString() } to n.map { it.toString() }
    }

    @Test fun genreMapsToGenreCategoryLowercased() {
        val (f, n) = translate(Clause("genre", FilterOp.EQ, value = "  Hip-Hop "))
        assertEquals(listOf("""{"term":{"genreCategory":"hip-hop"}}"""), f)
        assertTrue(n.isEmpty())
    }

    @Test fun nameMapsToTitleKeywordAndNeqGoesToMustNot() {
        val (f, n) = translate(Clause("name", FilterOp.NEQ, value = "Midnight"))
        assertTrue(f.isEmpty())
        assertEquals(listOf("""{"term":{"title.kw":"midnight"}}"""), n)
    }

    @Test fun numberEqEmitsIntWhenWholeDoubleOtherwise() {
        val (f, _) = translate(
            Clause("year", FilterOp.EQ, value = "1999"),
            Clause("bpm", FilterOp.EQ, value = "127.5"),
        )
        assertEquals("""{"term":{"year":1999}}""", f[0])
        assertEquals("""{"term":{"bpm":127.5}}""", f[1])
    }

    @Test fun numberBetweenIsRangeWithOptionalBounds() {
        val (f, _) = translate(
            Clause("bpm", FilterOp.BETWEEN, min = 120.0, max = 130.0),
            Clause("year", FilterOp.BETWEEN, min = 1990.0),
            Clause("length", FilterOp.BETWEEN, max = 300.0),
        )
        assertEquals("""{"range":{"bpm":{"gte":120,"lte":130}}}""", f[0])
        assertEquals("""{"range":{"year":{"gte":1990}}}""", f[1])
        assertEquals("""{"range":{"length":{"lte":300}}}""", f[2])
    }

    @Test fun inListIsTermsAndNotInListIsMustNotTerms() {
        val (f, n) = translate(
            Clause("camelot", FilterOp.IN_LIST, values = linkedSetOf("8A", " 9A ")),
            Clause("genre", FilterOp.NOT_IN_LIST, values = linkedSetOf("Rock", "Pop")),
            Clause("year", FilterOp.IN_LIST, values = linkedSetOf("1999", "2001")),
            Clause("trackNumber", FilterOp.NOT_IN_LIST, values = linkedSetOf("1")),
        )
        assertEquals("""{"terms":{"camelot":["8a","9a"]}}""", f[0])
        assertEquals("""{"terms":{"year":[1999,2001]}}""", f[1])
        assertEquals("""{"terms":{"genreCategory":["rock","pop"]}}""", n[0])
        assertEquals("""{"terms":{"trackNumber":[1]}}""", n[1])
    }

    @Test fun explicitEqIsBooleanTerm() {
        val (f, _) = translate(
            Clause("explicit", FilterOp.EQ, value = "true"),
            Clause("explicit", FilterOp.EQ, value = "false"),
        )
        assertEquals("""{"term":{"explicit":true}}""", f[0])
        assertEquals("""{"term":{"explicit":false}}""", f[1])
    }

    @Test fun sentimentUsesKeywordSubfield() {
        val (f, _) = translate(Clause("sentiment", FilterOp.EQ, value = "Dreamy"))
        assertEquals("""{"term":{"sentiment.kw":"dreamy"}}""", f[0])
    }

    @Test fun incompleteUnknownAndUnindexedFieldsAreSkipped() {
        val (f, n) = translate(
            Clause("genre", FilterOp.IN_LIST),                      // incomplete
            Clause("nope", FilterOp.EQ, value = "x"),               // unknown field
            Clause("playCount", FilterOp.BETWEEN, min = 3.0),       // device-local, not indexed
            Clause("dateAdded", FilterOp.BETWEEN, min = 3.0),       // not indexed
        )
        assertTrue(f.isEmpty() && n.isEmpty())
    }

    @Test fun sortMapsFieldsAndAlwaysEndsWithIdTiebreak() {
        val sort = SearchService.sortBody(
            listOf(SortKey(SortField.NAME, true), SortKey(SortField.BPM, false), SortKey(SortField.GENRE, true)),
        ).map { it.toString() }
        assertEquals(
            listOf(
                """{"title.kw":{"order":"asc"}}""",
                """{"bpm":{"order":"desc"}}""",
                """{"genreCategory":{"order":"asc"}}""",
                """{"id":{"order":"asc"}}""",
            ),
            sort,
        )
    }

    @Test fun unmappedSortFieldsAreDroppedAndEmptyKeysYieldOnlyId() {
        val sort = SearchService.sortBody(listOf(SortKey(SortField.PLAY_COUNT), SortKey(SortField.EXPLICIT)))
        assertEquals(listOf("""{"id":{"order":"asc"}}"""), sort.map { it.toString() })
        assertEquals(1, SearchService.sortBody(emptyList()).size)
    }

    @Test fun bodyComposesKindFilterClausesAndPagingFlags() {
        val body = SearchService.buildBody(
            "  midnight ", BrowseKind.SONGS,
            listOf(Clause("genre", FilterOp.NEQ, value = "Rock"), Clause("bpm", FilterOp.BETWEEN, min = 100.0)),
            emptyList(), from = 100, size = 50,
        )
        assertEquals(100, body["from"].toString().toInt())
        assertEquals("50", body["size"].toString())
        assertEquals("true", body["track_total_hits"].toString())
        val bool = body["query"]!!.jsonObject["bool"]!!.jsonObject
        assertEquals("""{"term":{"type":"song"}}""", bool["filter"]!!.jsonArray[0].toString())
        assertEquals(2, bool["filter"]!!.jsonArray.size)
        assertEquals(1, bool["must_not"]!!.jsonArray.size)
        assertFalse(body.toString().contains("match_all"))
    }
}

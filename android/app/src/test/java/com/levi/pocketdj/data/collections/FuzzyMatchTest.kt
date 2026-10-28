package com.levi.pocketdj.data.collections

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS FuzzyMatchTests. */
class FuzzyMatchTest {
    private val names = listOf(
        "80s Night", "Friday Night Mix", "Roadtrip", "Warmup",
        "Chill Sunday", "Night Owl", "Bangers", "Deep House 2024",
    )

    private fun ranked(q: String) = FuzzyMatch.rank(names, q) { it }

    @Test
    fun exactAndCaseAndPunctuationInsensitive() {
        assertNotNull(FuzzyMatch.score("80s night", "80s Night"))
        assertNotNull(FuzzyMatch.score("80S-NIGHT", "80s Night"))
        assertNotNull(FuzzyMatch.score("80snight", "80s Night"))
        val exact = FuzzyMatch.score("roadtrip", "Roadtrip")!!
        val loose = FuzzyMatch.score("roadtrip", "Roadtrip Reloaded")!!
        assertTrue(exact > loose)
    }

    @Test
    fun substringStillMatches() {
        assertEquals("Night Owl", ranked("night").first())
        assertTrue(ranked("night").contains("80s Night"))
        assertTrue(ranked("night").contains("Friday Night Mix"))
        assertFalse(ranked("night").contains("Roadtrip"))
    }

    @Test
    fun droppedCharactersFindTheName() {
        assertEquals(listOf("80s Night"), ranked("80snght"))
    }

    @Test
    fun initialsFindAMultiWordName() {
        assertEquals("Friday Night Mix", ranked("fnm").first())
    }

    @Test
    fun transposedLettersStillMatch() {
        assertEquals(listOf("80s Night"), ranked("80s Nigth"))
    }

    @Test
    fun substitutedAndExtraLetters() {
        assertEquals(listOf("Roadtrip"), ranked("roadtrup"))
        assertEquals(listOf("Bangers"), ranked("bangors"))
        assertEquals(listOf("Warmup"), ranked("warmupp"))
    }

    @Test
    fun typoWithinALongerName() {
        assertTrue(ranked("fridya").contains("Friday Night Mix"))
    }

    @Test
    fun nonsenseMatchesNothingAndBudgetScales() {
        assertEquals(emptyList<String>(), ranked("xyz"))
        assertNull(FuzzyMatch.score("zzzz", "80s Night"))
        assertEquals(0, FuzzyMatch.errorBudget(3))
        assertEquals(1, FuzzyMatch.errorBudget(4))
        assertEquals(1, FuzzyMatch.errorBudget(7))
        assertEquals(3, FuzzyMatch.errorBudget(12))
    }

    @Test
    fun emptyQueryReturnsEverythingInOrder() {
        assertEquals(names, ranked(""))
        assertEquals(names, ranked("   "))
        assertEquals(0.0, FuzzyMatch.score("", "anything")!!, 0.0)
    }

    @Test
    fun bestMatchFirstAndTiesStable() {
        assertEquals("Warmup", FuzzyMatch.rank(listOf("Warm Up Two", "Warmup"), "warmup") { it }.first())
        val list = listOf("Set A", "Set B", "Set C")
        assertEquals(list, FuzzyMatch.rank(list, "set") { it })
    }

    @Test
    fun diacriticsFold() {
        assertNotNull(FuzzyMatch.score("cafe", "Café Nights"))
        assertNotNull(FuzzyMatch.score("café", "Cafe Nights"))
    }

    @Test
    fun emptyCandidateNeverMatches() {
        assertNull(FuzzyMatch.score("mix", ""))
        assertNull(FuzzyMatch.score("mix", "  —  "))
    }

    @Test
    fun approximateDistanceIsSubstringAnchored() {
        val q = "night".toList()
        assertEquals(0, FuzzyMatch.approximateDistance(q, "80snight".toList()))
        assertEquals(1, FuzzyMatch.approximateDistance(q, "80snigth".toList()))
        assertEquals(1, FuzzyMatch.approximateDistance(q, "80snigt".toList()))
    }
}

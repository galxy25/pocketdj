package com.levi.pocketdj.assistant

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CollectionNameMatcherTest {
    private fun rank(q: String, vararg names: String) = CollectionNameMatcher.rank(q, names.toList()) { it }

    @Test
    fun spokenName_stripsLeadingMyThe_andTrailingKind() {
        assertEquals("workout", CollectionNameMatcher.spokenName("my workout playlist"))
        assertEquals("Late Night", CollectionNameMatcher.spokenName("  the Late Night pocket "))
        assertEquals("Focus", CollectionNameMatcher.spokenName("\"Focus collection\""))
        assertEquals("Mix", CollectionNameMatcher.spokenName("Mix"))
    }

    @Test
    fun rap_neverMatchesRainyAfternoonPop() {
        assertTrue(rank("Rap", "Rainy Afternoon Pop").isEmpty())
    }

    @Test
    fun initials_neverMatch() {
        assertTrue(rank("fnm", "Friday Night Mix").isEmpty())
        assertTrue(rank("wu", "Warmup").isEmpty())
    }

    @Test
    fun exactName_isNeverAmbiguous() {
        assertEquals(listOf("Rap"), rank("rap", "Rap", "Rap Classics", "Trap Rap Mix", "Rapture"))
        assertEquals(listOf("Workout"), rank("my workout playlist", "Workout", "Workout Extra"))
    }

    @Test
    fun equals_beatsPrefix_beatsContains() {
        val r = rank("jazz", "Late Night Jazz", "Jazz Standards", "Jazz")
        assertEquals("Jazz", r.first())
        val r2 = rank("jazz", "Late Night Jazz", "Jazz Standards")
        assertEquals(listOf("Jazz Standards"), r2) // prefix outranks contains by more than the band
    }

    @Test
    fun contains_matchesBuriedLiteral() {
        assertEquals(listOf("Late Night Warmup Mix"), rank("night warmup", "Late Night Warmup Mix", "Cooldown"))
    }

    @Test
    fun typo_onlyWhenNothingLiteral_andOnlyWholeName() {
        assertEquals(listOf("Workout"), rank("wrokout", "Workout", "Cooldown"))
        // A typo hit buried inside a longer name does not count.
        assertTrue(rank("wrokout", "Friday Workout Mix Extended Edition").isEmpty())
        // A literal hit suppresses the typo pass entirely.
        assertEquals(listOf("Workout"), rank("workout", "Workout", "Workuot"))
    }

    @Test
    fun shortQueries_getNoTypoTolerance() {
        assertTrue(rank("rop", "Rap").isEmpty())
    }

    @Test
    fun blankOrQuotesOnly_matchesNothing() {
        assertTrue(rank("   ", "Anything").isEmpty())
        assertTrue(rank("\"\"", "Anything").isEmpty())
    }

    @Test
    fun diacriticsAndPunctuationFold() {
        assertEquals(listOf("Café del Mar"), rank("cafe del mar", "Café del Mar"))
        assertEquals(listOf("Warm-Up!"), rank("warm up", "Warm-Up!"))
    }
}

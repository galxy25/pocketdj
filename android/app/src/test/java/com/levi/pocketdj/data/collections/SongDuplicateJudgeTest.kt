package com.levi.pocketdj.data.collections

import com.levi.pocketdj.data.collections.SongDuplicateJudge as J
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SongDuplicateJudgeTest {
    private fun id(n: String, a: String, al: String?, am: String? = null) = J.Identity(n, a, al, am)

    @Test fun featCreditMovedBetweenTitleAndArtist() {
        assertTrue(J.isSameReleaseDuplicate(
            id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout"),
            id("Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", "The College Dropout")))
        assertTrue(J.isSameReleaseDuplicate(
            id("Juicy (feat. Static Major)", "Pretty Ricky", "Bluestars"),
            id("Juicy Featuring Static Major", "Pretty Ricky", "Bluestars")))
        assertTrue(J.isSameReleaseDuplicate(
            id("Rather Be feat. Jess Glynne", "Clean Bandit, Jess Glynne", "New Eyes"),
            id("Rather Be (feat. Jess Glynne)", "Clean Bandit", "New Eyes")))
    }

    @Test fun respeltArtist() {
        assertTrue(J.isSameReleaseDuplicate(
            id("All I Need", "JAY Z", "The Blueprint"), id("All I Need", "JAŸ-Z", "The Blueprint")))
        assertTrue(J.isSameReleaseDuplicate(
            id("Hood Hop", "J Kwon", "Hood Hop"), id("Hood Hop", "J-Kwon", "Hood Hop")))
    }

    @Test fun differentAlbumNeverMatches() {
        assertFalse(J.isSameReleaseDuplicate(
            id("Never Let Me Down", "Kanye West", "The College Dropout"),
            id("Never Let Me Down", "Kanye West", "Late Registration")))
    }

    @Test fun differingCatalogIdsAreDistinct() {
        assertFalse(J.isSameReleaseDuplicate(
            id("E.T.", "Katy Perry", "Teenage Dream", "716084374"),
            id("E.T. (feat. Kanye West)", "Katy Perry", "Teenage Dream", "716085557")))
        // One side uncatalogued ⇒ ids don't veto.
        assertTrue(J.isSameReleaseDuplicate(
            id("E.T.", "Katy Perry", "Teenage Dream", "716084374"),
            id("E.T. (feat. Kanye West)", "Katy Perry", "Teenage Dream", null)))
    }

    @Test fun nonOverlappingFeatsAreDifferentVersion() {
        assertFalse(J.isSameReleaseDuplicate(
            id("Goodies (feat. Petey Pablo)", "Ciara", "Goodies"),
            id("Goodies (feat. T.I. & Jazze Pha)", "Ciara", "Goodies")))
    }

    @Test fun versionMarkersStayDistinct() {
        assertFalse(J.isSameReleaseDuplicate(id("Sap (Live)", "A", "Album"), id("Sap", "A", "Album")))
        assertFalse(J.isDuplicate(id("Sap (Live)", "A", "Album"), id("Sap", "A", "Album")))
    }

    @Test fun nonLatinTitlesAreNotCollapsed() {
        val a = id("희생양", "Epik High", "Remapping the Human Soul")
        val b = id("거미줄", "Epik High", "Remapping the Human Soul")
        assertFalse(J.isSameReleaseDuplicate(a, b))
        assertFalse(J.baseTitle("희생양").isEmpty())
        assertNotEquals(J.baseTitle("희생양"), J.baseTitle("거미줄"))
        assertTrue(J.isSameReleaseDuplicate(a, a.copy()))
    }

    @Test fun noAlbumNotComparableAtThisTier() {
        assertFalse(J.isSameReleaseDuplicate(id("X", "A", null), id("X (feat. B)", "A", null)))
        assertNull(J.releaseKey(id("X", "A", "")))
    }

    @Test fun exactTierIgnoresCaseDiacriticsQuotesWhitespace() {
        assertTrue(J.isExactDuplicate("What’s  Going On", "Marvin Gaye", "whats going on".replace("whats", "what's"), "marvin  gaye"))
        assertTrue(J.isExactDuplicate("Café", "Zoé", "cafe", "zoe"))
        assertFalse(J.isExactDuplicate("Sap (Live)", "A", "Sap", "A"))
    }

    @Test fun borderline() {
        assertTrue(J.isBorderline("Song", "A & B", "song", "A and B"))
        assertFalse(J.isBorderline("Song", "A", "Other", "B"))
    }

    @Test fun seenCatchesBothTiers() {
        val seen = J.Seen()
        assertTrue(seen.insert(id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout")))
        assertFalse(seen.insert(id("Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", "The College Dropout")))
        assertFalse(seen.insert(id("never let me down", "kanye west, jay-z & j-ivy", null)))
        assertTrue(seen.insert(id("All Falls Down", "Kanye West", "The College Dropout")))
    }

    @Test fun collapsePlanPrefersCatalogCopyEarliestSlot() {
        val table = mapOf(
            "a" to id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout"),
            "b" to id("All Falls Down", "Kanye West", "The College Dropout"),
            "c" to id("Never Let Me Down (feat. JAŸ-Z & J. Ivy)", "Kanye West", "The College Dropout", "1"),
            "d" to id("Never Let Me Down", "Kanye West, Jay-Z & J-Ivy", "The College Dropout"),
        )
        val plan = J.collapsePlan(listOf("a", "b", "c", "d", "zz")) { table[it] }
        assertEquals(mapOf("a" to "c"), plan.rename)
        assertEquals(setOf("c", "d"), plan.drop)
    }

    @Test fun repeatedSameIdIsNotATwin() {
        val table = mapOf("a" to id("X", "A", "Alb"))
        assertTrue(J.collapsePlan(listOf("a", "a"), table::get).isEmpty)
    }

    @Test fun romanNumeralsAreDistinct() {
        assertFalse(J.isDuplicate(id("Suite \u2161", "Band", "LP"), id("Suite \u2162", "Band", "LP")))
        assertNotEquals(J.loose("Part \u2161"), J.loose("Part \u2162"))
    }

    @Test fun devanagariVowelSignsAreDistinct() {
        assertFalse(J.isDuplicate(id("\u0915\u093F\u0924\u093E\u092C", "A", "LP"), id("\u0915\u0924\u093E\u092C", "A", "LP")))
    }

    @Test fun dakutenIsKept() {
        assertFalse(J.isDuplicate(id("\u304C", "A", "LP"), id("\u304B", "A", "LP")))
        assertFalse(J.isExactDuplicate("\u304C", "A", "\u304B", "A"))
        assertTrue(J.isExactDuplicate("Caf\u00E9", "A", "Cafe", "A"))
    }
}

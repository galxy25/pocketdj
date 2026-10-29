package com.levi.pocketdj.screens.jukebox

import com.levi.pocketdj.data.jukebox.JukeboxSessionRow
import org.junit.Assert.assertEquals
import org.junit.Test

class JukeboxSessionsPickerLogicTest {
    private val L = JukeboxSessionsPickerLogic

    @Test fun noneActiveAdopts() = assertEquals(SessionPickAction.ADOPT, L.decide(null, false, "b"))
    @Test fun sameActiveIsNoop() = assertEquals(SessionPickAction.ALREADY_HOSTING, L.decide("a", false, "a"))
    @Test fun differentActiveEndsThenAdopts() = assertEquals(SessionPickAction.END_THEN_ADOPT, L.decide("a", false, "b"))
    @Test fun busyIgnoresEverything() {
        listOf<String?>(null, "a", "b").forEach { assertEquals(SessionPickAction.IGNORE, L.decide(it, true, "b")) }
    }

    @Test fun ageBuckets() {
        assertEquals("expired", L.ageText(0))
        assertEquals("ends in <1 min", L.ageText(30_000))
        assertEquals("ends in 5 min", L.ageText(5 * 60_000L))
        assertEquals("ends in 3 h", L.ageText(3 * 3_600_000L))
        assertEquals("ends in 2 d", L.ageText(2 * 86_400_000L))
    }

    @Test fun detailStripsSchemeAndAppendsAge() {
        val row = JukeboxSessionRow("a", "Party", "https://x.io/j/a", expiresAt = 120_000.0)
        assertEquals("x.io/j/a · ends in 2 min", L.detail(row, 0))
        assertEquals("x.io/j/a", L.detail(row.copy(expiresAt = null), 0))
        assertEquals("", L.detail(JukeboxSessionRow("a"), 0))
    }
}

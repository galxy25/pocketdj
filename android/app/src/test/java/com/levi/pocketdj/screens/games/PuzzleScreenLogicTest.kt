package com.levi.pocketdj.screens.games

import com.levi.pocketdj.data.games.puzzle.PuzzleSampler
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

class PuzzleScreenLogicTest {
    private val L = PuzzleScreenLogic

    @Test fun poolCountVariants() {
        assertEquals("… songs match", L.poolCountText(null))
        assertEquals("42 songs match", L.poolCountText(PuzzleSampler.PoolStats(42, null)))
        assertEquals("42 match · 7 similar", L.poolCountText(PuzzleSampler.PoolStats(42, 7)))
        assertEquals("0 songs match", L.poolCountText(PuzzleSampler.PoolStats(0, null)))
    }

    @Test fun startDisabledOnlyOnComputedZero() {
        assertTrue(L.startEnabled(null))
        assertTrue(L.startEnabled(PuzzleSampler.PoolStats(1, null)))
        assertFalse(L.startEnabled(PuzzleSampler.PoolStats(0, null)))
        assertFalse(L.startEnabled(PuzzleSampler.PoolStats(0, 0)))
    }

    @Test fun timerFormatting() {
        assertEquals("2:00", L.timerText(120))
        assertEquals("0:09", L.timerText(9))
        assertEquals("4:59", L.timerText(299))
        assertEquals("0:00", L.timerText(-3))
        assertTrue(L.timerUrgent(9)); assertFalse(L.timerUrgent(10))
    }

    @Test fun yearParsing() {
        assertNull(L.parseYear(""))
        assertNull(L.parseYear("   "))
        assertNull(L.parseYear("19x"))
        assertEquals(1975, L.parseYear(" 1975 "))
        assertEquals("", L.yearText(null))
        assertEquals("1985", L.yearText(1985))
    }

    @Test fun targetsCapAtThreeKeepOrderAndToggle() {
        var t = emptyList<String>()
        for (id in listOf("a", "b", "c", "d")) t = L.toggleTarget(t, id)
        assertEquals(listOf("a", "b", "c"), t)
        assertEquals(listOf("a", "c"), L.toggleTarget(t, "b"))
        assertEquals(listOf("a", "b", "c"), L.appendTargetIfRoom(t, "a"))
        assertEquals(listOf("a", "b", "c"), L.appendTargetIfRoom(t, "z"))
        assertEquals(listOf("a", "z"), L.appendTargetIfRoom(listOf("a"), "z"))
    }

    @Test fun labelsAndFooter() {
        assertEquals("All genres", L.genresLabel(emptySet()))
        assertEquals("2", L.genresLabel(setOf("Funk", "Rock")))
        assertEquals("File into…", L.fileButtonLabel(false))
        assertEquals("Other…", L.fileButtonLabel(true))
        assertTrue(L.setupFooter(false).startsWith("No targets"))
        assertTrue(L.setupFooter(true).startsWith("One-tap"))
        assertEquals(listOf("1:00", "2:00", "3:00", "5:00"), L.ROUND_LENGTHS.map { it.second })
        assertEquals(setOf("a"), L.toggleIn(emptySet(), "a"))
        assertEquals(emptySet<String>(), L.toggleIn(setOf("a"), "a"))
    }
}

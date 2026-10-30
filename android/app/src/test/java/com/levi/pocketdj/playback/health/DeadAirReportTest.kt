package com.levi.pocketdj.playback.health

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DeadAirReportTest {
    private fun day(active: Double, dead: Double, gaps3: Int = 0, pairs: Map<String, DeadAirMeter.Pair> = emptyMap()) =
        DeadAirMeter.Day(activeSeconds = active, deadSeconds = dead, gapsOver3s = gaps3, byPair = pairs.toMutableMap())

    @Test fun label_formatsRatioDeadMinutesAndGaps() {
        assertEquals("5.0% · 30s dead / 10 min · 2 gaps≥3s", DeadAirReport.label(day(600.0, 30.0, 2)))
    }

    @Test fun label_emptyDayIsDash() {
        assertEquals("—", DeadAirReport.label(DeadAirMeter.Day()))
    }

    @Test fun worstPairs_sortedBySecondsTopFour() {
        val d = day(
            100.0, 10.0,
            pairs = mapOf(
                "a→b" to DeadAirMeter.Pair(1, 1.0, 1.0),
                "c→d" to DeadAirMeter.Pair(2, 20.0, 12.0),
                "e→f" to DeadAirMeter.Pair(1, 5.0, 5.0),
                "g→h" to DeadAirMeter.Pair(1, 3.0, 3.0),
                "i→j" to DeadAirMeter.Pair(1, 9.0, 9.0),
            ),
        )
        assertEquals(listOf("c→d", "i→j", "e→f", "g→h"), DeadAirReport.worstPairs(d).map { it.first })
    }

    @Test fun pairLabel_avgAndMax() {
        assertEquals("2× avg 10.0s max 12s", DeadAirReport.pairLabel(DeadAirMeter.Pair(2, 20.0, 12.0)))
    }

    @Test fun lastDays_excludesTodayAndIdle_newestFirst_cappedAtN() {
        val doc = DeadAirMeter.Document(
            linkedMapOf(
                "2026-10-29" to day(10.0, 1.0),
                "2026-10-28" to day(10.0, 1.0),
                "2026-10-27" to day(0.0, 0.0),
                "2026-10-26" to day(10.0, 1.0),
                "2026-10-25" to day(10.0, 1.0),
            ),
        )
        assertEquals(listOf("2026-10-28", "2026-10-26"), DeadAirReport.lastDays(2, doc, "2026-10-29").map { it.first })
        assertEquals(3, DeadAirReport.lastDays(7, doc, "2026-10-29").size)
    }

    @Test fun rows_todayFirstThenDaysThenPairs_andSummaryJoins() {
        val doc = DeadAirMeter.Document(
            linkedMapOf(
                "2026-10-29" to day(60.0, 3.0, pairs = mapOf("x→y" to DeadAirMeter.Pair(1, 2.0, 2.0))),
                "2026-10-28" to day(120.0, 0.0),
            ),
        )
        val rows = DeadAirReport.rows(doc, "2026-10-29")
        assertEquals(listOf("Today", "2026-10-28", "x→y"), rows.map { it.label })
        assertTrue(DeadAirReport.label(day(60.0, 3.0)).startsWith("5.0%"))
    }

    @Test fun summary_readsLiveMeterToday() {
        var now = 1_800_000_000_000L
        val m = DeadAirMeter(file = null, zone = { java.time.ZoneOffset.UTC }, log = {}, nowMs = { now })
        m.accumulate(active = 60.0, dead = 6.0, transitionDead = 6.0, nowMs = now)
        val text = DeadAirReport.summary(m, now)
        assertTrue(text, text.startsWith("Today: 10.0% · 6s dead / 1 min"))
    }
}

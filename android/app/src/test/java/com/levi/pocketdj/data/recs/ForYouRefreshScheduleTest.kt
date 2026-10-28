package com.levi.pocketdj.data.recs

import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ForYouRefreshScheduleTest {
    private val la = ZoneId.of("America/Los_Angeles")
    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int) = ZonedDateTime.of(y, mo, d, h, mi, 0, 0, la)
    private fun ms(t: ZonedDateTime) = t.toInstant().toEpochMilli().toDouble()
    private val fri1620 = ForYouRefreshSchedule.DEFAULT_MINUTES

    @Test fun defaultsAreWeeklyFridayFourTwenty() {
        assertEquals(ForYouRefreshCadence.WEEKLY, ForYouRefreshSchedule.DEFAULT_CADENCE)
        assertEquals(16 * 60 + 20, ForYouRefreshSchedule.DEFAULT_MINUTES)
        assertEquals(6, ForYouRefreshSchedule.DEFAULT_WEEKDAY)
        assertEquals("Friday", ForYouRefreshSchedule.weekdayName(6, java.util.Locale.US))
        assertEquals("Sunday", ForYouRefreshSchedule.weekdayName(1, java.util.Locale.US))
        assertEquals("Saturday", ForYouRefreshSchedule.weekdayName(99, java.util.Locale.US))
    }

    @Test fun manualHasNoFireAndIsNeverDue() {
        val now = at(2026, 10, 28, 12, 0)
        assertNull(ForYouRefreshSchedule.lastFire(now, ForYouRefreshCadence.MANUAL, fri1620, 6))
        assertNull(ForYouRefreshSchedule.nextFire(now, ForYouRefreshCadence.MANUAL, fri1620, 6))
        assertFalse(ForYouRefreshSchedule.isDue(ms(now), 0.0, ForYouRefreshCadence.MANUAL, fri1620, 6, la))
    }

    @Test fun hourlyUsesMinutePastEveryHour() {
        val before = at(2026, 10, 28, 15, 10) // :20 slot not yet reached this hour
        assertEquals(at(2026, 10, 28, 14, 20), ForYouRefreshSchedule.lastFire(before, ForYouRefreshCadence.HOURLY, fri1620, 6))
        val after = at(2026, 10, 28, 15, 25)
        assertEquals(at(2026, 10, 28, 15, 20), ForYouRefreshSchedule.lastFire(after, ForYouRefreshCadence.HOURLY, fri1620, 6))
        assertEquals(at(2026, 10, 28, 16, 20), ForYouRefreshSchedule.nextFire(after, ForYouRefreshCadence.HOURLY, fri1620, 6))
    }

    @Test fun dailyRollsBackToYesterdayBeforeTheSlot() {
        val morning = at(2026, 10, 28, 9, 0)
        assertEquals(at(2026, 10, 27, 16, 20), ForYouRefreshSchedule.lastFire(morning, ForYouRefreshCadence.DAILY, fri1620, 6))
        val evening = at(2026, 10, 28, 18, 0)
        assertEquals(at(2026, 10, 28, 16, 20), ForYouRefreshSchedule.lastFire(evening, ForYouRefreshCadence.DAILY, fri1620, 6))
        assertEquals(at(2026, 10, 29, 16, 20), ForYouRefreshSchedule.nextFire(evening, ForYouRefreshCadence.DAILY, fri1620, 6))
    }

    @Test fun weeklyOnTargetDayBeforeSlotReturnsLastWeek() {
        // Fri 2026-10-30 10:00 -> slot (16:20) still ahead -> previous Friday
        val fri = at(2026, 10, 30, 10, 0)
        assertEquals(at(2026, 10, 23, 16, 20), ForYouRefreshSchedule.lastFire(fri, ForYouRefreshCadence.WEEKLY, fri1620, 6))
        val friLate = at(2026, 10, 30, 17, 0)
        assertEquals(at(2026, 10, 30, 16, 20), ForYouRefreshSchedule.lastFire(friLate, ForYouRefreshCadence.WEEKLY, fri1620, 6))
    }

    @Test fun weeklyAcrossTheDstWeekKeepsWallClockTime() {
        // US DST ended Sun 2026-11-01. Monday after: last fire is Fri 10-30 16:20 PDT, next Fri 11-06 16:20 PST.
        val mon = at(2026, 11, 2, 10, 0)
        val last = ForYouRefreshSchedule.lastFire(mon, ForYouRefreshCadence.WEEKLY, fri1620, 6)!!
        assertEquals(at(2026, 10, 30, 16, 20), last)
        assertEquals(-7 * 3600, last.offset.totalSeconds)
        val next = ForYouRefreshSchedule.nextFire(mon, ForYouRefreshCadence.WEEKLY, fri1620, 6)!!
        assertEquals(at(2026, 11, 6, 16, 20), next)
        assertEquals(-8 * 3600, next.offset.totalSeconds)
        // 7 calendar days but 7d1h of elapsed time
        assertEquals(7 * 24 * 3600L + 3600, next.toEpochSecond() - last.toEpochSecond())
    }

    @Test fun weeklyHonoursOtherWeekdays() {
        // Sunday = 1: now Wed 10-28 -> last Sunday 10-25 at the slot
        val wed = at(2026, 10, 28, 12, 0)
        assertEquals(at(2026, 10, 25, 16, 20), ForYouRefreshSchedule.lastFire(wed, ForYouRefreshCadence.WEEKLY, fri1620, 1))
        // Saturday = 7
        assertEquals(at(2026, 10, 24, 16, 20), ForYouRefreshSchedule.lastFire(wed, ForYouRefreshCadence.WEEKLY, fri1620, 7))
    }

    @Test fun monthlyFiresOnTheFirst() {
        val mid = at(2026, 10, 28, 12, 0)
        assertEquals(at(2026, 10, 1, 16, 20), ForYouRefreshSchedule.lastFire(mid, ForYouRefreshCadence.MONTHLY, fri1620, 6))
        assertEquals(at(2026, 11, 1, 16, 20), ForYouRefreshSchedule.nextFire(mid, ForYouRefreshCadence.MONTHLY, fri1620, 6))
        val early = at(2026, 10, 1, 8, 0)
        assertEquals(at(2026, 9, 1, 16, 20), ForYouRefreshSchedule.lastFire(early, ForYouRefreshCadence.MONTHLY, fri1620, 6))
    }

    @Test fun missedSlotFiresOnNextOpen() {
        // Cache from Fri 10-23 17:00 (after that week's slot). Phone off all weekend; opened Mon 10-26.
        val cache = ms(at(2026, 10, 23, 17, 0))
        val mon = at(2026, 10, 26, 9, 0)
        // last slot is still Fri 10-23 16:20 and cache is newer -> NOT due
        assertFalse(ForYouRefreshSchedule.isDue(ms(mon), cache, ForYouRefreshCadence.WEEKLY, fri1620, 6, la))
        // opened the Saturday after the NEXT Friday's slot -> cache predates it -> due (fires late, once)
        val sat = at(2026, 10, 31, 8, 0)
        assertTrue(ForYouRefreshSchedule.isDue(ms(sat), cache, ForYouRefreshCadence.WEEKLY, fri1620, 6, la))
        // and after the refresh stamps "now", it cannot loop
        assertFalse(ForYouRefreshSchedule.isDue(ms(sat), ms(sat), ForYouRefreshCadence.WEEKLY, fri1620, 6, la))
    }

    @Test fun neverRefreshedIsDueUnderAnySchedule() {
        val now = at(2026, 10, 28, 12, 0)
        assertTrue(ForYouRefreshSchedule.isDue(ms(now), 0.0, ForYouRefreshCadence.DAILY, fri1620, 6, la))
        assertTrue(ForYouRefreshSchedule.isDue(ms(now), 0.0, ForYouRefreshCadence.MONTHLY, fri1620, 6, la))
    }

    @Test fun staleStampDueOnlyWhenOlderThanLastFire() {
        val now = at(2026, 10, 28, 16, 30) // daily slot 16:20 passed 10 min ago
        assertTrue(ForYouRefreshSchedule.isDue(ms(now), ms(at(2026, 10, 28, 16, 0)), ForYouRefreshCadence.DAILY, fri1620, 6, la))
        assertFalse(ForYouRefreshSchedule.isDue(ms(now), ms(at(2026, 10, 28, 16, 25)), ForYouRefreshCadence.DAILY, fri1620, 6, la))
    }

    @Test fun minutesAndWeekdayClampAndCadenceNormalizes() {
        val bad = ForYouSettings.normalize("fortnightly", 99999, -3)
        assertEquals(ForYouRefreshCadence.WEEKLY, bad.cadence)
        assertEquals(1439, bad.minutesOfDay)
        assertEquals(1, bad.weekday)
        val missing = ForYouSettings.normalize(null, null, null)
        assertEquals(ForYouScheduleSettings(), missing)
        assertEquals(ForYouRefreshCadence.HOURLY, ForYouSettings.normalize("hourly", 5, 2).cadence)
        // clamped minutes still fire at that minute
        val now = at(2026, 10, 28, 12, 0)
        assertEquals(at(2026, 10, 27, 23, 59), ForYouRefreshSchedule.lastFire(now, ForYouRefreshCadence.DAILY, 99999, 6))
    }
}

package com.levi.pocketdj.data.applemusic

import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoSyncScheduleTest {
    private val utc = ZoneId.of("UTC")
    private fun ms(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int = 0): Double =
        ZonedDateTime.of(y, mo, d, h, mi, s, 0, utc).toInstant().toEpochMilli().toDouble()

    private val fire = AppleMusicAutoSync.DEFAULT_MINUTES

    @Test fun defaultIs1620() {
        assertEquals(16 * 60 + 20, fire)
        assertEquals("4:20 PM", AmSyncSettings.timeLabel(fire))
        assertEquals("12:05 AM", AmSyncSettings.timeLabel(5))
        assertEquals("12:00 PM", AmSyncSettings.timeLabel(720))
    }

    @Test fun isDueBoundaries() {
        // Before today's fire time: never due, even with no prior run.
        assertFalse(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 16, 19, 59), null, fire, utc))
        // At the fire instant: due.
        assertTrue(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 16, 20), null, fire, utc))
        // Ran today after the slot: not due; ran exactly at the slot: not due (not BEFORE it).
        assertFalse(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 20, 0), ms(2026, 10, 28, 16, 21), fire, utc))
        assertFalse(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 20, 0), ms(2026, 10, 28, 16, 20), fire, utc))
        // Last run a second before today's slot: due.
        assertTrue(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 20, 0), ms(2026, 10, 28, 16, 19, 59), fire, utc))
        // Missed yesterday's slot entirely, opening the app at 09:00 today: NOT due until today's slot...
        assertFalse(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 9, 0), ms(2026, 10, 26, 17, 0), fire, utc))
        // ...and due afterwards (a missed slot fires on the next launch after it).
        assertTrue(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 17, 0), ms(2026, 10, 26, 17, 0), fire, utc))
        // Yesterday's evening run does not satisfy today's slot.
        assertTrue(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 16, 20), ms(2026, 10, 27, 23, 0), fire, utc))
        // 0 = never run (the settings store's sentinel).
        assertTrue(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 17, 0), 0.0, fire, utc))
    }

    @Test fun isDueClampsMinutesAndHonoursZone() {
        // Out-of-range minutes clamp to 23:59 / 00:00.
        assertFalse(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 23, 58), null, 99999, utc))
        assertTrue(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 23, 59), null, 99999, utc))
        assertTrue(AppleMusicAutoSync.isDue(ms(2026, 10, 28, 0, 0), null, -50, utc))
        // 16:20 in Los Angeles is a different instant than 16:20 UTC.
        val la = ZoneId.of("America/Los_Angeles")
        val at1620Utc = ms(2026, 10, 28, 16, 20)
        assertTrue(AppleMusicAutoSync.isDue(at1620Utc, null, fire, utc))
        assertFalse(AppleMusicAutoSync.isDue(at1620Utc, null, fire, la)) // 09:20 local
    }

    private class State(var last: Double? = null, var enabled: Boolean = true, var now: Double = 0.0)

    private fun gate(s: State) = AutoSyncGate(
        enabled = { s.enabled }, minutesOfDay = { fire },
        lastRunMs = { s.last }, setLastRunMs = { s.last = it },
        nowMs = { s.now }, zone = utc,
    )

    @Test fun claimBeforeRun() = runBlocking {
        val s = State(now = ms(2026, 10, 28, 17, 0))
        var stampSeenByPass: Double? = null
        val ran = gate(s).runIfDue { stampSeenByPass = s.last }
        assertTrue(ran)
        // The claim was stamped BEFORE the pass body started.
        assertEquals(s.now, stampSeenByPass)
        // A second trigger (foreground after launch) the same day does nothing.
        assertFalse(gate(s).runIfDue { error("must not run twice") })
        // Next day after the slot it is due again.
        s.now = ms(2026, 10, 29, 16, 30)
        assertTrue(gate(s).runIfDue { })
    }

    @Test fun claimBeforeRunSingleFlightsConcurrentTriggers() = runBlocking {
        val s = State(now = ms(2026, 10, 28, 17, 0))
        val g = gate(s)
        val runs = AtomicInteger()
        // launch + foreground + periodic tick all land together; the pass is slow.
        val results = (1..3).map { async(kotlinx.coroutines.Dispatchers.Default) { g.runIfDue { runs.incrementAndGet(); delay(50) } } }.awaitAll()
        assertEquals(1, runs.get())
        assertEquals(1, results.count { it })
    }

    @Test fun disabledNeverClaims() = runBlocking {
        val s = State(enabled = false, now = ms(2026, 10, 28, 17, 0))
        assertFalse(gate(s).runIfDue { error("disabled") })
        assertEquals(null, s.last)
    }
}

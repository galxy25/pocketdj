package com.levi.pocketdj.data.recs

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.TextStyle
import java.util.Locale

/** How often For You re-ranks itself. Raw values are the persisted/wire strings (iOS parity). */
enum class ForYouRefreshCadence(val raw: String, val label: String) {
    /** No automatic refresh. Only the menu Refresh (and the cold-install build) recompute. */
    MANUAL("manual", "Only when I ask"),
    /** At minutesOfDay % 60 past EVERY hour. */
    HOURLY("hourly", "Hourly"),
    DAILY("daily", "Daily"),
    /** THE DEFAULT (Friday 16:20). */
    WEEKLY("weekly", "Weekly"),
    /** On the 1st, at the chosen local time. */
    MONTHLY("monthly", "Monthly");

    companion object {
        fun fromRaw(raw: String?): ForYouRefreshCadence? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Pure schedule arithmetic (port of iOS `ForYouRefreshSchedule`). Due-ness is evaluated at READ
 * time (tab open / foreground), never by a timer; a missed slot fires on the next open; a refresh
 * that bails (empty catalog) does not move the stamp so it retries. Weekday numbering is the
 * iOS `Calendar` one: 1 = Sunday ... 7 = Saturday (Friday = 6).
 */
object ForYouRefreshSchedule {
    val DEFAULT_CADENCE = ForYouRefreshCadence.WEEKLY
    const val DEFAULT_MINUTES = 16 * 60 + 20
    const val DEFAULT_WEEKDAY = 6
    val MINUTES_RANGE = 0..1439
    val WEEKDAY_RANGE = 1..7

    fun clampMinutes(m: Int): Int = m.coerceIn(0, 1439)
    fun clampWeekday(w: Int): Int = w.coerceIn(1, 7)

    /** Calendar weekday (1 = Sunday) -> localized full name. */
    fun weekdayName(weekday: Int, locale: Locale = Locale.getDefault()): String {
        val w = clampWeekday(weekday)
        // 1 = Sunday -> DayOfWeek.SUNDAY (7); 2 = Monday -> 1; ...
        val dow = if (w == 1) DayOfWeek.SUNDAY else DayOfWeek.of(w - 1)
        return dow.getDisplayName(TextStyle.FULL, locale)
    }

    private fun calendarWeekday(t: ZonedDateTime): Int = (t.dayOfWeek.value % 7) + 1

    private fun instant(hour: Int, minute: Int, day: LocalDate, zone: ZoneId): ZonedDateTime =
        ZonedDateTime.of(day, LocalTime.of(hour, minute), zone)

    /** The most recent scheduled instant at or before [now]; null for MANUAL. */
    fun lastFire(
        now: ZonedDateTime,
        cadence: ForYouRefreshCadence,
        minutesOfDay: Int,
        weekday: Int,
    ): ZonedDateTime? {
        if (cadence == ForYouRefreshCadence.MANUAL) return null
        val mins = clampMinutes(minutesOfDay)
        val hour = mins / 60
        val minute = mins % 60
        val zone = now.zone
        return when (cadence) {
            ForYouRefreshCadence.MANUAL -> null
            ForYouRefreshCadence.HOURLY -> {
                val candidate = now.withMinute(minute).withSecond(0).withNano(0)
                if (!candidate.isAfter(now)) candidate else candidate.minusHours(1)
            }
            ForYouRefreshCadence.DAILY -> {
                val candidate = instant(hour, minute, now.toLocalDate(), zone)
                if (!candidate.isAfter(now)) candidate else instant(hour, minute, now.toLocalDate().minusDays(1), zone)
            }
            ForYouRefreshCadence.WEEKLY -> {
                val target = clampWeekday(weekday)
                // 8 days, not 7: today may be the target weekday with its fire time still ahead.
                for (back in 0..8) {
                    val candidate = instant(hour, minute, now.toLocalDate().minusDays(back.toLong()), zone)
                    if (candidate.isAfter(now)) continue
                    if (calendarWeekday(candidate) != target) continue
                    return candidate
                }
                null
            }
            ForYouRefreshCadence.MONTHLY -> {
                val first = now.toLocalDate().withDayOfMonth(1)
                val candidate = instant(hour, minute, first, zone)
                if (!candidate.isAfter(now)) candidate else instant(hour, minute, first.minusMonths(1), zone)
            }
        }
    }

    /** The next scheduled instant after [now] — the Settings readout. */
    fun nextFire(
        now: ZonedDateTime,
        cadence: ForYouRefreshCadence,
        minutesOfDay: Int,
        weekday: Int,
    ): ZonedDateTime? {
        val last = lastFire(now, cadence, minutesOfDay, weekday) ?: return null
        val zone = now.zone
        val mins = clampMinutes(minutesOfDay)
        return when (cadence) {
            ForYouRefreshCadence.MANUAL -> null
            ForYouRefreshCadence.HOURLY -> last.plusHours(1)
            ForYouRefreshCadence.DAILY -> instant(mins / 60, mins % 60, last.toLocalDate().plusDays(1), zone)
            ForYouRefreshCadence.WEEKLY -> instant(mins / 60, mins % 60, last.toLocalDate().plusDays(7), zone)
            ForYouRefreshCadence.MONTHLY -> instant(mins / 60, mins % 60, last.toLocalDate().plusMonths(1), zone)
        }
    }

    /**
     * Is a refresh due? True when the most recent scheduled instant has passed AND the cached feed
     * predates it. Never refreshed (stamp <= 0) with a schedule on is due. MANUAL is never due.
     */
    fun isDue(
        nowMs: Double,
        lastRefreshedAtMs: Double,
        cadence: ForYouRefreshCadence,
        minutesOfDay: Int,
        weekday: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Boolean {
        if (cadence == ForYouRefreshCadence.MANUAL) return false
        val now = ZonedDateTime.ofInstant(Instant.ofEpochMilli(nowMs.toLong()), zone)
        val fire = lastFire(now, cadence, minutesOfDay, weekday) ?: return false
        if (lastRefreshedAtMs <= 0) return true
        return lastRefreshedAtMs < fire.toInstant().toEpochMilli().toDouble()
    }
}

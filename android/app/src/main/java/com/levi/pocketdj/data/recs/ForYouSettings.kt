package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey

/** Persisted For You refresh schedule (iOS `forYouRefreshCadence/Minutes/Weekday`). */
data class ForYouScheduleSettings(
    val cadence: ForYouRefreshCadence = ForYouRefreshSchedule.DEFAULT_CADENCE,
    val minutesOfDay: Int = ForYouRefreshSchedule.DEFAULT_MINUTES,
    val weekday: Int = ForYouRefreshSchedule.DEFAULT_WEEKDAY,
)

object ForYouSettings {
    /** Persisted DataStore key names — never rename once shipped. */
    val CADENCE = PrefKey.string("forYouRefreshCadence", ForYouRefreshSchedule.DEFAULT_CADENCE.raw)
    val MINUTES = PrefKey.int("forYouRefreshMinutes", ForYouRefreshSchedule.DEFAULT_MINUTES)
    val WEEKDAY = PrefKey.int("forYouRefreshWeekday", ForYouRefreshSchedule.DEFAULT_WEEKDAY)

    /** Unknown cadence -> default; minutes/weekday clamped (same as iOS load). */
    fun normalize(cadenceRaw: String?, minutes: Int?, weekday: Int?) = ForYouScheduleSettings(
        cadence = ForYouRefreshCadence.fromRaw(cadenceRaw) ?: ForYouRefreshSchedule.DEFAULT_CADENCE,
        minutesOfDay = ForYouRefreshSchedule.clampMinutes(minutes ?: ForYouRefreshSchedule.DEFAULT_MINUTES),
        weekday = ForYouRefreshSchedule.clampWeekday(weekday ?: ForYouRefreshSchedule.DEFAULT_WEEKDAY),
    )

    suspend fun load(store: AppSettingsStore): ForYouScheduleSettings =
        normalize(store.get(CADENCE), store.get(MINUTES), store.get(WEEKDAY))

    suspend fun save(store: AppSettingsStore, s: ForYouScheduleSettings) {
        store.set(CADENCE, s.cadence.raw)
        store.set(MINUTES, ForYouRefreshSchedule.clampMinutes(s.minutesOfDay))
        store.set(WEEKDAY, ForYouRefreshSchedule.clampWeekday(s.weekday))
    }
}

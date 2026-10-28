package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.settings.PrefKey

/**
 * Write-back settings (iOS `SettingsStore.writeBackBackfillDays`): how far back "Send my adds"
 * re-drives queued adds from the collection history. The persisted name is frozen.
 */
object WriteBackSettings {
    const val BACKFILL_DEFAULT_DAYS = 2
    const val BACKFILL_MAX_DAYS = 90

    val BACKFILL_DAYS = PrefKey.int("writeBackBackfillDays", BACKFILL_DEFAULT_DAYS)

    /** Window clamp 1..90 (applied on read AND before use, so a hand-edited value can't escape). */
    fun clampDays(days: Int): Int = days.coerceIn(1, BACKFILL_MAX_DAYS)
}

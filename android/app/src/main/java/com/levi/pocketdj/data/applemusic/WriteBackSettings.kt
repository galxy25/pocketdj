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

/** Pure copy for the Settings "Send my adds" status line (iOS `runCollections` strings). */
object WriteBackStatus {
    fun sendLine(canWriteBack: Boolean, newlyQueued: Int): String = when {
        !canWriteBack -> "Adds: unavailable on this device."
        newlyQueued == 0 -> "Adds: nothing new to send"
        else -> "Adds: sending $newlyQueued song${if (newlyQueued == 1) "" else "s"} to Apple Music"
    }

    fun lookbackLabel(days: Int): String = "$days day${if (days == 1) "" else "s"}"
}

/** Pure user-feedback copy for "Force Apple Music sync" (iOS `CollectionForceSync.writeBackLine`). */
object ForceSyncMessages {
    fun line(
        attempt: com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt,
        canWriteBack: Boolean,
        unsyncable: Boolean,
    ): String = when (attempt) {
        com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt.NOT_LINKED ->
            "This collection isn\u2019t linked to an Apple Music playlist, so there\u2019s no playlist to add it to."
        com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt.PUSH_DISABLED ->
            "Sending to Apple Music is turned off for this collection (its sync is Get only / Off)."
        com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt.NOT_CATALOG_SONG ->
            "This item isn\u2019t an Apple Music catalog track, so it can\u2019t be added to a playlist."
        com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt.NO_IDENTITY ->
            "This track has no Apple Music identity, so it can\u2019t be added to a playlist."
        com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt.QUEUED ->
            "Sending it to the linked Apple Music playlist now."
        com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt.DEDUPED,
        com.levi.pocketdj.data.collections.CollectionsStore.WriteBackAttempt.ALREADY_UPSTREAM -> when {
            !canWriteBack -> "Apple Music playlists can\u2019t be edited from this device, so it stays in your local copy."
            unsyncable -> "Apple Music has no confident match, so it can\u2019t be added to the linked playlist."
            else -> "It\u2019s already on its way to the linked Apple Music playlist."
        }
    }
}

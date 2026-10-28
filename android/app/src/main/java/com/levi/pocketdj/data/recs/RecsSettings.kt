package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.settings.PrefKey

/** Device-local rec-engine prefs (iOS `SettingsStore`; UserDefaults there, never profile-synced). */
object RecsSettings {
    /** "Use PocketDJ Recommendation Engine" — default OFF; nothing leaves the device until ON. */
    val REC_ENGINE_ENABLED = PrefKey.boolean("recEngineEnabled", false)

    /** "Include lifetime play counts" — default ON (a considered choice, see iOS doc). */
    val SHARE_LIFETIME_PLAY_COUNTS = PrefKey.boolean("shareLifetimePlayCounts", true)
}

package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.settings.PrefKey

/**
 * Apple Music playlist-sync settings (iOS `SettingsStore` amAutoSyncEnabled / amAutoSyncMinutes /
 * lastAMAutoSyncAtMs / amImportNewPlaylists). Persisted names are frozen to the iOS keys.
 */
object AmSyncSettings {
    /** Daily unattended sync; default ON. */
    val AUTO_ENABLED = PrefKey.boolean("amAutoSyncEnabled", true)

    /** Minutes past local midnight; default 16:20 (Levi 2026-07-29: "default to 4:20 pm"). */
    val AUTO_MINUTES = PrefKey.int("amAutoSyncMinutes", AppleMusicAutoSync.DEFAULT_MINUTES)

    /** Epoch ms of the last CLAIMED auto run; 0 = never (iOS stores nil). */
    val LAST_AUTO_MS = PrefKey.double("lastAMAutoSyncAtMs", 0.0)

    /** Pull also imports Apple Music playlists with no local counterpart. Default OFF (safe). */
    val IMPORT_NEW = PrefKey.boolean("amImportNewPlaylists", false)

    /**
     * Debug/emulator override for the Lambda base (point at a MockWebServer). Blank = live
     * endpoint config. Android-only; not part of any iOS document.
     */
    val BASE_OVERRIDE = PrefKey.string("amPlaylistSyncBaseOverride", "")

    fun clampMinutes(m: Int): Int = m.coerceIn(0, 1439)

    /** "4:20 PM" style label for a minutes-of-day value. */
    fun timeLabel(minutes: Int): String {
        val m = clampMinutes(minutes)
        val h24 = m / 60
        val h12 = if (h24 % 12 == 0) 12 else h24 % 12
        return "%d:%02d %s".format(h12, m % 60, if (h24 < 12) "AM" else "PM")
    }
}

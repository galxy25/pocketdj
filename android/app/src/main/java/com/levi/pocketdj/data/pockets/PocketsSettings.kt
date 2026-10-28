package com.levi.pocketdj.data.pockets

import com.levi.pocketdj.data.settings.PrefKey

/** Device-local listening-pockets prefs (iOS `SettingsStore`; never profile-synced). */
object PocketsSettings {
    /** "Find my listening pockets" - default OFF; also requires the rec engine ON to open the gate. */
    val LISTENING_POCKETS_ENABLED = PrefKey.boolean("listeningPocketsEnabled", false)

    /** "Places & trips" - collection exists only to feed pockets, so it is forced OFF when the gate closes. */
    val LISTENING_LOCATION_ENABLED = PrefKey.boolean("listeningLocationEnabled", false)

    /** What turning pockets on sends - shown wherever the switch can be flipped (iOS `consentText`). */
    const val CONSENT_TEXT =
        "Turning this on sends, for each play in the last 90 days and from now on: the song and its artist, " +
            "when it started (to the minute) and your time-zone offset, whether you finished or skipped it, " +
            "where in the app you played it (which collection, by id), and whether CarPlay was connected. " +
            "It also sends which songs are in each of your pockets and playlists and when you added them " +
            "(ids only, never their names). PocketDJ uses it to find the stretches where you were in a groove."
}

package com.levi.pocketdj.data.settings

import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey

/**
 * A typed, defaulted preference key (decision D3). Every package declares its keys
 * in its OWN `*Settings.kt` file and reads/writes them through the generic
 * [AppSettingsStore.get] / [AppSettingsStore.set] / [AppSettingsStore.flow] — the
 * store itself never needs another edit.
 *
 * [name] is the persisted DataStore key name: once shipped it must never change
 * (additive-optional iron law — a missing key just yields [default]).
 */
class PrefKey<T> private constructor(
    val name: String,
    val default: T,
    internal val key: Preferences.Key<T>,
) {
    override fun toString(): String = "PrefKey($name)"

    companion object {
        fun string(name: String, default: String = ""): PrefKey<String> =
            PrefKey(name, default, stringPreferencesKey(name))

        fun boolean(name: String, default: Boolean = false): PrefKey<Boolean> =
            PrefKey(name, default, booleanPreferencesKey(name))

        fun int(name: String, default: Int = 0): PrefKey<Int> =
            PrefKey(name, default, intPreferencesKey(name))

        fun long(name: String, default: Long = 0L): PrefKey<Long> =
            PrefKey(name, default, longPreferencesKey(name))

        fun float(name: String, default: Float = 0f): PrefKey<Float> =
            PrefKey(name, default, floatPreferencesKey(name))

        fun double(name: String, default: Double = 0.0): PrefKey<Double> =
            PrefKey(name, default, doublePreferencesKey(name))

        fun stringSet(name: String, default: Set<String> = emptySet()): PrefKey<Set<String>> =
            PrefKey(name, default, stringSetPreferencesKey(name))
    }
}

/**
 * The keys that existed before the generic store. Their persisted NAMES are frozen
 * (pinned by PrefKeyTest) — an upgrade must read what the previous build wrote.
 */
object LegacyPrefKeys {
    val SOURCES_JSON = PrefKey.string("sourcesJson")
    val RIP_SERVER_URL = PrefKey.string("ripServerUrl")
    val RIP_TOKEN = PrefKey.string("ripToken")
    val JUKEBOX_SERVER_URL = PrefKey.string("jukeboxServerUrl")
    val JUKEBOX_TOKEN = PrefKey.string("jukeboxToken")
    val JUKEBOX_TOKENS_REQUIRED = PrefKey.boolean("jukeboxTokensRequiredByDefault", true)
    val ONLINE_SEARCH_ENABLED = PrefKey.boolean("onlineSearchEnabled", false)
    val INSTALL_ID = PrefKey.string("installId")
    val BROWSE_SNAPSHOT_JSON = PrefKey.string("browseSnapshotJson")
    val COLLECTION_SORT = PrefKey.string("collectionSort", "name")
    val PLAYLISTS_MODE = PrefKey.string("playlistsMode", "user")
    val COLLAPSED_FOLDER_IDS = PrefKey.stringSet("collapsedFolderIds")
    val EXPANDED_SOURCE_NAMES = PrefKey.stringSet("expandedSourceNames")
    val MUSIC_USER_TOKEN = PrefKey.string("musicUserToken")
    val AM_DEV_TOKEN = PrefKey.string("appleMusicDeveloperToken")
    val AM_DEV_TOKEN_EXP = PrefKey.long("appleMusicDeveloperTokenExpiresAt", 0L)

    /** Set once the plaintext secrets have been moved into SecretStore. */
    val SECRETS_MIGRATED = PrefKey.boolean("secretsMigratedV1", false)

    /** The last-visited shell section token (shell/LastSectionStore). */
    val LAST_SECTION = PrefKey.string("lastSection", "")
}

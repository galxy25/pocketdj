package com.levi.pocketdj.data.jukebox

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import com.levi.pocketdj.data.PdjJson
import java.io.IOException
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json

/**
 * Persists the live jukebox session so an app relaunch re-adopts a running
 * party (specs/jukebox.md §4.1). Keys mirror the iOS UserDefaults names
 * (`pdj.jukebox.session.v1` + `pdj.jukebox.hear.v1`).
 *
 * Additive-safe: the session doc decodes with the lenient [PdjJson] (unknown
 * keys ignored, later field additions default), and a corrupt doc folds to
 * "no session" instead of crashing.
 */
class JukeboxSessionStore(
    private val dataStore: DataStore<Preferences>,
    private val json: Json = PdjJson.lenient,
) {
    data class Persisted(
        val session: JukeboxSessionInfo,
        val hear: Boolean,
    )

    private object Keys {
        val SESSION_JSON = stringPreferencesKey("pdj.jukebox.session.v1")
        val HEAR = booleanPreferencesKey("pdj.jukebox.hear.v1")
    }

    /** The persisted session, or null (absent, corrupt, or unreadable disk). */
    suspend fun load(): Persisted? {
        val prefs = runCatching { dataStore.data.first() }
            .getOrElse { error -> if (error is IOException) emptyPreferences() else throw error }
        val raw = prefs[Keys.SESSION_JSON] ?: return null
        val session = runCatching { json.decodeFromString<JukeboxSessionInfo>(raw) }
            .getOrNull() ?: return null
        return Persisted(session = session, hear = prefs[Keys.HEAR] ?: false)
    }

    suspend fun save(session: JukeboxSessionInfo) {
        val encoded = json.encodeToString(JukeboxSessionInfo.serializer(), session)
        dataStore.edit { it[Keys.SESSION_JSON] = encoded }
    }

    suspend fun setHear(hear: Boolean) {
        dataStore.edit { it[Keys.HEAR] = hear }
    }

    /** Fold the party: forget the session AND the hear flag. */
    suspend fun clear() {
        dataStore.edit {
            it.remove(Keys.SESSION_JSON)
            it.remove(Keys.HEAR)
        }
    }
}

package com.levi.pocketdj.data.credentials

import android.content.Context
import android.content.SharedPreferences
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.levi.pocketdj.data.settings.LegacyPrefKeys
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first

/**
 * Where every secret lives (decision D6): rip token, jukebox token, Music-User-Token
 * and — in later packages — search creds, diag key, profile secret. Non-secret prefs
 * stay in DataStore; a secret never does.
 */
interface SecretStore {
    /** Bumps on every mutation so combined flows can re-read. */
    val revision: Flow<Long>

    fun get(name: String): String
    fun put(name: String, value: String)
    fun remove(name: String)

    companion object {
        const val RIP_TOKEN = "ripToken"
        const val JUKEBOX_TOKEN = "jukeboxToken"
        const val MUSIC_USER_TOKEN = "musicUserToken"
    }
}

/** Hardware-backed (Keystore master key) EncryptedSharedPreferences implementation. */
class EncryptedSecretStore(context: Context) : SecretStore {
    private val prefs: SharedPreferences = run {
        val app = context.applicationContext
        val master = MasterKey.Builder(app).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            app,
            FILE_NAME,
            master,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }
    private val rev = MutableStateFlow(0L)
    override val revision: Flow<Long> = rev

    override fun get(name: String): String = prefs.getString(name, null) ?: ""

    override fun put(name: String, value: String) {
        prefs.edit().putString(name, value).apply()
        rev.value = rev.value + 1
    }

    override fun remove(name: String) {
        prefs.edit().remove(name).apply()
        rev.value = rev.value + 1
    }

    companion object {
        const val FILE_NAME = "pocketdj-secrets"
    }
}

/** In-memory implementation (JVM tests / previews). */
class InMemorySecretStore(initial: Map<String, String> = emptyMap()) : SecretStore {
    private val map = HashMap(initial)
    private val rev = MutableStateFlow(0L)
    override val revision: Flow<Long> = rev

    @Synchronized
    override fun get(name: String): String = map[name] ?: ""

    @Synchronized
    override fun put(name: String, value: String) {
        map[name] = value
        rev.value = rev.value + 1
    }

    @Synchronized
    override fun remove(name: String) {
        map.remove(name)
        rev.value = rev.value + 1
    }
}

/**
 * One-shot migration of the plaintext DataStore copies into [SecretStore].
 *
 * Idempotent and crash-safe: secrets are copied FIRST (never overwriting a value
 * already in the secret store), the plaintext is blanked and the done-marker set in
 * ONE DataStore edit afterwards. A kill between the two steps just re-runs the
 * copy on next launch with identical results.
 */
object SecretMigration {
    private val moved = listOf(
        LegacyPrefKeys.RIP_TOKEN.name to SecretStore.RIP_TOKEN,
        LegacyPrefKeys.JUKEBOX_TOKEN.name to SecretStore.JUKEBOX_TOKEN,
        LegacyPrefKeys.MUSIC_USER_TOKEN.name to SecretStore.MUSIC_USER_TOKEN,
    )

    /** @return true when this call performed the migration, false if already done. */
    suspend fun run(dataStore: DataStore<Preferences>, secrets: SecretStore): Boolean {
        val before = dataStore.data.first()
        if (before[LegacyPrefKeys.SECRETS_MIGRATED.key] == true) return false
        for ((dsName, secretName) in moved) {
            val plain = before.asMap().entries
                .firstOrNull { it.key.name == dsName }?.value as? String
            if (!plain.isNullOrBlank() && secrets.get(secretName).isBlank()) {
                secrets.put(secretName, plain)
            }
        }
        dataStore.edit { prefs ->
            for ((dsName, _) in moved) {
                val key = prefs.asMap().keys.firstOrNull { it.name == dsName }
                if (key != null) {
                    @Suppress("UNCHECKED_CAST")
                    prefs[key as Preferences.Key<String>] = ""
                }
            }
            prefs[LegacyPrefKeys.SECRETS_MIGRATED.key] = true
        }
        return true
    }
}

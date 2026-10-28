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

    /**
     * False when the secure backing store could not be created. Callers must then use the
     * legacy plaintext path and the migration must NOT run (it would blank the plaintext).
     */
    val isAvailable: Boolean get() = true

    fun get(name: String): String
    fun put(name: String, value: String)
    fun remove(name: String)

    companion object {
        const val RIP_TOKEN = "ripToken"
        const val JUKEBOX_TOKEN = "jukeboxToken"
        const val MUSIC_USER_TOKEN = "musicUserToken"
    }
}

/**
 * Defers creating the real store until first use (always off-main: migration coroutine,
 * the settings flow on IO, DataStore-path writes). When creation fails (after one
 * wipe-and-retry) [isAvailable] is false and every call is a harmless no-op.
 */
class DeferredSecretStore(factory: () -> SecretStore?) : SecretStore {
    private val delegate: SecretStore? by lazy(LazyThreadSafetyMode.SYNCHRONIZED, factory)
    private val rev = MutableStateFlow(0L)
    override val revision: Flow<Long> = rev
    override val isAvailable: Boolean get() = delegate != null

    override fun get(name: String): String = delegate?.get(name).orEmpty()

    override fun put(name: String, value: String) {
        delegate?.put(name, value)
        rev.value = rev.value + 1
    }

    override fun remove(name: String) {
        delegate?.remove(name)
        rev.value = rev.value + 1
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
        // commit(): the secret must be on disk before the migration blanks the plaintext.
        prefs.edit().putString(name, value).commit()
        rev.value = rev.value + 1
    }

    override fun remove(name: String) {
        prefs.edit().remove(name).commit()
        rev.value = rev.value + 1
    }

    companion object {
        const val FILE_NAME = "pocketdj-secrets"
        private const val MASTER_KEY_ALIAS = "_androidx_security_master_key_"
        private const val CREATE_ATTEMPTS = 3

        /**
         * True when [t] says the file/key pair can never open again (bad AEAD tag, invalidated or foreign key,
         * corrupt keyset): the only case where wiping and recreating is right. A bare KeyStoreException is transient.
         */
        internal fun isKeyMismatch(t: Throwable): Boolean {
            var c: Throwable? = t
            var depth = 0
            while (c != null && depth++ < 8) {
                if (c is javax.crypto.AEADBadTagException || c is javax.crypto.BadPaddingException ||
                    c is java.security.InvalidKeyException || c is java.security.UnrecoverableKeyException ||
                    c is java.io.IOException || c.javaClass.simpleName == "KeyPermanentlyInvalidatedException"
                ) return true
                c = c.cause
            }
            return false
        }

        /**
         * Build the store; on failure (Keystore glitch, corrupt/foreign-keyed prefs after a
         * restore) wipe the prefs file + master key once and retry. null ⇒ unavailable.
         */
        fun createOrNull(context: Context): SecretStore? {
            // Final review: a transient Keystore error (busy daemon after boot/update, OEM glitch) must NOT wipe every
            // secret incl. the profile-sync identity. Retry briefly; only a key MISMATCH / corrupt file justifies a wipe.
            var failure: Throwable? = null
            for (attempt in 0 until CREATE_ATTEMPTS) {
                try { return EncryptedSecretStore(context) } catch (t: Throwable) { failure = t }
                if (isKeyMismatch(failure!!)) break
                runCatching { Thread.sleep(250L * (attempt + 1)) }
            }
            if (failure != null && !isKeyMismatch(failure)) {
                android.util.Log.e("PocketDJ", "[secrets] keystore unavailable this launch (kept for the next)", failure)
                return null
            }
            runCatching {
                context.applicationContext.deleteSharedPreferences(FILE_NAME)
                java.security.KeyStore.getInstance("AndroidKeyStore").apply {
                    load(null)
                    deleteEntry(MASTER_KEY_ALIAS)
                }
            }
            return runCatching { EncryptedSecretStore(context) }
                .onFailure { android.util.Log.e("PocketDJ", "[secrets] keystore unavailable", it) }
                .getOrNull()
        }
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
        if (!secrets.isAvailable) return false // never blank plaintext we could not secure
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

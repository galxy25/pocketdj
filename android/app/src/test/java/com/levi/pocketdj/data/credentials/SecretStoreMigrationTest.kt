package com.levi.pocketdj.data.credentials

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.LegacyPrefKeys
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SecretStoreMigrationTest {
    @get:Rule val tmp = TemporaryFolder()
    private val scopes = mutableListOf<CoroutineScope>()

    @After fun tearDown() = scopes.forEach { it.cancel() }

    private fun ds(): DataStore<Preferences> {
        val scope = CoroutineScope(Dispatchers.IO + Job()).also { scopes += it }
        return PreferenceDataStoreFactory.create(scope = scope) { File(tmp.root, "p.preferences_pb") }
    }

    /** Seeds the pre-SURF-1 world: plaintext tokens in the DataStore. */
    private suspend fun seedLegacy(ds: DataStore<Preferences>) {
        AppSettingsStore(ds).apply {
            setRipServer("https://rip", "rip-secret")
            setJukeboxServer("https://jb", "jb-secret")
            setMusicUserToken("mut-secret")
        }
    }

    private suspend fun plain(ds: DataStore<Preferences>, name: String): String =
        ds.data.first().asMap().entries.firstOrNull { it.key.name == name }?.value as? String ?: ""

    @Test
    fun migration_movesTokens_blanksPlaintext_andIsIdempotent() = runBlocking {
        val ds = ds()
        seedLegacy(ds)
        val secrets = InMemorySecretStore()

        assertTrue(SecretMigration.run(ds, secrets))
        assertEquals("rip-secret", secrets.get(SecretStore.RIP_TOKEN))
        assertEquals("jb-secret", secrets.get(SecretStore.JUKEBOX_TOKEN))
        assertEquals("mut-secret", secrets.get(SecretStore.MUSIC_USER_TOKEN))
        assertEquals("", plain(ds, "ripToken"))
        assertEquals("", plain(ds, "jukeboxToken"))
        assertEquals("", plain(ds, "musicUserToken"))

        // Second run: no-op, and a fresh value in the secret store is never clobbered.
        secrets.put(SecretStore.RIP_TOKEN, "rotated")
        assertFalse(SecretMigration.run(ds, secrets))
        assertEquals("rotated", secrets.get(SecretStore.RIP_TOKEN))
    }

    @Test
    fun migration_survivesRelaunch_marker_isPersisted() = runBlocking {
        val ds = ds()
        seedLegacy(ds)
        val secrets = InMemorySecretStore()
        SecretMigration.run(ds, secrets)
        // "Relaunch": a new store instance over the same persisted files.
        assertEquals(true, ds.data.first()[LegacyPrefKeys.SECRETS_MIGRATED.key])
        assertFalse(SecretMigration.run(ds, secrets))
    }

    @Test
    fun migration_doesNotOverwriteExistingSecret_withStalePlaintext() = runBlocking {
        val ds = ds()
        seedLegacy(ds)
        val secrets = InMemorySecretStore(mapOf(SecretStore.RIP_TOKEN to "newer"))
        SecretMigration.run(ds, secrets)
        assertEquals("newer", secrets.get(SecretStore.RIP_TOKEN))
        assertEquals("", plain(ds, "ripToken"))
    }

    @Test
    fun settingsReads_seeThroughMigration_andNewWritesGoOnlyToSecrets() = runBlocking {
        val ds = ds()
        seedLegacy(ds)
        val secrets = InMemorySecretStore()
        val store = AppSettingsStore(ds, secrets = secrets)

        // Before migration: plaintext fallback keeps existing rip/jukebox flows authenticating.
        assertEquals("rip-secret", store.current().ripToken)
        SecretMigration.run(ds, secrets)
        // After migration: same values, now from the secret store.
        val migrated = store.current()
        assertEquals("rip-secret", migrated.ripToken)
        assertEquals("jb-secret", migrated.jukeboxToken)
        assertTrue(migrated.hasAppleMusic)

        store.setRipServer("https://rip2", "rip-2")
        assertEquals("rip-2", store.current().ripToken)
        assertEquals("rip-2", secrets.get(SecretStore.RIP_TOKEN))
        assertEquals("never back in plaintext", "", plain(ds, "ripToken"))

        store.clearMusicUserToken()
        assertFalse(store.current().hasAppleMusic)
    }
}

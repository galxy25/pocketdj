package com.levi.pocketdj.data.search

import com.levi.pocketdj.data.credentials.SecretStore
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.data.settings.PrefKey
import com.levi.pocketdj.net.SigV4

/**
 * Online-search settings (BRW-5). The read-only aoss key id/secret are SECRETS and live in
 * [SecretStore] (decision D6); only the per-user host override is a plain pref. Names mirror
 * iOS `SettingsStore.searchAccessKeyID` / `searchSecretKey` / `searchEndpoint`.
 */
object SearchSettings {
    const val ACCESS_KEY_ID = "searchAccessKeyId"
    const val SECRET_KEY = "searchSecretKey"

    /** Per-user host override (bare host or full URL; normalised by [SearchConfig]). */
    val ENDPOINT = PrefKey.string("searchEndpoint", "")

    fun creds(secrets: SecretStore): SigV4.Creds? {
        val id = secrets.get(ACCESS_KEY_ID).trim()
        val secret = secrets.get(SECRET_KEY).trim()
        return if (id.isEmpty() || secret.isEmpty()) null else SigV4.Creds(id, secret)
    }

    fun isConfigured(secrets: SecretStore): Boolean = creds(secrets) != null

    fun saveCreds(secrets: SecretStore, accessKeyId: String, secretKey: String) {
        secrets.put(ACCESS_KEY_ID, accessKeyId.trim())
        secrets.put(SECRET_KEY, secretKey.trim())
    }

    fun clearCreds(secrets: SecretStore) {
        secrets.remove(ACCESS_KEY_ID)
        secrets.remove(SECRET_KEY)
    }

    suspend fun endpoint(store: AppSettingsStore): String = store.get(ENDPOINT)
    suspend fun setEndpoint(store: AppSettingsStore, raw: String) = store.set(ENDPOINT, raw.trim())

    const val MISSING_CREDS_MESSAGE = "Add OpenSearch credentials in Settings to search online."
}

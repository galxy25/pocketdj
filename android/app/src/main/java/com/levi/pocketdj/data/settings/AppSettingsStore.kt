package com.levi.pocketdj.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.config.Endpoints
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * One catalog data source the user has configured (specs/catalog.md §5).
 * Persisted as JSON inside the settings DataStore — additive-optional: unknown
 * keys ignored, every non-identity field defaulted.
 */
@Serializable
data class SourceConfig(
    val id: String,
    val name: String,
    val url: String,
    val enabled: Boolean = true,
)

/** Immutable snapshot of every persisted app setting. */
data class AppSettings(
    val sources: List<SourceConfig> = defaultSources(),
    val ripServerUrl: String = Endpoints.DEFAULT_RIP_SERVER_URL,
    val ripToken: String = "",
    val jukeboxServerUrl: String = Endpoints.DEFAULT_JUKEBOX_SERVER_URL,
    val jukeboxToken: String = "",
    val jukeboxTokensRequiredByDefault: Boolean = true,
    val onlineSearchEnabled: Boolean = false,
    val installId: String = "",
) {
    val hasRipServer: Boolean get() = ripServerUrl.isNotBlank()

    companion object {
        /** iOS ships exactly one default source: My Vinyl (catalog.md §5). */
        fun defaultSources(): List<SourceConfig> = listOf(
            SourceConfig(
                id = "vinyl",
                name = Endpoints.SOURCE_NAME_VINYL,
                url = Endpoints.VINYL_INDEX_URL,
                enabled = true,
            ),
        )

        /** Opt-in preset (catalog.md §1). */
        fun appleMusicSource(): SourceConfig = SourceConfig(
            id = "apple-music",
            name = Endpoints.SOURCE_NAME_APPLE_MUSIC,
            url = Endpoints.APPLE_MUSIC_INDEX_URL,
        )

        /** Opt-in preset (catalog.md §1). */
        fun digitalSource(): SourceConfig = SourceConfig(
            id = "digital",
            name = Endpoints.SOURCE_NAME_DIGITAL,
            url = Endpoints.DIGITAL_INDEX_URL,
        )
    }
}

/**
 * Additive-safe settings store over a Preferences DataStore.
 *
 * Additive safety comes in two layers: Preferences keys are independent (a new
 * key simply defaults when absent), and the one structured value (the sources
 * list) is decoded with the lenient [PdjJson] so unknown fields never wipe it.
 */
class AppSettingsStore(
    private val dataStore: DataStore<Preferences>,
    private val json: Json = PdjJson.lenient,
) {
    private object Keys {
        val SOURCES_JSON = stringPreferencesKey("sourcesJson")
        val RIP_SERVER_URL = stringPreferencesKey("ripServerUrl")
        val RIP_TOKEN = stringPreferencesKey("ripToken")
        val JUKEBOX_SERVER_URL = stringPreferencesKey("jukeboxServerUrl")
        val JUKEBOX_TOKEN = stringPreferencesKey("jukeboxToken")
        val JUKEBOX_TOKENS_REQUIRED = booleanPreferencesKey("jukeboxTokensRequiredByDefault")
        val ONLINE_SEARCH_ENABLED = booleanPreferencesKey("onlineSearchEnabled")
        val INSTALL_ID = stringPreferencesKey("installId")
        val BROWSE_SNAPSHOT_JSON = stringPreferencesKey("browseSnapshotJson")
    }

    /** Live settings; IO errors surface as defaults rather than a crash. */
    val settings: Flow<AppSettings> = dataStore.data
        .catch { error -> if (error is IOException) emit(emptyPreferences()) else throw error }
        .map(::toSettings)

    suspend fun current(): AppSettings = settings.first()

    private fun toSettings(prefs: Preferences): AppSettings = AppSettings(
        sources = decodeSources(prefs[Keys.SOURCES_JSON]),
        ripServerUrl = prefs[Keys.RIP_SERVER_URL] ?: Endpoints.DEFAULT_RIP_SERVER_URL,
        ripToken = prefs[Keys.RIP_TOKEN] ?: "",
        jukeboxServerUrl = prefs[Keys.JUKEBOX_SERVER_URL] ?: Endpoints.DEFAULT_JUKEBOX_SERVER_URL,
        jukeboxToken = prefs[Keys.JUKEBOX_TOKEN] ?: "",
        jukeboxTokensRequiredByDefault = prefs[Keys.JUKEBOX_TOKENS_REQUIRED] ?: true,
        onlineSearchEnabled = prefs[Keys.ONLINE_SEARCH_ENABLED] ?: false,
        installId = prefs[Keys.INSTALL_ID] ?: "",
    )

    private fun decodeSources(raw: String?): List<SourceConfig> {
        if (raw.isNullOrBlank()) return AppSettings.defaultSources()
        return runCatching { json.decodeFromString<List<SourceConfig>>(raw) }
            .getOrElse { AppSettings.defaultSources() }
    }

    suspend fun setSources(sources: List<SourceConfig>) {
        val encoded = json.encodeToString(sources)
        dataStore.edit { it[Keys.SOURCES_JSON] = encoded }
    }

    /**
     * Transactional source mutation: [transform] runs INSIDE `dataStore.edit`
     * over the list decoded from the prefs being edited — never over a stale
     * composition snapshot — so two quick mutations (toggle + toggle, toggle +
     * preset-add) can't lose the first write.
     */
    suspend fun updateSources(transform: (List<SourceConfig>) -> List<SourceConfig>) {
        dataStore.edit { prefs ->
            val current = decodeSources(prefs[Keys.SOURCES_JSON])
            prefs[Keys.SOURCES_JSON] = json.encodeToString(transform(current))
        }
    }

    /**
     * The persisted Browse view-state (specs/browse.md §7), stored separately
     * from the settings fields under its own key. Decoded leniently: a missing,
     * empty, or corrupt doc yields defaults — never a crash — exactly like the
     * sources value.
     */
    val browseSnapshot: Flow<BrowseSnapshot> = dataStore.data
        .catch { error -> if (error is IOException) emit(emptyPreferences()) else throw error }
        .map { decodeBrowseSnapshot(it[Keys.BROWSE_SNAPSHOT_JSON]) }

    suspend fun currentBrowseSnapshot(): BrowseSnapshot = browseSnapshot.first()

    /**
     * Whole-doc write of the Browse snapshot. A single `edit` is atomic, so the
     * authoritative in-memory session is serialized as one value — no
     * read-modify-write, therefore no transactional merge needed here.
     */
    suspend fun setBrowseSnapshot(snapshot: BrowseSnapshot) {
        val encoded = json.encodeToString(snapshot)
        dataStore.edit { it[Keys.BROWSE_SNAPSHOT_JSON] = encoded }
    }

    private fun decodeBrowseSnapshot(raw: String?): BrowseSnapshot {
        if (raw.isNullOrBlank()) return BrowseSnapshot()
        return runCatching { json.decodeFromString<BrowseSnapshot>(raw) }
            .getOrElse { BrowseSnapshot() }
    }

    suspend fun setRipServer(url: String, token: String) {
        dataStore.edit {
            it[Keys.RIP_SERVER_URL] = url.trim()
            it[Keys.RIP_TOKEN] = token.trim()
        }
    }

    suspend fun setJukeboxServer(url: String, token: String) {
        dataStore.edit {
            it[Keys.JUKEBOX_SERVER_URL] = url.trim()
            it[Keys.JUKEBOX_TOKEN] = token.trim()
        }
    }

    suspend fun setJukeboxTokensRequiredByDefault(required: Boolean) {
        dataStore.edit { it[Keys.JUKEBOX_TOKENS_REQUIRED] = required }
    }

    suspend fun setOnlineSearchEnabled(enabled: Boolean) {
        dataStore.edit { it[Keys.ONLINE_SEARCH_ENABLED] = enabled }
    }

    /**
     * The stable per-install identity for `X-PocketDJ-Device` (playback.md §4.1,
     * jukebox.md §2.2): a random UUID minted once, then persisted forever.
     */
    suspend fun ensureInstallId(): String {
        current().installId.takeIf { it.isNotEmpty() }?.let { return it }
        var minted = UUID.randomUUID().toString()
        dataStore.edit { prefs ->
            val existing = prefs[Keys.INSTALL_ID]
            if (existing.isNullOrEmpty()) prefs[Keys.INSTALL_ID] = minted else minted = existing
        }
        return minted
    }
}

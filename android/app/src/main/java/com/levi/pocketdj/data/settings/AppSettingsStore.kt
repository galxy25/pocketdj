package com.levi.pocketdj.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.credentials.SecretStore
import com.levi.pocketdj.data.config.Endpoints
import com.levi.pocketdj.data.config.RemoteEndpoints
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
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
    // Playlists-tab UI state (specs/playlists-ui.md §9 — persisted OUTSIDE the
    // collections document). Tokens/semantics mirror the iOS keys exactly.
    /** `CollectionSortOrder` raw token; missing ⇒ "name" (fresh install AND upgrade). */
    val collectionSort: String = "name",
    /** Yours/Shared tab: "user" | "shared"; missing ⇒ "user". */
    val playlistsMode: String = "user",
    /** COLLAPSED folder ids — missing/absent ⇒ expanded (folders default OPEN). */
    val collapsedFolderIds: Set<String> = emptySet(),
    /**
     * EXPANDED source names — missing/absent ⇒ collapsed (Shared groups default
     * CLOSED). Deliberately the INVERSE of the folder key so the default needs
     * no seeding.
     */
    val expandedSourceNames: Set<String> = emptySet(),
    // Apple Music (specs/applemusic.md §3.3, §10). Each is an independent
    // additive-optional Preferences key that simply defaults when absent — a
    // saved doc from a build without them is never wiped.
    /** Per-user Music-User-Token from the sign-in deep-link; empty ⇒ signed out. */
    val musicUserToken: String = "",
    /** Cold-start cache of the app-wide ES256 developer token (empty ⇒ unfetched). */
    val appleMusicDeveloperToken: String = "",
    /** Epoch-ms expiry of the cached developer token (0 ⇒ unknown/unfetched). */
    val appleMusicDeveloperTokenExpiresAt: Long = 0L,
) {
    val hasRipServer: Boolean get() = ripServerUrl.isNotBlank()

    /** Signed in to Apple Music (a Music-User-Token is persisted). */
    val hasAppleMusic: Boolean get() = musicUserToken.isNotBlank()

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
    /**
     * Where the three secrets (rip token, jukebox token, Music-User-Token) live. null ⇒
     * legacy behaviour (plaintext in the DataStore) — JVM tests and the pre-migration
     * window. When present, writes go ONLY here and reads fall back to a not-yet-migrated
     * DataStore copy so the one-shot migration is invisible to callers.
     */
    private val secrets: SecretStore? = null,
) {
    private object Keys {
        val SOURCES_JSON = LegacyPrefKeys.SOURCES_JSON
        val RIP_SERVER_URL = LegacyPrefKeys.RIP_SERVER_URL
        val RIP_TOKEN = LegacyPrefKeys.RIP_TOKEN
        val JUKEBOX_SERVER_URL = LegacyPrefKeys.JUKEBOX_SERVER_URL
        val JUKEBOX_TOKEN = LegacyPrefKeys.JUKEBOX_TOKEN
        val JUKEBOX_TOKENS_REQUIRED = LegacyPrefKeys.JUKEBOX_TOKENS_REQUIRED
        val ONLINE_SEARCH_ENABLED = LegacyPrefKeys.ONLINE_SEARCH_ENABLED
        val INSTALL_ID = LegacyPrefKeys.INSTALL_ID
        val BROWSE_SNAPSHOT_JSON = LegacyPrefKeys.BROWSE_SNAPSHOT_JSON
        val COLLECTION_SORT = LegacyPrefKeys.COLLECTION_SORT
        val PLAYLISTS_MODE = LegacyPrefKeys.PLAYLISTS_MODE
        val COLLAPSED_FOLDER_IDS = LegacyPrefKeys.COLLAPSED_FOLDER_IDS
        val EXPANDED_SOURCE_NAMES = LegacyPrefKeys.EXPANDED_SOURCE_NAMES
        val MUSIC_USER_TOKEN = LegacyPrefKeys.MUSIC_USER_TOKEN
        val AM_DEV_TOKEN = LegacyPrefKeys.AM_DEV_TOKEN
        val AM_DEV_TOKEN_EXP = LegacyPrefKeys.AM_DEV_TOKEN_EXP
    }

    private val prefsFlow: Flow<Preferences> = dataStore.data
        .catch { error -> if (error is IOException) emit(emptyPreferences()) else throw error }

    // ---- Generic typed API (decision D3) -----------------------------------

    /** Live value of [key] (its default when unset). */
    fun <T> flow(key: PrefKey<T>): Flow<T> =
        prefsFlow.map { it[key.key] ?: key.default }.distinctUntilChanged()

    suspend fun <T> get(key: PrefKey<T>): T = flow(key).first()

    suspend fun <T> set(key: PrefKey<T>, value: T) {
        dataStore.edit { it[key.key] = value }
    }

    /** Transactional read-modify-write of one key. */
    suspend fun <T> update(key: PrefKey<T>, transform: (T) -> T) {
        dataStore.edit { it[key.key] = transform(it[key.key] ?: key.default) }
    }

    suspend fun <T> remove(key: PrefKey<T>) {
        dataStore.edit { it.remove(key.key) }
    }

    /** Wipe every preference (Reset everything). Secrets are the caller's to clear. */
    suspend fun clearAll() {
        dataStore.edit { it.clear() }
    }

    /** Live settings; IO errors surface as defaults rather than a crash. */
    val settings: Flow<AppSettings> =
        combine(prefsFlow, secrets?.revision ?: flowOf(0L)) { prefs, _ -> toSettings(prefs) }
            .flowOn(kotlinx.coroutines.Dispatchers.IO) // secret reads may touch the Keystore

    suspend fun current(): AppSettings = settings.first()

    private fun secretOrLegacy(prefs: Preferences, secretName: String, legacy: PrefKey<String>): String {
        val fromSecrets = secrets?.get(secretName).orEmpty()
        return fromSecrets.ifEmpty { prefs[legacy.key] ?: "" }
    }

    private fun toSettings(prefs: Preferences): AppSettings = AppSettings(
        sources = decodeSources(prefs[Keys.SOURCES_JSON.key]),
        ripServerUrl = prefs[Keys.RIP_SERVER_URL.key] ?: Endpoints.DEFAULT_RIP_SERVER_URL,
        ripToken = secretOrLegacy(prefs, SecretStore.RIP_TOKEN, Keys.RIP_TOKEN),
        jukeboxServerUrl = prefs[Keys.JUKEBOX_SERVER_URL.key] ?: Endpoints.DEFAULT_JUKEBOX_SERVER_URL,
        jukeboxToken = secretOrLegacy(prefs, SecretStore.JUKEBOX_TOKEN, Keys.JUKEBOX_TOKEN),
        jukeboxTokensRequiredByDefault = prefs[Keys.JUKEBOX_TOKENS_REQUIRED.key] ?: true,
        onlineSearchEnabled = prefs[Keys.ONLINE_SEARCH_ENABLED.key] ?: false,
        installId = prefs[Keys.INSTALL_ID.key] ?: "",
        collectionSort = prefs[Keys.COLLECTION_SORT.key] ?: "name",
        playlistsMode = prefs[Keys.PLAYLISTS_MODE.key] ?: "user",
        collapsedFolderIds = prefs[Keys.COLLAPSED_FOLDER_IDS.key] ?: emptySet(),
        expandedSourceNames = prefs[Keys.EXPANDED_SOURCE_NAMES.key] ?: emptySet(),
        musicUserToken = secretOrLegacy(prefs, SecretStore.MUSIC_USER_TOKEN, Keys.MUSIC_USER_TOKEN),
        appleMusicDeveloperToken = prefs[Keys.AM_DEV_TOKEN.key] ?: "",
        appleMusicDeveloperTokenExpiresAt = prefs[Keys.AM_DEV_TOKEN_EXP.key] ?: 0L,
    )

    private fun decodeSources(raw: String?): List<SourceConfig> {
        if (raw.isNullOrBlank()) return AppSettings.defaultSources()
        // Built-in sources persist their catalog host; rebase them onto the LIVE endpoint
        // config at read time (remote endpoints — a backend flip must not strand them).
        return runCatching { json.decodeFromString<List<SourceConfig>>(raw) }
            .getOrElse { AppSettings.defaultSources() }
            .map { it.copy(url = RemoteEndpoints.rebaseCatalogUrl(it.url)) }
    }

    suspend fun setSources(sources: List<SourceConfig>) {
        val encoded = json.encodeToString(sources)
        dataStore.edit { it[Keys.SOURCES_JSON.key] = encoded }
    }

    /**
     * Transactional source mutation: [transform] runs INSIDE `dataStore.edit`
     * over the list decoded from the prefs being edited — never over a stale
     * composition snapshot — so two quick mutations (toggle + toggle, toggle +
     * preset-add) can't lose the first write.
     */
    suspend fun updateSources(transform: (List<SourceConfig>) -> List<SourceConfig>) {
        dataStore.edit { prefs ->
            val current = decodeSources(prefs[Keys.SOURCES_JSON.key])
            prefs[Keys.SOURCES_JSON.key] = json.encodeToString(transform(current))
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
        .map { decodeBrowseSnapshot(it[Keys.BROWSE_SNAPSHOT_JSON.key]) }

    suspend fun currentBrowseSnapshot(): BrowseSnapshot = browseSnapshot.first()

    /**
     * Whole-doc write of the Browse snapshot. A single `edit` is atomic, so the
     * authoritative in-memory session is serialized as one value — no
     * read-modify-write, therefore no transactional merge needed here.
     */
    suspend fun setBrowseSnapshot(snapshot: BrowseSnapshot) {
        val encoded = json.encodeToString(snapshot)
        dataStore.edit { it[Keys.BROWSE_SNAPSHOT_JSON.key] = encoded }
    }

    private fun decodeBrowseSnapshot(raw: String?): BrowseSnapshot {
        if (raw.isNullOrBlank()) return BrowseSnapshot()
        return runCatching { json.decodeFromString<BrowseSnapshot>(raw) }
            .getOrElse { BrowseSnapshot() }
    }

    /** Secret write: into [secrets] when wired (and blank any stale plaintext), else DataStore. */
    private suspend fun putSecret(secretName: String, legacy: PrefKey<String>, value: String) {
        val store = secrets
        if (store == null || !store.isAvailable) {
            dataStore.edit { it[legacy.key] = value }
        } else {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { store.put(secretName, value) }
            dataStore.edit { prefs -> if (prefs[legacy.key] != null) prefs[legacy.key] = "" }
        }
    }

    suspend fun setRipServer(url: String, token: String) {
        dataStore.edit { it[Keys.RIP_SERVER_URL.key] = url.trim() }
        putSecret(SecretStore.RIP_TOKEN, Keys.RIP_TOKEN, token.trim())
    }

    suspend fun setJukeboxServer(url: String, token: String) {
        dataStore.edit { it[Keys.JUKEBOX_SERVER_URL.key] = url.trim() }
        putSecret(SecretStore.JUKEBOX_TOKEN, Keys.JUKEBOX_TOKEN, token.trim())
    }

    suspend fun setJukeboxTokensRequiredByDefault(required: Boolean) {
        dataStore.edit { it[Keys.JUKEBOX_TOKENS_REQUIRED.key] = required }
    }

    suspend fun setOnlineSearchEnabled(enabled: Boolean) {
        dataStore.edit { it[Keys.ONLINE_SEARCH_ENABLED.key] = enabled }
    }

    /** Persist the Playlists collection-sort token (`CollectionSortOrder.token`). */
    suspend fun setCollectionSort(token: String) {
        dataStore.edit { it[Keys.COLLECTION_SORT.key] = token }
    }

    /** Persist the Playlists Yours/Shared tab ("user" | "shared"). */
    suspend fun setPlaylistsMode(mode: String) {
        dataStore.edit { it[Keys.PLAYLISTS_MODE.key] = mode }
    }

    /**
     * Toggle one folder's collapsed state. Transactional (like [updateSources])
     * so two quick toggles can't lose the first write.
     */
    suspend fun setFolderCollapsed(folderId: String, collapsed: Boolean) {
        dataStore.edit { prefs ->
            val current = prefs[Keys.COLLAPSED_FOLDER_IDS.key] ?: emptySet()
            prefs[Keys.COLLAPSED_FOLDER_IDS.key] =
                if (collapsed) current + folderId else current - folderId
        }
    }

    /** Toggle one Shared source group's expanded state (inverse-set semantics). */
    suspend fun setSourceExpanded(sourceName: String, expanded: Boolean) {
        dataStore.edit { prefs ->
            val current = prefs[Keys.EXPANDED_SOURCE_NAMES.key] ?: emptySet()
            prefs[Keys.EXPANDED_SOURCE_NAMES.key] =
                if (expanded) current + sourceName else current - sourceName
        }
    }

    /**
     * Persist the Music-User-Token from a successful sign-in (specs/applemusic.md
     * §3.3). Atomic single-key edit; never touches identity or other settings.
     */
    suspend fun setMusicUserToken(token: String) {
        putSecret(SecretStore.MUSIC_USER_TOKEN, Keys.MUSIC_USER_TOKEN, token.trim())
    }

    /** Sign out of Apple Music — clears the Music-User-Token only (dev token is
     *  app-wide, not user-identifying, and is deliberately kept). */
    suspend fun clearMusicUserToken() {
        putSecret(SecretStore.MUSIC_USER_TOKEN, Keys.MUSIC_USER_TOKEN, "")
    }

    /** Cold-start cache of the app-wide developer token + its epoch-ms expiry. */
    suspend fun setAppleMusicDeveloperToken(token: String, expiresAt: Long) {
        dataStore.edit {
            it[Keys.AM_DEV_TOKEN.key] = token
            it[Keys.AM_DEV_TOKEN_EXP.key] = expiresAt
        }
    }

    /**
     * The stable per-install identity for `X-PocketDJ-Device` (playback.md §4.1,
     * jukebox.md §2.2): a random UUID minted once, then persisted forever.
     */
    suspend fun ensureInstallId(): String {
        current().installId.takeIf { it.isNotEmpty() }?.let { return it }
        var minted = UUID.randomUUID().toString()
        dataStore.edit { prefs ->
            val existing = prefs[Keys.INSTALL_ID.key]
            if (existing.isNullOrEmpty()) prefs[Keys.INSTALL_ID.key] = minted else minted = existing
        }
        return minted
    }
}

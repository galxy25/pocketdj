package com.levi.pocketdj.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.levi.pocketdj.data.config.Endpoints
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Settings round-trip + the additive-optional iron law: defaults when nothing
 * is stored, lenient decode of the structured sources value, and a corrupt
 * value never wipes the doc into a crash.
 */
class AppSettingsStoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val scopes = mutableListOf<CoroutineScope>()

    private fun newStore(name: String): Pair<AppSettingsStore, DataStore<Preferences>> {
        val scope = CoroutineScope(Dispatchers.IO + Job())
        scopes += scope
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) {
            File(tmp.root, "$name.preferences_pb")
        }
        return AppSettingsStore(dataStore) to dataStore
    }

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
    }

    @Test
    fun defaults_matchTheContract() = runBlocking {
        val (store, _) = newStore("defaults")
        val settings = store.current()
        assertEquals("", settings.ripServerUrl) // never ship a baked hostname
        assertEquals("", settings.ripToken)
        assertEquals("", settings.jukeboxServerUrl)
        assertEquals("", settings.jukeboxToken)
        assertTrue(settings.jukeboxTokensRequiredByDefault)
        assertFalse(settings.onlineSearchEnabled)
        assertFalse(settings.hasRipServer)
        // Exactly one default source: My Vinyl → current-index.json, enabled.
        assertEquals(1, settings.sources.size)
        assertEquals(Endpoints.SOURCE_NAME_VINYL, settings.sources[0].name)
        assertEquals(Endpoints.VINYL_INDEX_URL, settings.sources[0].url)
        assertTrue(settings.sources[0].enabled)
    }

    @Test
    fun serverFields_roundTrip_trimmed() = runBlocking {
        val (store, _) = newStore("roundtrip")
        store.setRipServer("  https://levis-imac.example.ts.net:10000/  ", "  secret-token ")
        store.setJukeboxServer("https://broker.example:8443/jukebox", "party-token")
        store.setOnlineSearchEnabled(true)
        store.setJukeboxTokensRequiredByDefault(false)

        val settings = store.current()
        assertEquals("https://levis-imac.example.ts.net:10000/", settings.ripServerUrl)
        assertEquals("secret-token", settings.ripToken)
        assertEquals("https://broker.example:8443/jukebox", settings.jukeboxServerUrl)
        assertEquals("party-token", settings.jukeboxToken)
        assertTrue(settings.onlineSearchEnabled)
        assertFalse(settings.jukeboxTokensRequiredByDefault)
        assertTrue(settings.hasRipServer)
    }

    @Test
    fun installId_isMintedOnce_thenStable() = runBlocking {
        val (store, _) = newStore("install-id")
        val first = store.ensureInstallId()
        val second = store.ensureInstallId()
        assertTrue(first.isNotEmpty())
        assertEquals(first, second)
        assertEquals(first, store.current().installId)
    }

    @Test
    fun sources_roundTrip() = runBlocking {
        val (store, _) = newStore("sources")
        val updated = AppSettings.defaultSources() + AppSettings.appleMusicSource().copy(enabled = false)
        store.setSources(updated)
        val settings = store.current()
        assertEquals(2, settings.sources.size)
        assertEquals(Endpoints.SOURCE_NAME_APPLE_MUSIC, settings.sources[1].name)
        assertFalse(settings.sources[1].enabled)
    }

    @Test
    fun sourcesJson_withUnknownFutureFields_decodesLeniently() = runBlocking {
        val (store, dataStore) = newStore("lenient")
        // A future build wrote extra fields — this build must keep the doc.
        dataStore.edit {
            it[stringPreferencesKey("sourcesJson")] = """
                [{"id":"vinyl","name":"My Vinyl","url":"${Endpoints.VINYL_INDEX_URL}",
                  "enabled":false,"addedAt":1750000000000,"color":"#6EA8FF"}]
            """.trimIndent()
        }
        val settings = store.current()
        assertEquals(1, settings.sources.size)
        assertFalse(settings.sources[0].enabled)
        assertEquals(Endpoints.SOURCE_NAME_VINYL, settings.sources[0].name)
    }

    @Test
    fun corruptSourcesJson_fallsBackToDefaults_neverCrashes() = runBlocking {
        val (store, dataStore) = newStore("corrupt")
        dataStore.edit { it[stringPreferencesKey("sourcesJson")] = "not json at all {{{" }
        val settings = store.current()
        assertEquals(AppSettings.defaultSources(), settings.sources)
    }

    // ---- Browse snapshot (specs/browse.md §7) ------------------------------

    @Test
    fun browseSnapshot_defaultsWhenUnset() = runBlocking {
        val (store, _) = newStore("browse-default")
        assertEquals(BrowseSnapshot(), store.currentBrowseSnapshot())
    }

    @Test
    fun browseSnapshot_roundTrips() = runBlocking {
        val (store, _) = newStore("browse-roundtrip")
        val snap = BrowseSnapshot(
            kind = "songs",
            layout = "list",
            searchMode = "online",
            genres = listOf("jazz"),
            bpmMin = 90.0,
            bpmMax = 140.0,
            camelots = listOf("8A"),
            sources = listOf("My Vinyl"),
            sortKeys = listOf(
                BrowseSortKeyDoc("bpm", ascending = false),
                BrowseSortKeyDoc("artist", ascending = true),
            ),
        )
        store.setBrowseSnapshot(snap)
        assertEquals(snap, store.currentBrowseSnapshot())
    }

    @Test
    fun browseSnapshot_corruptJson_fallsBackToDefaults() = runBlocking {
        val (store, dataStore) = newStore("browse-corrupt")
        dataStore.edit { it[stringPreferencesKey("browseSnapshotJson")] = "}{ not json" }
        assertEquals(BrowseSnapshot(), store.currentBrowseSnapshot())
    }

    @Test
    fun browseSnapshot_oldDocWithUnknownFutureFields_decodesLeniently() = runBlocking {
        val (store, dataStore) = newStore("browse-lenient")
        // A future build wrote extra fields + omitted some — this build must keep it.
        dataStore.edit {
            it[stringPreferencesKey("browseSnapshotJson")] = """
                {"kind":"songs","sortKeys":[{"field":"bpm","ascending":false}],
                 "favoriteFilter":"only","futureKnob":42}
            """.trimIndent()
        }
        val snap = store.currentBrowseSnapshot()
        assertEquals("songs", snap.kind)
        assertEquals("grid", snap.layout) // omitted → default
        assertEquals(1, snap.sortKeys.size)
        assertEquals("bpm", snap.sortKeys[0].field)
        assertFalse(snap.sortKeys[0].ascending)
    }

    @Test
    fun playlistsUiState_defaultsAndRoundTrip() = runBlocking {
        val (store, _) = newStore("playlists-ui")
        // Defaults (specs/playlists-ui.md §9): name sort, Yours tab, folders
        // expanded (empty collapsed set), Shared groups collapsed (empty
        // expanded set — the deliberate inverse-key semantics).
        val defaults = store.current()
        assertEquals("name", defaults.collectionSort)
        assertEquals("user", defaults.playlistsMode)
        assertTrue(defaults.collapsedFolderIds.isEmpty())
        assertTrue(defaults.expandedSourceNames.isEmpty())

        store.setCollectionSort("recentlyPlayed")
        store.setPlaylistsMode("shared")
        store.setFolderCollapsed("fld_1", collapsed = true)
        store.setFolderCollapsed("fld_2", collapsed = true)
        store.setFolderCollapsed("fld_1", collapsed = false)
        store.setSourceExpanded("Apple Music (Local)", expanded = true)
        store.setSourceExpanded("My Vinyl", expanded = true)
        store.setSourceExpanded("My Vinyl", expanded = false)

        val settings = store.current()
        assertEquals("recentlyPlayed", settings.collectionSort)
        assertEquals("shared", settings.playlistsMode)
        assertEquals(setOf("fld_2"), settings.collapsedFolderIds)
        assertEquals(setOf("Apple Music (Local)"), settings.expandedSourceNames)
    }
}

package com.levi.pocketdj.data.settings

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
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
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PrefKeyTest {
    @get:Rule val tmp = TemporaryFolder()
    private val scope = CoroutineScope(Dispatchers.IO + Job())

    @After fun tearDown() = scope.cancel()

    private fun store(name: String = "s") = AppSettingsStore(
        PreferenceDataStoreFactory.create(scope = scope) { File(tmp.root, "$name.preferences_pb") },
    )

    private val counter = PrefKey.int("test.counter", 7)
    private val flag = PrefKey.boolean("test.flag", true)
    private val label = PrefKey.string("test.label", "dflt")
    private val big = PrefKey.long("test.big", 5L)
    private val ratio = PrefKey.double("test.ratio", 0.5)
    private val tags = PrefKey.stringSet("test.tags")

    @Test
    fun defaults_whenUnset() = runBlocking {
        val s = store()
        assertEquals(7, s.get(counter))
        assertEquals(true, s.get(flag))
        assertEquals("dflt", s.get(label))
        assertEquals(5L, s.get(big))
        assertEquals(0.5, s.get(ratio), 0.0)
        assertEquals(emptySet<String>(), s.get(tags))
    }

    @Test
    fun setGetFlow_roundTrip_allTypes() = runBlocking {
        val s = store()
        s.set(counter, 42); s.set(flag, false); s.set(label, "hi"); s.set(big, 1L shl 40)
        s.set(ratio, 0.25); s.set(tags, setOf("a", "b"))
        assertEquals(42, s.get(counter))
        assertEquals(false, s.flow(flag).first())
        assertEquals("hi", s.get(label))
        assertEquals(1L shl 40, s.get(big))
        assertEquals(0.25, s.get(ratio), 0.0)
        assertEquals(setOf("a", "b"), s.flow(tags).first())
    }

    @Test
    fun update_isReadModifyWrite_andRemoveRestoresDefault() = runBlocking {
        val s = store()
        s.update(counter) { it + 1 }
        s.update(counter) { it + 1 }
        assertEquals(9, s.get(counter))
        s.remove(counter)
        assertEquals(7, s.get(counter))
    }

    @Test
    fun genericKeys_coexistWithTypedSettings_andSurviveClearAllOnlyAsDefaults() = runBlocking {
        val s = store()
        s.setRipServer("https://x", "t")
        s.set(label, "kept")
        assertEquals("https://x", s.current().ripServerUrl)
        assertEquals("kept", s.get(label))
        s.clearAll()
        assertEquals("dflt", s.get(label))
        assertEquals("", s.current().ripToken)
    }

    @Test
    fun legacyKeyNames_areUnchanged() {
        assertEquals("sourcesJson", LegacyPrefKeys.SOURCES_JSON.name)
        assertEquals("ripServerUrl", LegacyPrefKeys.RIP_SERVER_URL.name)
        assertEquals("ripToken", LegacyPrefKeys.RIP_TOKEN.name)
        assertEquals("jukeboxServerUrl", LegacyPrefKeys.JUKEBOX_SERVER_URL.name)
        assertEquals("jukeboxToken", LegacyPrefKeys.JUKEBOX_TOKEN.name)
        assertEquals("jukeboxTokensRequiredByDefault", LegacyPrefKeys.JUKEBOX_TOKENS_REQUIRED.name)
        assertEquals("onlineSearchEnabled", LegacyPrefKeys.ONLINE_SEARCH_ENABLED.name)
        assertEquals("installId", LegacyPrefKeys.INSTALL_ID.name)
        assertEquals("browseSnapshotJson", LegacyPrefKeys.BROWSE_SNAPSHOT_JSON.name)
        assertEquals("collectionSort", LegacyPrefKeys.COLLECTION_SORT.name)
        assertEquals("playlistsMode", LegacyPrefKeys.PLAYLISTS_MODE.name)
        assertEquals("collapsedFolderIds", LegacyPrefKeys.COLLAPSED_FOLDER_IDS.name)
        assertEquals("expandedSourceNames", LegacyPrefKeys.EXPANDED_SOURCE_NAMES.name)
        assertEquals("musicUserToken", LegacyPrefKeys.MUSIC_USER_TOKEN.name)
        assertEquals("appleMusicDeveloperToken", LegacyPrefKeys.AM_DEV_TOKEN.name)
        assertEquals("appleMusicDeveloperTokenExpiresAt", LegacyPrefKeys.AM_DEV_TOKEN_EXP.name)
        assertEquals("lastSection", LegacyPrefKeys.LAST_SECTION.name)
        assertFalse(LegacyPrefKeys.SECRETS_MIGRATED.default)
    }

    @Test
    fun lastSection_persistsAndRestores() = runBlocking {
        val s = store()
        val lss = com.levi.pocketdj.shell.LastSectionStore(s)
        assertEquals(com.levi.pocketdj.navigation.PocketDjDestination.History, lss.restore())
        lss.save(com.levi.pocketdj.navigation.PocketDjDestination.Playlists)
        assertEquals(com.levi.pocketdj.navigation.PocketDjDestination.Playlists, lss.restore())
        assertEquals("Playlists", s.get(LegacyPrefKeys.LAST_SECTION))
    }
}

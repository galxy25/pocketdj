package com.levi.pocketdj.screens.settings

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.PlaybackPrefKeys
import com.levi.pocketdj.playback.PlaybackSettings
import com.levi.pocketdj.screens.playlists.toggled
import com.levi.pocketdj.screens.settings.sections.PlaybackSectionModel
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlaybackSectionTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun store(file: File, scope: CoroutineScope) =
        AppSettingsStore(PreferenceDataStoreFactory.create(scope = scope) { file })

    @Test fun modeRow_roundTripsAndPersistsAcrossInstances() = runBlocking {
        val file = File(tmp.root, "pb.preferences_pb")
        val s1 = CoroutineScope(Dispatchers.IO + Job())
        val a = store(file, s1)
        assertEquals(PlaybackMode.CLOUD, PlaybackSettings(a).mode())
        PlaybackSettings(a).setMode(PlaybackMode.DEVICE)
        // the section and the per-collection toggle both read this flow
        assertEquals(PlaybackMode.DEVICE, PlaybackSectionModel.modeOf(a.flow(PlaybackPrefKeys.PLAYBACK_MODE).first()))
        s1.cancel()
        val s2 = CoroutineScope(Dispatchers.IO + Job())
        assertEquals(PlaybackMode.DEVICE, PlaybackSettings(store(file, s2)).mode())
        s2.cancel()
    }

    @Test fun perCollectionToggle_flipsTheSameValueTheRowShows() = runBlocking {
        val s = CoroutineScope(Dispatchers.IO + Job())
        val st = store(File(tmp.root, "t.preferences_pb"), s)
        val ps = PlaybackSettings(st)
        ps.setMode(ps.mode().toggled())
        assertEquals(PlaybackMode.DEVICE, PlaybackSectionModel.modeOf(st.flow(PlaybackPrefKeys.PLAYBACK_MODE).first()))
        ps.setMode(ps.mode().toggled())
        assertEquals(PlaybackMode.CLOUD, PlaybackSectionModel.modeOf(st.flow(PlaybackPrefKeys.PLAYBACK_MODE).first()))
        s.cancel()
    }

    @Test fun unknownTokenFallsBackToCloud_andCopyDiffersPerMode() {
        assertEquals(PlaybackMode.CLOUD, PlaybackSectionModel.modeOf("garbage"))
        assertEquals(PlaybackMode.CLOUD, PlaybackSectionModel.modeOf(null))
        assertNotEquals(
            PlaybackSectionModel.caption(PlaybackMode.DEVICE),
            PlaybackSectionModel.caption(PlaybackMode.CLOUD),
        )
        assertEquals(listOf("Device", "Cloud"), PlaybackSectionModel.options.map(PlaybackSectionModel::title))
    }
}

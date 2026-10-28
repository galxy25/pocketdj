package com.levi.pocketdj.mix

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.screens.mix.DeckLayout
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MixSettingsTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun store(file: File, scope: CoroutineScope) =
        AppSettingsStore(PreferenceDataStoreFactory.create(scope = scope) { file })

    @Test fun defaultsAreTheIosDefaults() = runBlocking {
        val scope = CoroutineScope(Dispatchers.IO + Job())
        val s = store(File(tmp.root, "d.preferences_pb"), scope).mixSettings()
        assertEquals(15.0, s.autoMixLeadSeconds, 0.0)
        assertEquals(3.0, s.autoMixFadeSeconds, 0.0)
        assertEquals(15.0, s.skipFadeSeconds, 0.0)
        assertEquals(10.0, s.mixGlideSeconds, 0.0)
        assertTrue(s.mixAutoHidePlayed)
        assertEquals(CueChannel.RIGHT, s.cueOutputChannel)
        assertEquals(false, s.beatPulseEnabled)
        assertEquals(DeckLayout.STACKED, s.mixDeckLayout)
        scope.cancel()
    }

    @Test fun persistsAndReloadsAcrossStoreInstances() = runBlocking {
        val file = File(tmp.root, "p.preferences_pb")
        val scope1 = CoroutineScope(Dispatchers.IO + Job())
        val a = store(file, scope1)
        a.setMixLeadSeconds(20.0); a.setMixFadeSeconds(6.0); a.setMixSkipFadeSeconds(30.0); a.setMixGlideSeconds(4.0)
        a.setMixAutoHidePlayed(false); a.setMixCueChannel(CueChannel.LEFT); a.setMixBeatPulse(true)
        a.setMixDeckLayout(DeckLayout.SINGLE)
        scope1.cancel()
        val scope2 = CoroutineScope(Dispatchers.IO + Job())
        val s = store(file, scope2).mixSettings()
        assertEquals(MixSettings(20.0, 6.0, 30.0, 4.0, false, CueChannel.LEFT, true, DeckLayout.SINGLE), s)
        scope2.cancel()
    }

    @Test fun keysAreAdditive_oneWriteLeavesTheRestAtDefault() = runBlocking {
        val scope = CoroutineScope(Dispatchers.IO + Job())
        val a = store(File(tmp.root, "a.preferences_pb"), scope)
        a.setMixBeatPulse(true)
        assertEquals(MixSettings(beatPulseEnabled = true), a.mixSettings())
        scope.cancel()
    }

    @Test fun writesAreClamped_andUnknownRawsFallBack() = runBlocking {
        val scope = CoroutineScope(Dispatchers.IO + Job())
        val a = store(File(tmp.root, "c.preferences_pb"), scope)
        a.setMixLeadSeconds(500.0); a.setMixFadeSeconds(-3.0); a.setMixSkipFadeSeconds(0.0); a.setMixGlideSeconds(99.0)
        a.set(MixSettingsKeys.CUE_CHANNEL, "bogus"); a.set(MixSettingsKeys.DECK_LAYOUT, "bogus")
        val s = a.mixSettings()
        assertEquals(60.0, s.autoMixLeadSeconds, 0.0)
        assertEquals(1.0, s.autoMixFadeSeconds, 0.0)
        assertEquals(1.0, s.skipFadeSeconds, 0.0)
        assertEquals(30.0, s.mixGlideSeconds, 0.0)
        assertEquals(CueChannel.RIGHT, s.cueOutputChannel)
        assertEquals(DeckLayout.STACKED, s.mixDeckLayout)
        scope.cancel()
    }

    @Test fun persistedKeyNamesMatchIos() {
        assertEquals(
            listOf("autoMixLeadSeconds", "autoMixFadeSeconds", "skipFadeSeconds", "mixGlideSeconds", "mixAutoHidePlayed",
                "cueOutputChannel", "beatPulseEnabled", "mixDeckLayout"),
            listOf(MixSettingsKeys.LEAD, MixSettingsKeys.FADE, MixSettingsKeys.SKIP_FADE, MixSettingsKeys.GLIDE,
                MixSettingsKeys.AUTO_HIDE_PLAYED, MixSettingsKeys.CUE_CHANNEL, MixSettingsKeys.BEAT_PULSE, MixSettingsKeys.DECK_LAYOUT).map { it.name },
        )
    }

    private class Sink : MixSettingsSink {
        val calls = ArrayList<String>()
        override fun setCueOnRight(right: Boolean) { calls += "cue=$right" }
        override fun setBeatPulseEnabled(on: Boolean) { calls += "pulse=$on" }
        override fun setMixGlideSeconds(seconds: Double) { calls += "glide=$seconds" }
        override fun setSkipFadeSeconds(seconds: Double) { calls += "skip=$seconds" }
    }

    @Test fun pushChangesOnlyTouchesWhatChanged() {
        val sink = Sink()
        val a = MixSettings()
        MixSettingsPush.pushChanges(a, a.copy(cueOutputChannel = CueChannel.LEFT, skipFadeSeconds = 8.0), sink)
        assertEquals(listOf("skip=8.0", "cue=false"), sink.calls)
        sink.calls.clear()
        MixSettingsPush.pushChanges(a, a, sink)
        assertTrue(sink.calls.isEmpty())
        MixSettingsPush.pushAll(a, sink)
        assertEquals(listOf("cue=true", "pulse=false", "glide=10.0", "skip=15.0"), sink.calls)
    }
}

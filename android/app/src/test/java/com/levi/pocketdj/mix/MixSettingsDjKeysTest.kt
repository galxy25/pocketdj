package com.levi.pocketdj.mix

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.levi.pocketdj.data.settings.AppSettingsStore
import com.levi.pocketdj.playback.dj.DJModeSettings
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MixSettingsDjKeysTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun store(file: File, scope: CoroutineScope) =
        AppSettingsStore(PreferenceDataStoreFactory.create(scope = scope) { file })

    @Test fun keyNamesAreTheIosFieldNames() {
        assertEquals("djTransitions", MixSettingsKeys.DJ_TRANSITIONS.name)
        assertEquals("djEffectSweeps", MixSettingsKeys.DJ_EFFECT_SWEEPS.name)
        assertEquals("djTempoMatch", MixSettingsKeys.DJ_TEMPO_MATCH.name)
        assertEquals("djKeyMatch", MixSettingsKeys.DJ_KEY_MATCH.name)
        assertEquals("djVolumeLeveling", MixSettingsKeys.DJ_VOLUME_LEVELING.name)
        assertEquals("djTempoWaves", MixSettingsKeys.DJ_TEMPO_WAVES.name)
        assertEquals("djPockets", MixSettingsKeys.DJ_POCKETS.name)
        assertEquals("mixVolumeGlide", MixSettingsKeys.VOLUME_GLIDE.name)
    }

    @Test fun missingKeysDefaultDjOnAndVolumeGlideOff() = runBlocking {
        val scope = CoroutineScope(Dispatchers.IO + Job())
        val s = store(File(tmp.root, "d.preferences_pb"), scope).mixSettings()
        assertEquals(DJModeSettings.ALL_ON, s.dj)
        assertFalse(s.mixVolumeGlide)
        assertEquals(MixSettings(), s)
        scope.cancel()
    }

    @Test fun togglesPersistIndependentlyAndNeverTouchSharedTimings() = runBlocking {
        val file = File(tmp.root, "p.preferences_pb")
        val scope1 = CoroutineScope(Dispatchers.IO + Job())
        val a = store(file, scope1)
        a.setMixLeadSeconds(20.0)
        a.setDjTempoMatch(false); a.setDjPockets(false); a.setMixVolumeGlide(true)
        scope1.cancel()
        val scope2 = CoroutineScope(Dispatchers.IO + Job())
        val s = store(file, scope2).mixSettings()
        assertFalse(s.dj.tempoMatch); assertFalse(s.dj.pockets)
        assertTrue(s.dj.transitions && s.dj.effectSweeps && s.dj.keyMatch && s.dj.volumeLeveling && s.dj.tempoWaves)
        assertTrue(s.mixVolumeGlide)
        assertEquals(20.0, s.autoMixLeadSeconds, 0.0)
        assertEquals(3.0, s.autoMixFadeSeconds, 0.0)
        scope2.cancel()
    }

    @Test fun timingRangesMatchIos() {
        assertEquals(3.0..60.0, MixSettings.LEAD_RANGE)
        assertEquals(1.0..12.0, MixSettings.FADE_RANGE)
        assertEquals(1.0..60.0, MixSettings.SKIP_FADE_RANGE)
        assertEquals(1.0..30.0, MixSettings.GLIDE_RANGE)
    }
}

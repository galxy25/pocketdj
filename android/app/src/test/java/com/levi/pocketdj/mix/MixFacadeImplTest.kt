package com.levi.pocketdj.mix

import com.levi.pocketdj.mix.engine.AutoUiState
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.screens.mix.MixAutoStarter
import com.levi.pocketdj.screens.mix.MixCratePort
import com.levi.pocketdj.screens.mix.MixDownloadPort
import com.levi.pocketdj.screens.mix.MixEnginePort
import com.levi.pocketdj.shell.MixSource
import com.levi.pocketdj.shell.ShellActionException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import com.levi.pocketdj.mix.model.MixSource as EngineSource

class MixFacadeImplTest {
    private class FakeEngine : MixEnginePort {
        override var autoMixing = false
        override var isRunning = false
        override var autoEnabled = false
        override val autoUi = MutableStateFlow(AutoUiState())
        var started: List<AutoMixItem>? = null
        var label: String? = null
        val settingsPushed = ArrayList<String>()
        override fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?) {
            started = items; this.label = label
        }
        override fun skipToNext(fadeSeconds: Double) {}
        override fun pauseAuto() {}
        override fun resumeAuto() {}
        override fun stopAutoMix() {}
        override fun setFXGlide(on: Boolean) {}
        override fun setMixGlide(on: Boolean) {}
        override fun prepare() {}
        override fun materializePendingRestore() {}
        override fun setCueOnRight(right: Boolean) { settingsPushed += "cue" }
        override fun setBeatPulseEnabled(on: Boolean) { settingsPushed += "pulse" }
        override fun setMixGlideSeconds(seconds: Double) { settingsPushed += "glide" }
        override fun setSkipFadeSeconds(seconds: Double) { settingsPushed += "skipfade" }
    }

    private class FakeDownloads : MixDownloadPort {
        override var isActive = false
        val order = ArrayList<String>()
        override fun begin(sources: List<EngineSource>) { order += "begin"; isActive = true }
        override fun noteAutoStarted(initialIds: Set<String>, lead: Double, fade: Double, label: String?, shuffled: Boolean) { order += "noted:${initialIds.size}" }
        override fun handleMixLeave(engineActive: Boolean) {}
    }

    private class FakeCrates : MixCratePort {
        val tracks = HashMap<EngineSource, List<MixLoadable>>()
        val names = HashMap<EngineSource, String>()
        override fun loadables(source: EngineSource) = tracks[source].orEmpty()
        override fun name(source: EngineSource) = names[source]
    }

    private class Rig {
        val engine = FakeEngine(); val downloads = FakeDownloads(); val crates = FakeCrates()
        var mixing = false; var paused = false
        val log = ArrayList<String>()
        val facade = MixFacadeImpl(
            starter = { MixAutoStarter(engine, downloads, crates, pushSettings = engine) },
            settings = { MixSettings() },
            isAutoMixing = { mixing }, isAutoPaused = { paused },
            remotePause = { log += "remotePause" }, remotePlay = { log += "remotePlay" },
            engineContext = Dispatchers.Unconfined,
        )
    }

    private fun songs(n: Int) = (0 until n).map { MixLoadable("s$it", "T$it", "A") }

    @Test fun startMapsShellSourceToEngineSource_andReportsNameAndCount() = runTest {
        val r = Rig()
        r.crates.names[EngineSource.Pocket("p1")] = "Warmup"
        r.crates.tracks[EngineSource.Pocket("p1")] = songs(3)
        val out = r.facade.startAutoMix(MixSource.Pocket("p1"), shuffle = false, allowPendingStart = false)
        assertEquals("Warmup", out.name)
        assertEquals(3, out.count)
        assertEquals("Warmup", r.engine.label)
        assertEquals(listOf("s0", "s1", "s2"), r.engine.started!!.map { it.loadable.songId })
    }

    @Test fun downloadRunIsKickedBeforeTheEmptyGuard() = runTest {
        val r = Rig()
        r.crates.names[EngineSource.Playlist("pl")] = "Empty"
        try {
            r.facade.startAutoMix(MixSource.Playlist("pl"), false, false)
            fail("expected NoBurnedSongs")
        } catch (e: ShellActionException.NoBurnedSongs) {
            assertEquals("Empty", e.name)
        }
        assertEquals(listOf("begin"), r.downloads.order) // begin ran; no armed pending start
        assertNull(r.engine.started)
    }

    @Test fun pendingStartAllowedWhenARunCanSupplyTheFirstTrack() = runTest {
        val r = Rig()
        r.crates.names[EngineSource.Setlist("sl")] = "Set"
        val out = r.facade.startAutoMix(MixSource.Setlist("sl"), true, allowPendingStart = true)
        assertEquals(0, out.count)
        assertEquals(listOf("begin", "noted:0"), r.downloads.order)
    }

    @Test fun twoCrateStartInterleavesBoth() = runTest {
        val r = Rig()
        val a = EngineSource.Pocket("a"); val b = EngineSource.Playlist("b")
        r.crates.names[a] = "A"; r.crates.names[b] = "B"
        r.crates.tracks[a] = listOf(MixLoadable("a0", "t", "x")); r.crates.tracks[b] = listOf(MixLoadable("b0", "t", "x"))
        val out = r.facade.startAutoMix(MixSource.Pocket("a"), MixSource.Playlist("b"), false, false)
        assertEquals("A + B", out.name)
        assertEquals(listOf("a0", "b0"), r.engine.started!!.map { it.loadable.songId })
    }

    @Test fun deletedCrateMapsToMixSourceNotFound() = runTest {
        val r = Rig()
        try {
            r.facade.startAutoMix(MixSource.Pocket("gone"), false, false)
            fail("expected MixSourceNotFound")
        } catch (e: ShellActionException) {
            assertTrue(e === ShellActionException.MixSourceNotFound)
        }
    }

    @Test fun headlessStartPushesTheMixSettingsFirst() = runTest {
        val r = Rig()
        r.crates.names[EngineSource.Pocket("p")] = "P"; r.crates.tracks[EngineSource.Pocket("p")] = songs(1)
        r.facade.startAutoMix(MixSource.Pocket("p"), false, false)
        assertTrue(r.engine.settingsPushed.isNotEmpty())
    }

    @Test fun pauseAndResumeGoThroughTheLockScreenSeam() {
        val r = Rig(); r.mixing = true
        r.facade.pauseAutoMix(); r.paused = true
        r.facade.resumeAutoMix()
        assertEquals(listOf("remotePause", "remotePlay"), r.log)
        assertTrue(r.facade.autoMixing); assertTrue(r.facade.autoPaused)
        r.mixing = false; r.paused = false
        assertFalse(r.facade.autoMixing)
    }
}

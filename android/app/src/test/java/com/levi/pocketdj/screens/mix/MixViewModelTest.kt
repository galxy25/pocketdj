package com.levi.pocketdj.screens.mix

import com.levi.pocketdj.mix.MixSettings
import com.levi.pocketdj.mix.engine.AutoUiState
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

@OptIn(ExperimentalCoroutinesApi::class)
class MixViewModelTest {

    private class FakeEngine : MixEnginePort {
        override var autoMixing = false
        override var isRunning = false
        override var autoEnabled = false
        override val autoUi = MutableStateFlow(AutoUiState())
        val log = ArrayList<String>()
        class Start(val items: List<AutoMixItem>, val shuffled: Boolean, val lead: Double, val fade: Double, val label: String?)
        var started: Start? = null
        override fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?) {
            started = Start(items, shuffled, lead, fade, label); log += "start"
        }
        override fun skipToNext(fadeSeconds: Double) { log += "skip=$fadeSeconds" }
        override fun pauseAuto() { log += "pause" }
        override fun resumeAuto() { log += "resume" }
        override fun stopAutoMix() { log += "stop" }
        override fun setFXGlide(on: Boolean) { log += "fx=$on" }
        override fun setMixGlide(on: Boolean) { log += "mixglide=$on" }
        override fun prepare() { log += "prepare" }
        var restoreEnables = false
        override fun materializePendingRestore() { log += "materialize"; if (restoreEnables) autoEnabled = true }
        override fun setCueOnRight(right: Boolean) { log += "cue=$right" }
        override fun setBeatPulseEnabled(on: Boolean) { log += "pulse=$on" }
        override fun setMixGlideSeconds(seconds: Double) { log += "glide=$seconds" }
        override fun setSkipFadeSeconds(seconds: Double) { log += "skipfade=$seconds" }
    }

    private class FakeDownloads : MixDownloadPort {
        override var isActive = false
        val begins = ArrayList<List<MixSource>>()
        class Noted(val ids: Set<String>, val lead: Double, val fade: Double, val label: String?, val shuffled: Boolean)
        val noted = ArrayList<Noted>()
        val leaves = ArrayList<Boolean>()
        override fun begin(sources: List<MixSource>) { begins += sources; isActive = true }
        override fun noteAutoStarted(initialIds: Set<String>, lead: Double, fade: Double, label: String?, shuffled: Boolean) {
            noted += Noted(initialIds, lead, fade, label, shuffled)
        }
        override fun handleMixLeave(engineActive: Boolean) { leaves += engineActive }
    }

    private class FakeCrates : MixCratePort {
        val tracks = HashMap<MixSource, List<MixLoadable>>()
        val names = HashMap<MixSource, String>()
        override fun loadables(source: MixSource) = tracks[source].orEmpty()
        override fun name(source: MixSource) = names[source]
        /** Cold-start catalog: crate members only resolve once [ensureLoaded] has run. */
        var lateTracks: Map<MixSource, List<MixLoadable>>? = null
        var ensureCalls = 0
        override suspend fun ensureLoaded() { ensureCalls++; lateTracks?.let { tracks.putAll(it); lateTracks = null } }
    }

    private val A = MixSource.Pocket("A")
    private val B = MixSource.Playlist("B")
    private fun songs(prefix: String, n: Int) = (0 until n).map { MixLoadable("$prefix$it", "T$prefix$it", "art", lengthMs = if (it == 0) null else 200_000) }

    private class Rig(val settings: MutableStateFlow<MixSettings> = MutableStateFlow(MixSettings())) {
        val engine = FakeEngine()
        val downloads = FakeDownloads()
        val crates = FakeCrates()
        val scope = TestScope(UnconfinedTestDispatcher())
        fun vm(random: Random = Random(1)) = MixViewModel(engine, downloads, crates, settings, scope, random)
    }

    private fun rig(): Rig = Rig().also {
        it.crates.names[A] = "Alpha"; it.crates.names[B] = "Beta"
        it.crates.tracks[A] = songs("a", 3); it.crates.tracks[B] = songs("b", 2)
    }

    // ---- two-crate start ---------------------------------------------------------------------

    @Test fun twoCrateInterleavesA0B0A1B1_andStartsTheUnionRun() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setAutoEnabled(true)
        vm.setAutoSource(A); vm.setAutoSourceB(B)
        r.downloads.begins.clear()
        vm.startAuto(shuffled = false)
        val s = r.engine.started!!
        assertEquals(listOf("a0", "b0", "a1", "b1", "a2"), s.items.map { it.loadable.songId })
        assertEquals(listOf("Alpha", "Beta", "Alpha", "Beta", "Alpha"), s.items.map { it.sourceLabel })
        assertEquals("Alpha + Beta", s.label)
        assertEquals(listOf(listOf(A, B)), r.downloads.begins)             // union run, one begin
        val n = r.downloads.noted.single()
        assertEquals(setOf("a0", "a1", "a2", "b0", "b1"), n.ids)
        assertEquals(15.0, n.lead, 0.0); assertEquals(3.0, n.fade, 0.0)
        assertEquals(180_000, s.items[0].durationMs)                       // unknown length => 3 min default
        assertEquals(200_000, s.items[2].durationMs)
    }

    @Test fun twoCrateShufflesEachCrateOnItsOwn_keepingTheInterleaveShape() = runTest {
        val r = rig(); val vm = r.vm(Random(7))
        vm.setAutoEnabled(true); vm.setAutoSource(A); vm.setAutoSourceB(B)
        vm.startAuto(shuffled = true)
        val ids = r.engine.started!!.items.map { it.loadable.songId }
        assertEquals(setOf("a0", "a1", "a2", "b0", "b1"), ids.toSet())
        // Positions 0,2,4 are crate A; 1,3 are crate B (per-crate shuffle, then A0,B0,A1,B1..).
        assertTrue(listOf(0, 2, 4).all { ids[it].startsWith("a") })
        assertTrue(listOf(1, 3).all { ids[it].startsWith("b") })
        assertFalse(r.engine.started!!.shuffled)                           // already shuffled per crate
    }

    @Test fun crateBLosesSongsCrateAAlreadyHolds() {
        val a = songs("x", 2)
        val b = listOf(a[1], MixLoadable("y0", "Y", "art"))
        val q = AutoMixPlan.interleave(a, b, "A", "B", shuffle = false, random = Random(0))
        assertEquals(listOf("x0", "y0", "x1"), q.items.map { it.loadable.songId })
    }

    @Test fun singleCrateStartPassesShuffleToTheEngineAndArmsProgressiveEligibility() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setAutoSource(A)
        vm.startAuto(shuffled = true)
        val s = r.engine.started!!
        assertTrue(s.shuffled)
        assertEquals(listOf("a0", "a1", "a2"), s.items.map { it.loadable.songId })
        assertEquals("Alpha", s.label)
        assertTrue(s.items.all { it.sourceLabel == null })
        assertEquals(setOf("a0", "a1", "a2"), r.downloads.noted.single().ids)
        assertTrue(r.downloads.noted.single().shuffled)
        assertNull(vm.state.value.autoStartError)
    }

    @Test fun sameCrateForBIsASingleCrateMix() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setAutoSource(A); vm.setAutoSourceB(A)
        assertNull(vm.state.value.autoCrateB)
        vm.startAuto(false)
        assertEquals("Alpha", r.engine.started!!.label)
    }

    // ---- zero start --------------------------------------------------------------------------

    @Test fun nothingDownloaded_twoCrates_zeroStartsPendingTheFirstLanding() = runTest {
        val r = rig(); r.crates.tracks[A] = emptyList(); r.crates.tracks[B] = emptyList()
        val vm = r.vm()
        vm.setAutoEnabled(true); vm.setAutoSource(A); vm.setAutoSourceB(B)
        vm.startAuto(false)
        assertNull(r.engine.started)                                         // no engine start...
        val n = r.downloads.noted.single()                                   // ...but armed with an empty queue
        assertTrue(n.ids.isEmpty()); assertEquals("Alpha + Beta", n.label)
        assertNull(vm.state.value.autoStartError)
    }

    @Test fun nothingDownloadedAndNoRun_surfacesAnErrorLine() = runTest {
        val r = rig(); r.crates.tracks[A] = emptyList(); r.crates.tracks[B] = emptyList()
        val vm = r.vm()
        // A downloader that never activates (no rip server / nothing to pull).
        val dead = object : MixDownloadPort by r.downloads {
            override val isActive = false
            override fun begin(sources: List<MixSource>) {}
        }
        val vm2 = MixViewModel(r.engine, dead, r.crates, r.settings, r.scope)
        vm2.setAutoSource(A); vm2.setAutoSourceB(B); vm2.startAuto(false)
        assertNotNull(vm2.state.value.autoStartError)
        assertTrue(vm2.state.value.autoStartError!!.contains("Alpha + Beta"))
        assertNotNull(vm)
    }

    @Test fun singleCrateWithNothingOnDiskStillArmsTheRun() = runTest {
        val r = rig(); r.crates.tracks[A] = emptyList()
        val vm = r.vm(); vm.setAutoSource(A); vm.startAuto(false)
        assertTrue(r.downloads.noted.single().ids.isEmpty())
        assertEquals(listOf(listOf(A)), r.downloads.begins.takeLast(1))
    }

    // ---- funnels -----------------------------------------------------------------------------

    @Test fun autoCratesSyncDeckSourcesAndBeginDownload() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setAutoSource(A)                                                  // Auto OFF: no deck mirroring
        assertNull(vm.state.value.sourceA)
        assertEquals(listOf(listOf(A)), r.downloads.begins)
        vm.setAutoEnabled(true)                                              // flipping Auto on mirrors
        assertEquals(A, vm.state.value.sourceA); assertEquals(A, vm.state.value.sourceB)
        vm.setAutoSourceB(B)
        assertEquals(A, vm.state.value.sourceA); assertEquals(B, vm.state.value.sourceB)
        assertEquals(listOf(A, B), r.downloads.begins.last())               // two crates: ALWAYS the union
    }

    @Test fun deckSourceChangeBeginsItsDownload_andPlainReassignmentIsIdempotent() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setSourceA(B)
        assertEquals(listOf(listOf(B)), r.downloads.begins)
        vm.setSourceA(B)                                                     // unchanged => no second funnel
        assertEquals(1, r.downloads.begins.size)
        vm.setSourceB(null)                                                  // nil is nil-safe
        assertEquals(1, r.downloads.begins.size)
    }

    @Test fun manualDeckSourceWhileAutoHasTwoCratesKeepsTheUnionRun() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setAutoEnabled(true); vm.setAutoSource(A); vm.setAutoSourceB(B)
        r.downloads.begins.clear()
        vm.setSourceA(MixSource.Pocket("other"))
        assertEquals(listOf(listOf(A, B)), r.downloads.begins)               // never a single-source begin
    }

    @Test fun resetEntryClearsCrateB() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setAutoSource(A); vm.setAutoSourceB(B)
        vm.setAutoSourceB(null)
        assertNull(vm.state.value.autoSourceB)
        assertTrue(vm.state.value.autoDownloadSources == listOf(A))
    }

    // ---- skip --------------------------------------------------------------------------------

    @Test fun engineEnabledFlipOutsideTheScreen_isMirroredAndSyncsDecks() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setAutoSource(A)
        assertFalse(vm.state.value.autoEnabled)
        r.engine.autoEnabled = true
        r.engine.autoUi.value = AutoUiState(enabled = true)    // restore / headless start flips the engine
        assertTrue(vm.state.value.autoEnabled)
        assertEquals(A, vm.state.value.sourceA)                 // deck sources mirrored
        r.engine.autoUi.value = AutoUiState(enabled = false)
        assertFalse(vm.state.value.autoEnabled)
    }

    @Test fun runAdoptsEngineEnabledAfterMaterializingARestore() = runTest {
        val r = rig(); val vm = r.vm()
        r.engine.restoreEnables = true     // the parked restore flips dj.enabled without a ui emission
        val job = r.scope.launch { vm.run() }
        assertTrue(vm.state.value.autoEnabled)
        job.cancel()
    }

    @Test fun deletedCrateFailsLikeMixSourceNotFound() = runTest {
        val r = rig(); r.crates.names.remove(B)
        val starter = MixAutoStarter(r.engine, r.downloads, r.crates)
        try { starter.start(A, B, false, true, MixSettings()); org.junit.Assert.fail("expected not found") }
        catch (e: MixSourceNotFoundException) { assertEquals(B, e.source) }
        assertNull(r.engine.started)
    }

    @Test fun autoStartWaitsForColdCatalogBeforeJudgingTheCrateEmpty() = runTest {
        val r = rig(); r.crates.tracks.remove(A)
        r.crates.lateTracks = mapOf(A to songs("a", 3))
        val out = MixAutoStarter(r.engine, r.downloads, r.crates).start(A, null, false, false, MixSettings())
        assertEquals(1, r.crates.ensureCalls)
        assertEquals(3, out.count)
        assertNotNull(r.engine.started)
    }

    @Test fun unnamedSetlistStillReadsSetList_andStartPushesSettings() = runTest {
        val r = rig(); val sl = MixSource.Setlist("s")
        r.crates.tracks[sl] = songs("s", 1)
        MixAutoStarter(r.engine, r.downloads, r.crates, pushSettings = r.engine).start(sl, null, false, true, MixSettings())
        assertEquals("Set list", r.engine.started!!.label)
        assertTrue(r.engine.log.any { it.startsWith("skipfade=") })
    }

    @Test fun skipSingleVsDoubleTap() = runTest {
        val r = rig(); r.settings.value = MixSettings(skipFadeSeconds = 22.0)
        val vm = r.vm()
        vm.skip(1); vm.skip(2); vm.skip(3)
        assertEquals(listOf("skip=22.0", "skip=5.0", "skip=5.0"), r.engine.log.filter { it.startsWith("skip=") })
        assertEquals(5.0, SkipGesture.fadeSeconds(2, 15.0), 0.0)
        assertEquals(15.0, SkipGesture.fadeSeconds(1, 15.0), 0.0)
    }

    // ---- leave / first composition -----------------------------------------------------------

    @Test fun leaveReportsLiveEngine_soTheDownloaderOnlyCancelsWhenNothingIsLive() = runTest {
        val r = rig(); val vm = r.vm()
        vm.handleMixLeave()
        r.engine.autoMixing = true; vm.handleMixLeave()
        r.engine.autoMixing = false; r.engine.isRunning = true; vm.handleMixLeave()
        assertEquals(listOf(false, true, true), r.downloads.leaves)
        assertFalse(r.engine.log.contains("stop"))                           // never tears the engine down
    }

    @Test fun runPushesSettingsBeforeMaterializing_thenPushesChangesImmediately() = runTest {
        val r = rig(); r.settings.value = MixSettings(mixGlideSeconds = 7.0)
        val vm = r.vm()
        val job = r.scope.launch { vm.run() }
        assertEquals(listOf("prepare", "cue=true", "pulse=false", "glide=7.0", "skipfade=15.0", "materialize"), r.engine.log)
        r.engine.log.clear()
        r.settings.value = r.settings.value.copy(beatPulseEnabled = true, skipFadeSeconds = 9.0)
        assertEquals(listOf("skipfade=9.0", "pulse=true"), r.engine.log)
        job.cancel()
    }

    @Test fun autoStartUsesTheCurrentSettings() = runTest {
        val r = rig(); r.settings.value = MixSettings(autoMixLeadSeconds = 30.0, autoMixFadeSeconds = 8.0)
        val vm = r.vm(); vm.setAutoSource(A); vm.startAuto(false)
        assertEquals(30.0, r.engine.started!!.lead, 0.0); assertEquals(8.0, r.engine.started!!.fade, 0.0)
    }

    @Test fun glideAndTransportCommandsReachTheEngine() = runTest {
        val r = rig(); val vm = r.vm()
        vm.setFXGlide(true); vm.setMixGlide(false); vm.pauseAuto(); vm.resumeAuto(); vm.stopAuto()
        assertEquals(listOf("fx=true", "mixglide=false", "pause", "resume", "stop"), r.engine.log)
    }
}

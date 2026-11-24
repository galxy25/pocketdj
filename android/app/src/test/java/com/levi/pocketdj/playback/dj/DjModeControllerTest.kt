package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.ParityFlags
import com.levi.pocketdj.playback.durable.SessionDjMode
import com.levi.pocketdj.playback.durable.SnapshotExtras
import com.levi.pocketdj.playback.sequencer.SessionEndReason
import com.levi.pocketdj.playback.sequencer.SessionExtraKey
import com.levi.pocketdj.playback.sequencer.SessionExtras
import com.levi.pocketdj.playback.sequencer.SourceRef
import com.levi.pocketdj.screens.nowplaying.DjChipText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DjModeControllerTest {
    private class FakePorts : DjModeController.Ports {
        override var running = true
        override var held = false
        override var sessionId: String? = "s1"
        override var currentSongId: String? = "a"
        override var mixTabActive = false
        override var mixModeEnabled = false
        var mixCalls = mutableListOf<Boolean>()
        override fun setMixMode(on: Boolean) { mixCalls += on; mixModeEnabled = on }
        override var queueFirstSongId: String? = "song-1"
        override var queueCount = 5
        var persists = 0
        override fun persist() { persists++ }
    }

    private class FakeEngine : DjEngineHooks {
        val calls = mutableListOf<String>()
        var seed: ULong? = null
        override fun applyOnTrackStart(liveClock: Boolean) { calls += "apply" }
        override fun disarm() { calls += "disarm" }
        override fun levelToZero() { calls += "level0" }
        override fun plannerSeeded(seed: ULong) { this.seed = seed; calls += "seed" }
    }

    private class FakeRemote(initial: Boolean = false) : RemoteSessionProbe {
        override val activeFlow = MutableStateFlow(initial)
        override val active: Boolean get() = activeFlow.value
    }

    private val ports = FakePorts()
    private val engine = FakeEngine()
    private val remote = FakeRemote()
    private val c = DjModeController(ports, engine, remote)

    @Test fun onImpliesMixModeSeedsPlannerAndEngages() {
        c.setDjMode(true)
        assertTrue(c.enabled)
        assertEquals(listOf(true), ports.mixCalls)
        val expected = AutoTransition.fxSeed("song-1", 5)
        assertEquals(expected, engine.seed)
        assertEquals(expected, DjPlannerState.fromJson(c.write().planner!!)!!.seed)
        assertEquals(listOf("seed", "apply"), engine.calls)
        assertEquals(1, ports.persists)
    }

    @Test fun onWithMixAlreadyOnDoesNotTouchMixMode() {
        ports.mixModeEnabled = true
        c.setDjMode(true)
        assertTrue(ports.mixCalls.isEmpty())
    }

    @Test fun offDisarmsAndLevelsToZeroButKeepsMixMode() {
        c.setDjMode(true); engine.calls.clear()
        c.setDjMode(false)
        assertFalse(c.enabled)
        assertEquals(listOf("disarm", "level0"), engine.calls)
        assertTrue(ports.mixModeEnabled)
    }

    @Test fun noopWithoutSessionOrWhenUnchanged() {
        ports.running = false
        c.setDjMode(true)
        assertFalse(c.enabled)
        ports.running = true
        c.setDjMode(false)
        assertEquals(0, ports.persists)
        assertTrue(engine.calls.isEmpty())
    }

    @Test fun mixModeOffTurnsDjOff() {
        c.setDjMode(true)
        c.onMixModeChanged(true)
        assertTrue(c.enabled)
        c.onMixModeChanged(false)
        assertFalse(c.enabled)
    }

    @Test fun sessionScopeStartAndEndClearIt() {
        c.setDjMode(true)
        c.onSessionStarted("s2", SourceRef("setlist", null, null))
        assertFalse(c.enabled)
        assertNull(c.state.value.planner)
        c.setDjMode(true)
        c.onSessionEnded(SessionEndReason.STOPPED)
        assertFalse(c.enabled)
        assertNull(c.state.value.planner)
    }

    @Test fun suspensionReasonsAndPriority() {
        assertEquals(DjSuspension.NONE, c.suspension)
        c.setDjMode(true)
        assertEquals(DjSuspension.NONE, c.suspension)
        assertTrue(c.djActive)
        ports.mixTabActive = true
        assertEquals(DjSuspension.MIX_TAB, c.suspension)
        assertFalse(c.djActive)
        assertEquals(DjMode.Indicator.Suspended, c.indicator())
        remote.activeFlow.value = true
        assertEquals(DjSuspension.REMOTE, c.suspension)
        assertEquals(DjMode.Indicator.SuspendedRemote, c.indicator())
    }

    @Test fun suspendingDisarmsAndResumingReengages() {
        c.setDjMode(true); engine.calls.clear()
        ports.mixTabActive = true
        c.onSuspensionInputsChanged()
        assertEquals(listOf("disarm", "level0"), engine.calls)
        c.onSuspensionInputsChanged() // unchanged: nothing more
        assertEquals(2, engine.calls.size)
        ports.mixTabActive = false
        c.onSuspensionInputsChanged()
        assertEquals("apply", engine.calls.last())
        assertEquals(3, engine.calls.size)
    }

    @Test fun remoteSessionSuspendsAndResumes() {
        c.setDjMode(true); engine.calls.clear()
        remote.activeFlow.value = true
        c.onSuspensionInputsChanged()
        assertEquals(listOf("disarm", "level0"), engine.calls)
        remote.activeFlow.value = false
        c.onSuspensionInputsChanged()
        assertEquals("apply", engine.calls.last())
    }

    @Test fun turningOnWhileSuspendedDoesNotArm() {
        ports.mixTabActive = true
        c.setDjMode(true)
        assertTrue(c.enabled)
        assertFalse("apply" in engine.calls)
        ports.mixTabActive = false
        c.onSuspensionInputsChanged()
        assertEquals("apply", engine.calls.last())
    }

    @Test fun heldRestoreComesBackHeldAndArmsOnFirstPlay() {
        val stored = JsonObject(mapOf("seed" to JsonPrimitive(7)))
        ports.held = true
        ports.mixModeEnabled = true
        c.restoreHeld(SessionDjMode(enabled = true, planner = stored))
        assertTrue(c.enabled)
        assertTrue(engine.calls.isEmpty())
        assertFalse(c.djActive)
        assertEquals(stored, c.write().planner)
        ports.held = false
        c.onResumedFromHold()
        assertEquals(7uL, engine.seed)
        assertEquals("apply", engine.calls.last())
    }

    @Test fun toggleOnWhileHeldDoesNotEngageUntilResume() {
        ports.held = true
        c.setDjMode(true)
        assertTrue(c.enabled)
        assertFalse("apply" in engine.calls)
        ports.held = false
        c.onResumedFromHold()
        assertEquals("apply", engine.calls.last())
    }

    @Test fun heldRestoreDjOnWithMixOffTurnsDjOffOnFirstPlay() {
        ports.held = true
        ports.mixModeEnabled = false
        c.restoreHeld(SessionDjMode(enabled = true, planner = JsonObject(mapOf("seed" to JsonPrimitive(7)))))
        ports.held = false
        c.onResumedFromHold()
        assertFalse(c.enabled)
        assertFalse("apply" in engine.calls)
    }

    @Test fun heldWithoutStoredKeyReadsOff() {
        c.setDjMode(true)
        c.onHeld()
        assertFalse(c.enabled)
    }

    @Test fun heldRestoreSurvivesOnHeldAndKeepsUnknownKeys() {
        val unknown = JsonObject(mapOf("future" to JsonPrimitive(1)))
        c.restoreHeld(SessionDjMode(enabled = true, unknownKeys = unknown))
        c.onHeld()
        assertTrue(c.enabled)
        assertEquals(unknown, c.write().unknownKeys)
    }

    @Test fun registryRoundTripRestoresThroughSessionExtras() {
        val extras = SessionExtras()
        extras.register(c)
        c.setDjMode(true)
        val saved = extras.collect(SnapshotExtras())
        assertTrue(saved.djMode!!.enabled)
        assertNotNull(saved.djMode!!.planner)
        c.resetDjMode()
        assertFalse(c.enabled)
        extras.restoreHeld(saved)
        assertTrue(c.enabled)
        assertEquals("djMode", SessionExtraKey.DJ_MODE.name)
    }

    @Test fun plannerSeedAboveInt64SurvivesJson() {
        val seed = 0xFFFF_FFFF_FFFF_FFF0uL
        val json = DjPlannerState(seed).toJson()
        val text = Json.encodeToString(JsonObject.serializer(), json)
        assertTrue(text.contains(seed.toString()))
        ports.mixModeEnabled = true
        c.restoreHeld(SessionDjMode(enabled = true, planner = json))
        c.onResumedFromHold()
        assertEquals(seed, engine.seed)
    }

    @Test fun indicatorOffWithoutDjOrSession() {
        assertEquals(DjMode.Indicator.Off, c.indicator())
        c.setDjMode(true)
        assertEquals(DjMode.Indicator.NextReady, c.indicator())
        ports.running = false
        assertEquals(DjMode.Indicator.Off, c.indicator())
    }

    @Test fun chipWordsAndFlag() {
        assertEquals("DJ — paused · Remote session", DjChipText.words(DjMode.Indicator.SuspendedRemote))
        assertEquals("DJ — paused · Mix tab", DjChipText.words(DjMode.Indicator.Suspended))
        assertEquals("DJ — next mixes in", DjChipText.words(DjMode.Indicator.NextReady))
        assertNull(DjChipText.words(DjMode.Indicator.Off))
        assertEquals("DJ — next mixes in · Clean edition", DjChipText.mixChipNote(DjMode.Indicator.NextReady, "Clean edition"))
        assertEquals("Clean edition", DjChipText.mixChipNote(DjMode.Indicator.Off, "Clean edition"))
        assertNull(DjChipText.mixChipNote(DjMode.Indicator.Off, null))
        assertEquals("On, mixing 50 percent", DjChipText.switchValue(true, 0.5f))
        assertEquals(0.04f, DjChipText.floorFraction(0f), 0f)
        // The flag stays behind the debug toggle until the integrator verifies DJ transitions on the emulator.
        val was = ParityFlags.DEBUG_FORCE_DJ_MODE
        try {
            ParityFlags.DEBUG_FORCE_DJ_MODE = false
            assertFalse("DJ Mode ships hidden until the emulator steps are run", ParityFlags.DJ_MODE)
            ParityFlags.DEBUG_FORCE_DJ_MODE = true
            assertTrue(ParityFlags.DJ_MODE)
        } finally { ParityFlags.DEBUG_FORCE_DJ_MODE = was }
    }
}

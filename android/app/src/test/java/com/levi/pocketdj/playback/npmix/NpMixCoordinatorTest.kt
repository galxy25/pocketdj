package com.levi.pocketdj.playback.npmix

import com.levi.pocketdj.mix.nowplaying.NowPlayingPrefetcher.Step
import com.levi.pocketdj.mix.nowplaying.NpMixSettings
import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.durable.SessionNpMixMode
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.SessionEndReason
import com.levi.pocketdj.playback.sequencer.SessionExtraKey
import com.levi.pocketdj.playback.sequencer.SessionExtras
import com.levi.pocketdj.playback.sequencer.SourceRef
import com.levi.pocketdj.playback.sequencer.StartPath
import com.levi.pocketdj.playback.sequencer.TrackStart
import com.levi.pocketdj.playback.sequencer.UserTransport
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class NpMixCoordinatorTest {
    private class FakePorts : NpMixCoordinator.Ports {
        var cfg = NpMixSettings()
        override fun settings() = cfg
        override var mixTabActive = false
        override var deviceMode = false
        override var running = true
        override var held = false
        override var sessionId: String? = "pses_1"
        override var currentSongId: String? = "a"
        override var currentUid: String? = "u1"
        var window: List<String> = listOf("a", "b")
        override fun currentAndNextResolveIds() = window
        var lanePlans = 0
        override fun replanLane() { lanePlans++ }
        var persists = 0
        override fun persist() { persists++ }
        var modeOffs = 0
        override fun onModeOff() { modeOffs++ }
        val posted = ArrayDeque<() -> Unit>()
        override fun post(block: () -> Unit) { posted += block }
        fun drain() { while (posted.isNotEmpty()) posted.removeFirst()() }
        val lines = mutableListOf<String>()
        override fun log(line: String) { lines += line }
    }

    private class FakeHandOff : NpMixCoordinator.HandOff {
        val attempts = mutableListOf<String>()
        val retries = mutableListOf<String>()
        val rows = mutableListOf<String?>()
        var ended = 0
        override fun attempt(reason: String) { attempts += reason }
        override fun retryOwed(trigger: String) { retries += trigger }
        override fun rowChanged(currentUid: String?) { rows += currentUid }
        override fun sessionEnded() { ended++ }
    }

    private lateinit var ports: FakePorts
    private lateinit var hand: FakeHandOff
    private lateinit var mix: NpMixCoordinator
    private val src = SourceRef("setlist", "set_1", "Set")

    @Before fun setUp() {
        ports = FakePorts(); hand = FakeHandOff(); mix = NpMixCoordinator(ports, hand)
    }

    private fun startSession(defaultOn: Boolean = false) {
        ports.cfg = NpMixSettings(modeDefaultOn = defaultOn)
        mix.onSessionStarted("pses_1", src)
    }

    // ---- session scope ----------------------------------------------------------------------------------

    @Test fun aFreshPlayStartsFromTheSettingsDefault() {
        startSession(defaultOn = false)
        assertFalse(mix.enabled)
        startSession(defaultOn = true)
        assertTrue(mix.enabled)
        assertTrue(mix.buffering)
    }

    @Test fun aNewSessionResetsAPreviousOnToTheDefault() {
        startSession(false)
        mix.setMixMode(true)
        assertTrue(mix.enabled)
        mix.onSessionEnded(SessionEndReason.REPLACED)
        mix.onSessionStarted("pses_2", src)
        assertFalse("per-session, never sticky", mix.enabled)
    }

    @Test fun stopClearsAndTheLaneLeaves() {
        startSession(true)
        val before = ports.lanePlans
        mix.onSessionEnded(SessionEndReason.STOPPED)
        assertFalse(mix.enabled)
        assertEquals(before + 1, ports.lanePlans)
        assertTrue(hand.ended >= 1)
    }

    @Test fun toggleNeedsASessionAndIsANoOpWhenUnchanged() {
        ports.running = false
        mix.setMixMode(true)
        assertFalse(mix.enabled)
        ports.running = true
        mix.setMixMode(false)
        assertEquals("unchanged = no persist", 0, ports.persists)
    }

    @Test fun turningOnPersistsReplansAndTriesAHandOff() {
        startSession(false)
        mix.setMixMode(true)
        assertEquals(1, ports.persists)
        assertEquals(listOf("mode-on"), hand.attempts)
        assertEquals("re-plan is coalesced onto a later turn", 0, ports.lanePlans)
        ports.drain()
        assertEquals(1, ports.lanePlans)
    }

    @Test fun turningOffReplansSynchronouslyAndRunsTheCapCheck() {
        startSession(true)
        val before = ports.lanePlans
        mix.toggleMixMode()
        assertFalse(mix.enabled)
        assertEquals(before + 1, ports.lanePlans)
        assertEquals(1, ports.modeOffs)
        assertEquals(1, ports.persists)
    }

    // ---- held restore -------------------------------------------------------------------------------------

    @Test fun heldRestoreBringsTheFlagBackButArmsNothing() {
        // The sequencer emits onSessionStarted, then delivers the extras, then onHeld.
        ports.held = true
        ports.cfg = NpMixSettings(modeDefaultOn = false)
        mix.onSessionStarted("pses_1", src)
        mix.restoreHeld(SessionNpMixMode(enabled = true))
        assertTrue(mix.enabled)
        assertFalse("held = no buffering until the first play", mix.buffering)
        assertEquals(0, ports.persists)
        assertEquals(0, hand.attempts.size)
        mix.onHeld()
        assertEquals("held replan is the lane's cancel path, never a plan", 1, ports.lanePlans)
        assertFalse(mix.buffering)
        // First ▶: it arms.
        ports.held = false
        mix.onResumedFromHold()
        ports.drain()
        assertEquals(2, ports.lanePlans)
        assertTrue(mix.buffering)
    }

    @Test fun heldRestoreWithoutTheKeyIsOffEvenWhenTheSettingsDefaultIsOn() {
        ports.held = true
        ports.cfg = NpMixSettings(modeDefaultOn = true)
        mix.onSessionStarted("pses_1", src)
        assertTrue(mix.enabled)
        mix.onHeld()
        assertFalse(mix.enabled)
    }

    @Test fun heldRestoreOfAnExplicitOffStaysOffDespiteTheDefault() {
        ports.held = true
        ports.cfg = NpMixSettings(modeDefaultOn = true)
        mix.onSessionStarted("pses_1", src)
        mix.restoreHeld(SessionNpMixMode(enabled = false))
        mix.onHeld()
        assertFalse(mix.enabled)
    }

    // ---- Mix tab suspension -------------------------------------------------------------------------------

    @Test fun suspendedWhileTheMixTabRunsAndResumesWithAHandOffRetry() {
        startSession(true)
        assertTrue(mix.buffering)
        ports.mixTabActive = true
        mix.onMixTabChanged(true)
        assertFalse("suspended", mix.buffering)
        assertTrue(mix.enabled)
        assertTrue("going live never hands off", hand.attempts.isEmpty())
        ports.mixTabActive = false
        mix.onMixTabChanged(false)
        assertTrue(mix.buffering)
        assertEquals(listOf("mix-tab-idle"), hand.attempts)
        ports.drain()
        assertTrue(ports.lanePlans >= 1)
    }

    @Test fun mixTabEventsAreIgnoredWhileMixModeIsOff() {
        startSession(false)
        mix.onMixTabChanged(false)
        assertTrue(hand.attempts.isEmpty())
        assertTrue(ports.posted.isEmpty())
    }

    @Test fun deviceModeNeverBuffers() {
        startSession(true)
        ports.deviceMode = true
        assertFalse(mix.buffering)
        assertTrue(mix.enabled)
    }

    // ---- replan on edits ----------------------------------------------------------------------------------

    @Test fun queueEditsAndTrackStartsCoalesceIntoOneReplan() {
        startSession(true)
        ports.drain()
        val base = ports.lanePlans
        mix.onQueueChanged(2); mix.onQueueChanged(3)
        mix.onTrackStarted(TrackStart(QueueItem("b", uid = "u2"), 1, 5, StartPath.EXO, true))
        assertEquals(1, ports.posted.size)
        ports.drain()
        assertEquals(base + 1, ports.lanePlans)
        assertEquals(listOf<String?>("u2"), hand.rows.takeLast(1))
        mix.onQueueChanged(4)
        ports.drain()
        assertEquals(base + 2, ports.lanePlans)
    }

    @Test fun nothingIsScheduledWhenIdleAndOff() {
        ports.running = false
        mix.scheduleReplan()
        assertTrue(ports.posted.isEmpty())
    }

    @Test fun networkAndSettingsChangesReplan() {
        startSession(true)
        ports.drain()
        val base = ports.lanePlans
        mix.onNetworkChanged("expensive")
        ports.drain()
        assertEquals(base + 1, ports.lanePlans)
        assertTrue(ports.lines.any { it == "network -> expensive" })
    }

    // ---- hand-off triggers --------------------------------------------------------------------------------

    @Test fun aLandedSongOfThePlayingRowHandsOffButNotTheNextOrAStem() {
        startSession(true)
        mix.onStepFinished(Step.Song("a", "A", "x"), ok = true)
        assertEquals(listOf("landed"), hand.attempts)
        mix.onStepFinished(Step.Song("b", "B", "x"), ok = true)
        mix.onStepFinished(Step.StemPart("a", "vocals"), ok = true)
        mix.onStepFinished(Step.Song("a", "A", "x"), ok = false)
        assertEquals(listOf("landed"), hand.attempts)
    }

    @Test fun aLandingWhileHeldNeverHandsOff() {
        startSession(true)
        ports.held = true
        mix.onStepFinished(Step.Song("a", "A", "x"), ok = true)
        assertTrue(hand.attempts.isEmpty())
    }

    @Test fun owedHandOffsRetryOnPlayAndFirstAudioOnlyWhileOn() {
        startSession(false)
        mix.onUserTransport(UserTransport.PLAY)
        mix.onFirstAudio(QueueItem("a"), "player")
        assertTrue(hand.retries.isEmpty())
        mix.setMixMode(true)
        mix.onUserTransport(UserTransport.PLAY)
        mix.onUserTransport(UserTransport.SKIP)
        mix.onFirstAudio(QueueItem("a"), "player")
        assertEquals(listOf("user-play", "after-start"), hand.retries)
    }

    @Test fun firstAudioTriesAHandOffSoAPreloadedStreamWhoseFileLandedEarlyStillSwaps() {
        startSession(false)
        mix.onFirstAudio(QueueItem("a"), "player")
        assertTrue("off: nothing", hand.attempts.isEmpty())
        mix.setMixMode(true)
        hand.attempts.clear()
        mix.onFirstAudio(QueueItem("a"), "player")
        assertEquals(listOf("first-audio"), hand.attempts)
    }

    // ---- stream pinning -----------------------------------------------------------------------------------

    @Test fun pinsTheCurrentAndNextAudioIdsWhileARunExists() {
        assertEquals(setOf("a", "b"), mix.pinnedStreamIds())
        ports.running = false
        assertEquals(emptySet<String>(), mix.pinnedStreamIds())
    }

    // ---- durable session ----------------------------------------------------------------------------------

    @Test fun theExtraIsKeyedNpMixModeAndWritesTheIosShape() {
        startSession(true)
        assertEquals("npMixMode", mix.key.name)
        assertEquals(SessionExtraKey.NP_MIX_MODE, mix.key)
        assertEquals("""{"enabled":true}""", Json { encodeDefaults = true }.encodeToString(mix.write()))
        mix.setMixMode(false)
        assertEquals("""{"enabled":false}""", Json { encodeDefaults = true }.encodeToString(mix.write()))
    }

    @Test fun registersWithTheSessionExtrasAndCollectsItsFlag() {
        startSession(true)
        val extras = SessionExtras()
        extras.register(mix)
        val out = extras.collect(com.levi.pocketdj.playback.durable.SnapshotExtras())
        assertEquals(true, out.npMixMode?.enabled)
        assertEquals(setOf("npMixMode"), extras.registeredKeys)
    }

    @Test fun aLateRegistrationReceivesAHeldRestoreAlreadyDelivered() {
        val extras = SessionExtras()
        extras.restoreHeld(com.levi.pocketdj.playback.durable.SnapshotExtras(npMixMode = SessionNpMixMode(enabled = true)))
        extras.register(mix)
        assertTrue(mix.enabled)
    }

    // ---- lane trace ---------------------------------------------------------------------------------------

    @Test fun lanePlansLogOneLineEachAndDedupe() {
        startSession(true)
        val steps = listOf(Step.Song("b", "B", "x"), Step.StemPart("b", "vocals"))
        mix.noteLanePlan("a", steps, "unmetered")
        assertEquals(listOf("lane step=song:b row=b net=unmetered", "lane step=vocals:b row=b net=unmetered"), ports.lines.filter { it.startsWith("lane step") })
        mix.noteLanePlan("a", steps, "unmetered")
        assertEquals(2, ports.lines.count { it.startsWith("lane step") })
        mix.noteLanePlan("a", emptyList(), "unmetered")
        assertTrue(ports.lines.any { it.startsWith("lane step=- row=a") })
    }

    @Test fun lanePlansAreSilentWhileMixModeIsOff() {
        startSession(false)
        mix.noteLanePlan("a", listOf(Step.Song("b", "B", "x")), "unmetered")
        assertTrue(ports.lines.none { it.startsWith("lane step") })
        assertNull(null)
    }
}

package com.levi.pocketdj.playback.sequencer

import androidx.media3.common.Player
import com.levi.pocketdj.diag.NPLog
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.health.AutoAdvanceCascadeBreaker
import com.levi.pocketdj.playback.health.DeadAirMeter
import com.levi.pocketdj.playback.health.EngineProbe
import com.levi.pocketdj.playback.health.RunwayLock
import kotlin.random.Random
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The sequencer's PB-3 integration: start window, watchdogs, stall hop, cascade breaker, rip window, live. */
@OptIn(ExperimentalCoroutinesApi::class)
class SequencerHealthTest {
    class FakeEngine : EngineProbe {
        var loaded = true
        var playing = false
        var position = 0L
        var ended = false
        val rekicks = mutableListOf<String>()
        override val hasLoadedItem get() = loaded
        override val isPlaying get() = playing
        override val positionMs get() = position
        override val trackEnded get() = ended
        override fun rekick(by: String) { rekicks += by }
    }

    class FakeLock : RunwayLock {
        val acquired = mutableListOf<String>()
        var released = 0
        override fun acquire(name: String, timeoutMs: Long): () -> Unit {
            acquired += name
            return { released++ }
        }
    }

    private lateinit var tags: MutableList<String>
    private var savedLogd: (String, String) -> Unit = { _, _ -> }

    @Before
    fun captureNpLog() {
        tags = mutableListOf()
        savedLogd = NPLog.logd
        NPLog.logd = { tag, msg -> tags += "${tag.removePrefix("PocketDJ.")}|$msg" }
    }

    @After
    fun restoreNpLog() {
        NPLog.logd = savedLogd
    }

    private fun lane(name: String) = tags.filter { it.startsWith("$name|") }.map { it.substringAfter('|') }

    private class H(
        val t: TestScope,
        playable: Set<String>,
        ripOnDemand: Set<String> = emptySet(),
        withEngine: Boolean = true,
    ) {
        val port = FakePlayerPort()
        val engine = FakeEngine()
        val lock = FakeLock()
        val meter = DeadAirMeter(file = null, log = { }, nowMs = { t.currentTime })
        val logs = mutableListOf<String>()
        val cancelled = mutableListOf<List<String>>()
        val registry = RowResolverRegistry(
            initial = listOf(
                MapResolver("map", Rung.MANIFEST, playable.associateWith { stream(it) }),
                MapResolver("rip", Rung.RIP_ON_DEMAND, ripOnDemand.associateWith { RipOnDemandSource(it) }),
            ),
            manifestHit = { it in playable },
            ripServerConfigured = { true },
        )
        val seq = SetlistSequencer(
            scope = t.backgroundScope,
            port = port,
            registry = registry,
            modeProvider = { PlaybackMode.CLOUD },
            random = Random(1),
            log = { logs += it },
            clockMs = { t.currentTime },
        ).also { s ->
            if (withEngine) s.engine = engine
            s.meter = meter
            s.runwayLock = lock
            s.cancelPlaybackRips = { cancelled += it }
            s.rowStartsInstantly = { it.id in playable }
        }

        fun start(vararg ids: String, tag: String? = null) {
            seq.play(rows(*ids), tag)
            t.runCurrent()
        }
    }

    // ---- runway + start window + first audio ----------------------------------------------------------

    @Test
    fun ripWait_keepsStartPendingPastTheRunwayCap() = runTest {
        val h = H(this, setOf("a"))
        var resolving = true
        h.engine.loaded = false // the stall watchdog is not the subject here
        h.start("a")
        advanceTimeBy(25_100); runCurrent()
        assertFalse("runway cap alone ends the pending start", h.seq.isStartPending)
        h.seq.ripWaitProbe = { resolving }
        assertTrue("a rip-on-demand row still resolving is a pending start", h.seq.isStartPending)
        resolving = false
        assertFalse(h.seq.isStartPending)
    }

    @Test
    fun startWindow_holdsTheRunwayUntilFirstAudio_andClosesTheDeadAirGap() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        assertTrue(h.seq.isStartPending)
        assertEquals(listOf("pocketdj-start-a"), h.lock.acquired)
        assertEquals(0, h.lock.released)
        assertTrue(h.meter.hasOpenTransition)

        advanceTimeBy(1_500)
        h.engine.playing = true
        h.seq.onFirstAudio("a", "player")
        assertFalse(h.seq.isStartPending)
        assertEquals(1, h.lock.released)
        assertFalse(h.meter.hasOpenTransition)
        val d = h.meter.day(currentTime)
        assertEquals(1, d.transitions)
        assertEquals(1.5, d.transitionGapSeconds, 1e-9)
        assertEquals("rip", h.meter.lastAudibleBackend)
        assertTrue(h.logs.any { it == "[playback] start-ok song=a after=1500ms" })
        assertTrue(lane("runway").any { it.startsWith("end name=pocketdj-start-a held=1.5s reason=firstAudio.player") })
    }

    @Test
    fun runwayIsCapped_at25s() = runTest {
        val h = H(this, setOf("a"), withEngine = false) // no engine: the start watchdog (20 s) stays out of it
        h.start("a")
        advanceTimeBy(24_900); runCurrent()
        assertTrue(h.seq.isStartPending)
        advanceTimeBy(200)
        assertFalse(h.seq.isStartPending)
        assertEquals(1, h.lock.released)
        assertTrue(lane("runway").any { it.contains("reason=cap") })
    }

    @Test
    fun aSupersedingStart_endsTheOldRunway_asSuperseded() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.skipNext()
        runCurrent()
        assertEquals(listOf("pocketdj-start-a", "pocketdj-start-b"), h.lock.acquired)
        assertEquals(1, h.lock.released)
        assertTrue(lane("runway").any { it.contains("name=pocketdj-start-a") && it.endsWith("reason=superseded") })
    }

    @Test
    fun stop_endsTheRunway_andAbandonsTheTransition() = runTest {
        val h = H(this, setOf("a"))
        h.start("a")
        h.seq.stop()
        runCurrent()
        assertFalse(h.seq.isStartPending)
        assertEquals(1, h.lock.released)
        assertFalse(h.meter.hasOpenTransition)
        assertTrue(lane("runway").any { it.endsWith("reason=stop") })
    }

    @Test
    fun aStaleRowsAudio_doesNotCloseTheCurrentStart() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.skipNext(); runCurrent()
        h.seq.onFirstAudio("a") // the previous row's late isPlaying edge
        assertTrue(h.seq.isStartPending)
        h.seq.onFirstAudio("b")
        assertFalse(h.seq.isStartPending)
    }

    @Test
    fun firstAudio_isIdempotentPerStart() = runTest {
        val h = H(this, setOf("a"))
        h.start("a")
        h.seq.onFirstAudio("a")
        h.seq.onFirstAudio("a") // pause/resume edges later
        assertEquals(1, h.meter.day(currentTime).transitions)
        assertEquals(1, h.logs.count { it.startsWith("[playback] start-ok") })
    }

    // ---- start watchdog -----------------------------------------------------------------------------------

    @Test
    fun startStall_rekicksAt8s_thenEscalatesAt20s_throughTheBreaker() = runTest {
        val h = H(this, setOf("a", "b", "c", "d"))
        h.start("a", "b", "c", "d")
        advanceTimeBy(8_100)
        assertEquals(listOf("player.startStall"), h.engine.rekicks)
        assertTrue(h.logs.any { it.startsWith("[playback] start-stall song=a waited=8 ") })
        advanceTimeBy(12_000)
        // 20 s: no on-device row, but "b".."d" start instantly -> hop to the first instant row, "a" deferred behind
        assertTrue(h.logs.any { it.startsWith("[playback] start-stall song=a waited=20 ") })
        assertTrue(h.logs.any { it == "[playback] start-stall 20s song=a → hop to instant b (deferred stalled row)" })
        assertEquals(listOf("b", "a", "c", "d"), h.seq.state.value.queue.map { it.id })
        assertEquals("b", h.seq.currentSongId)
        assertEquals(listOf("a", "b"), h.port.loadedIds)
    }

    @Test
    fun startStall_noHopCandidate_advancesAutoAndIsCountedByTheBreaker() = runTest {
        val h = H(this, setOf("a", "b"))
        h.seq.rowStartsInstantly = { false }
        h.start("a", "b")
        advanceTimeBy(20_100)
        assertTrue(h.logs.any { it == "[playback] advance: start-stall 20s song=a — no on-device row to hop to" })
        assertEquals("b", h.seq.currentSongId)
    }

    @Test
    fun startStall_standsDown_forAListenerPause_aFirstAudio_andAnInterruption() = runTest {
        for (case in 0..2) {
            val h = H(this, setOf("a", "b"))
            h.start("a", "b")
            when (case) {
                0 -> h.discriminate { onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) }
                1 -> h.seq.onFirstAudio("a")
                2 -> h.discriminate { onSuppressionChanged(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS) }
            }
            advanceTimeBy(30_000)
            assertTrue("case $case", h.engine.rekicks.isEmpty())
            assertEquals("case $case", "a", h.seq.currentSongId)
        }
    }

    private fun H.discriminate(f: com.levi.pocketdj.playback.health.PauseDiscriminator.() -> Unit) = seq.discriminator.f()

    @Test
    fun supersedingStart_cancelsTheOldWatchdog() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        advanceTimeBy(6_000)
        h.seq.skipNext(); runCurrent()
        advanceTimeBy(3_000) // 9 s after the first start but only 3 s into the second
        assertTrue(h.engine.rekicks.isEmpty())
        advanceTimeBy(5_100)
        assertEquals(1, h.engine.rekicks.size)
    }

    // ---- resolve stall -------------------------------------------------------------------------------------

    @Test
    fun ripRequiredRow_loadsImmediately_thenHopsAt6s_toTheOnDeviceRow() = runTest {
        val h = H(this, playable = setOf("b", "c"), ripOnDemand = setOf("a"))
        h.seq.rowOnDevice = { it.id == "c" }
        h.start("a", "b", "c")
        assertEquals("the rip-required row is current at once", listOf("a"), h.port.loadedIds)
        assertTrue(h.port.loads.single().source is RipOnDemandSource)
        advanceTimeBy(5_900); runCurrent()
        assertEquals("a", h.seq.currentSongId)
        advanceTimeBy(200); runCurrent()
        assertTrue(h.logs.any { it == "[playback] resolve stalled 6s song=a → hop to on-device c (deferred stalled row)" })
        assertEquals(listOf("c", "a", "b"), h.seq.state.value.queue.map { it.id })
        assertEquals(listOf("a", "c"), h.port.loadedIds)
    }

    @Test
    fun resolveStall_prefersOnDevice_overInstant_andFallsBackToInstant() = runTest {
        val h = H(this, playable = setOf("b", "c"), ripOnDemand = setOf("a"))
        h.start("a", "b", "c")
        advanceTimeBy(6_100); runCurrent()
        assertTrue(h.logs.any { it == "[playback] resolve stalled 6s song=a → hop to instant b (deferred stalled row)" })
        assertEquals(listOf("b", "a", "c"), h.seq.state.value.queue.map { it.id })
    }

    @Test
    fun resolveStall_noRowToHopTo_keepsWaiting_withALogLine() = runTest {
        val h = H(this, playable = emptySet(), ripOnDemand = setOf("a", "b"))
        h.start("a", "b")
        advanceTimeBy(6_100); runCurrent()
        assertEquals("a", h.seq.currentSongId)
        assertTrue(h.logs.any { it == "[playback] resolve stalled 6s song=a — no on-device/instant row to hop to; waiting" })
        assertEquals(listOf("a"), h.port.loadedIds)
    }

    @Test
    fun resolvedSource_handsOverToTheStartWatchdog_andCancelsTheStall() = runTest {
        val h = H(this, playable = setOf("b"), ripOnDemand = setOf("a"))
        h.start("a", "b")
        advanceTimeBy(3_000)
        h.seq.noteSourceResolved("a")
        advanceTimeBy(10_000) // the 6 s stall would have hopped by now
        assertEquals("a", h.seq.currentSongId)
        assertEquals("watchdog re-kicks 8 s after the resolve", 1, h.engine.rekicks.size)
    }

    @Test
    fun firstAudio_cancelsTheResolveStall() = runTest {
        val h = H(this, playable = setOf("b"), ripOnDemand = setOf("a"))
        h.start("a", "b")
        advanceTimeBy(2_000)
        h.seq.onFirstAudio("a")
        advanceTimeBy(20_000)
        assertEquals("a", h.seq.currentSongId)
        assertEquals(listOf("a"), h.port.loadedIds)
    }

    @Test
    fun skippingAwayFromARipRow_cancelsItsStall() = runTest {
        val h = H(this, playable = setOf("b", "c"), ripOnDemand = setOf("a"))
        h.start("a", "b", "c")
        advanceTimeBy(3_000)
        h.seq.skipNext(); runCurrent()
        h.seq.onFirstAudio("b")
        advanceTimeBy(20_000)
        assertEquals("b", h.seq.currentSongId)
        assertEquals(listOf("a", "b", "c"), h.seq.state.value.queue.map { it.id })
    }

    // ---- cascade breaker -------------------------------------------------------------------------------------

    @Test
    fun threeQuickAutoAdvances_halt_pause_noticeAndKeepThePosition() = runTest {
        val h = H(this, setOf("a", "b", "c", "d", "e"))
        h.start("a", "b", "c", "d", "e")
        h.seq.handleFailed("a"); runCurrent()
        assertEquals("b", h.seq.currentSongId)
        h.seq.handleFailed("b"); runCurrent()
        assertEquals("c", h.seq.currentSongId)
        h.seq.handleFailed("c"); runCurrent()
        // the third quick advance is NOT performed
        val s = h.seq.state.value
        assertEquals("c", s.currentSongId)
        assertEquals(2, s.index)
        assertTrue(s.pausedByCascade)
        assertTrue(h.seq.isPausedByCascade)
        assertEquals("Playback paused — the last few tracks didn’t play", s.playbackNotice)
        assertEquals(1, h.port.pauses)
        assertFalse(h.seq.discriminator.intentPlaying)
        assertTrue(h.logs.any { it.startsWith("[playback] cascade-stop song=c index=2/5 quickAdvances=3 backend=rip audible=0s") })
        assertFalse("the runway of the halted start is released", h.seq.isStartPending)
        assertFalse(h.meter.hasOpenTransition)
        // nothing advances by itself while halted
        h.seq.handleEnded("c"); runCurrent()
        assertEquals("c", h.seq.currentSongId)
    }

    @Test
    fun appleMusicVariantOfTheNotice() = runTest {
        val h = H(this, setOf("a", "b", "c", "d"))
        h.seq.appleMusicActive = { true }
        h.start("a", "b", "c", "d")
        repeat(3) { h.seq.handleFailed(h.seq.currentSongId!!); runCurrent() }
        assertEquals("Playback paused — Apple Music was interrupted", h.seq.state.value.playbackNotice)
    }

    @Test
    fun playRetriesTheHaltedRow_andClearsTheCascade() = runTest {
        val h = H(this, setOf("a", "b", "c", "d", "e"))
        h.start("a", "b", "c", "d", "e")
        repeat(3) { h.seq.handleFailed(h.seq.currentSongId!!); runCurrent() }
        assertTrue(h.seq.isPausedByCascade)
        val loadsBefore = h.port.loads.size
        assertTrue(h.seq.startCurrent())
        runCurrent()
        assertFalse(h.seq.isPausedByCascade)
        assertNull(h.seq.state.value.playbackNotice)
        assertEquals("c", h.port.loadedIds.last())
        assertEquals(loadsBefore + 1, h.port.loads.size)
        assertTrue(h.seq.discriminator.intentPlaying)
    }

    @Test
    fun skipNext_previous_andJumps_resetTheBreaker() = runTest {
        val h = H(this, setOf("a", "b", "c", "d", "e", "f"))
        h.start("a", "b", "c", "d", "e", "f")
        h.seq.handleFailed("a"); runCurrent()
        h.seq.handleFailed("b"); runCurrent()
        h.seq.skipNext(); runCurrent() // the listener acted: two quick advances are forgiven
        h.seq.handleFailed("d"); runCurrent()
        h.seq.handleFailed("e"); runCurrent()
        assertFalse("only two quick advances since the user acted", h.seq.isPausedByCascade)
        h.seq.skipPrevious(); runCurrent()
        h.seq.handleFailed(h.seq.currentSongId!!); runCurrent()
        assertFalse(h.seq.isPausedByCascade)
    }

    @Test
    fun aTrackThatPlayed5s_resetsTheBreaker() = runTest {
        val h = H(this, setOf("a", "b", "c", "d", "e", "f"))
        h.start("a", "b", "c", "d", "e", "f")
        h.seq.handleFailed("a"); runCurrent()
        h.seq.handleFailed("b"); runCurrent()
        h.seq.addAudibleSeconds(AutoAdvanceCascadeBreaker.MIN_AUDIBLE_SECONDS)
        h.seq.handleEnded("c"); runCurrent() // heard 5 s: not a quick advance
        h.seq.handleFailed("d"); runCurrent()
        assertFalse(h.seq.isPausedByCascade)
        assertEquals("e", h.seq.currentSongId)
    }

    @Test
    fun audibleSeconds_areSampledAt1Hz_onlyWhileTheEngineIsRendering() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        advanceTimeBy(3_100) // engine not playing: nothing counted
        assertEquals(0.0, h.seq.audibleSecondsOfCurrent, 0.0)
        h.engine.playing = true
        advanceTimeBy(4_000)
        assertEquals(4.0, h.seq.audibleSecondsOfCurrent, 1.01)
    }

    @Test
    fun audibleSampling_resetsAtEveryStart() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        h.seq.addAudibleSeconds(12.0)
        h.seq.skipNext(); runCurrent()
        assertEquals(0.0, h.seq.audibleSecondsOfCurrent, 0.0)
    }

    @Test
    fun withoutAnEngine_theBreakerStaysInert() = runTest {
        val h = H(this, setOf("a", "b", "c", "d", "e"), withEngine = false)
        h.start("a", "b", "c", "d", "e")
        repeat(4) { h.seq.handleFailed(h.seq.currentSongId!!); runCurrent() }
        assertFalse(h.seq.isPausedByCascade)
        assertEquals("e", h.seq.currentSongId)
    }

    @Test
    fun hopAndSupervisorHooks_doNotCountAsUserTransport() = runTest {
        val h = H(this, setOf("a", "b", "c", "d", "e"))
        h.start("a", "b", "c", "d", "e")
        h.seq.handleFailed("a"); runCurrent()
        h.seq.handleFailed("b"); runCurrent()
        h.seq.supervisorRetryInPlace(); runCurrent() // NOT a user transport: the breaker keeps its count
        h.seq.handleFailed("c"); runCurrent()
        assertTrue(h.seq.isPausedByCascade)
    }

    // ---- supervisor hooks ---------------------------------------------------------------------------------------

    @Test
    fun retryInPlace_restartsTheRowAtItsPosition_andShortPositionsStartFromTheTop() = runTest {
        val h = H(this, setOf("a", "b"))
        h.start("a", "b")
        h.engine.position = 42_000
        h.seq.supervisorRetryInPlace(); runCurrent()
        assertEquals(42_000L, h.port.loads.last().resumeAtMs)
        h.engine.position = 800
        h.seq.supervisorRetryInPlace(); runCurrent()
        assertNull(h.port.loads.last().resumeAtMs)
        assertTrue(lane("supervisor").contains("retry in place song=a atMs=800"))
    }

    @Test
    fun supervisorHooks_areInertWhenHeldOrHalted() = runTest {
        val h = H(this, setOf("a", "b", "c", "d"))
        h.start("a", "b", "c", "d")
        repeat(3) { h.seq.handleFailed(h.seq.currentSongId!!); runCurrent() }
        val n = h.port.loads.size
        h.seq.supervisorRetryInPlace(); h.seq.supervisorEscalate(); runCurrent()
        assertEquals(n, h.port.loads.size)
    }

    // ---- live ---------------------------------------------------------------------------------------------------

    @Test
    fun liveRow_waitsForLive_thenTheBackstopAdvancesAtLengthPlus45s() = runTest {
        val h = H(this, setOf("a", "b"))
        h.seq.play(listOf(QueueItem(id = "a", lengthMs = 100_000), QueueItem(id = "b")))
        runCurrent()
        h.seq.noteLive("a")
        h.seq.onFirstAudio("a") // the live stream is audible: the start watchdog stands down
        assertTrue(h.seq.state.value.waitingForLive)
        assertTrue(h.seq.isWaitingForLive)
        advanceTimeBy(144_000)
        assertEquals("a", h.seq.currentSongId)
        advanceTimeBy(2_000)
        assertEquals("b", h.seq.currentSongId)
        assertTrue(h.logs.any { it == "[playback] advance: live capture past its length+grace song=a" })
        assertFalse("waitingForLive clears with the advance", h.seq.state.value.waitingForLive)
    }

    @Test
    fun liveBackstop_doesNotCountThePausedTime() = runTest {
        val h = H(this, setOf("a", "b"))
        h.seq.play(listOf(QueueItem(id = "a", lengthMs = 10_000), QueueItem(id = "b")))
        runCurrent()
        h.seq.noteLive("a")
        h.seq.onFirstAudio("a")
        advanceTimeBy(20_000)
        h.discriminate { onPlayWhenReadyChanged(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) }
        advanceTimeBy(300_000)
        assertEquals("a", h.seq.currentSongId)
        h.discriminate { onPlayWhenReadyChanged(true, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) }
        advanceTimeBy(36_000)
        assertEquals("b", h.seq.currentSongId)
    }

    @Test
    fun skippingAwayFromALiveRow_cancelsTheBackstop() = runTest {
        val h = H(this, setOf("a", "b", "c"))
        h.seq.play(listOf(QueueItem(id = "a", lengthMs = 1_000), QueueItem(id = "b"), QueueItem(id = "c")))
        runCurrent()
        h.seq.noteLive("a")
        h.seq.skipNext(); runCurrent()
        h.seq.onFirstAudio("b")
        advanceTimeBy(120_000)
        assertEquals("the stale backstop must not skip b", "b", h.seq.currentSongId)
    }

    // ---- rip window ----------------------------------------------------------------------------------------------

    private fun ids(n: Int) = (0 until n).map { "s$it" }.toTypedArray()

    @Test
    fun ripsOutsideTheWindow_areCancelled_whenThePlayheadMoves_andInsideOnesKept() = runTest {
        val h = H(this, ids(30).toSet())
        h.start(*ids(30))
        h.seq.notePlaybackRipQueued("s0")
        h.seq.notePlaybackRipQueued("s10")
        assertEquals(setOf("s0", "s10"), h.seq.trackedPlaybackRips)
        h.seq.notePlaybackRipQueued("s20") // outside the window at queue time: cancelled at once
        assertEquals(listOf(listOf("s20")), h.cancelled)
        h.seq.skipNext(); runCurrent() // playing s1: window is s1..s11, s0 left it
        assertEquals(listOf(listOf("s20"), listOf("s0")), h.cancelled)
        assertEquals(setOf("s10"), h.seq.trackedPlaybackRips)
        assertTrue(lane("ripreq").any { it == "rip window cancel n=1 reason=outside-window ids=s0" })
    }

    @Test
    fun aRowHeardFor30s_isExemptFromCancellation() = runTest {
        val h = H(this, ids(30).toSet())
        h.start(*ids(30))
        h.seq.notePlaybackRipQueued("s0")
        h.seq.addAudibleSeconds(29.0)
        h.seq.addAudibleSeconds(1.5)
        assertTrue("heard: no longer tracked", "s0" !in h.seq.trackedPlaybackRips)
        h.seq.skipNext(); runCurrent()
        assertTrue(h.cancelled.isEmpty())
    }

    @Test
    fun userRequestedRips_areNeverCancelled() = runTest {
        val h = H(this, ids(30).toSet())
        h.seq.isUserRequestedRip = { it == "s5" }
        h.start(*ids(30))
        h.seq.notePlaybackRipQueued("s5") // not even tracked
        assertTrue(h.seq.trackedPlaybackRips.isEmpty())
        h.seq.notePlaybackRipQueued("s2")
        h.seq.jumpToUpcoming(h.seq.upcomingUid(11)!!); runCurrent() // playing s12: s2 left, s5 was never tracked
        assertEquals(listOf(listOf("s2")), h.cancelled)
    }

    @Test
    fun queueEdits_reconcileTheWindow_coalesced() = runTest {
        val h = H(this, ids(30).toSet())
        h.start(*ids(30))
        h.seq.notePlaybackRipQueued("s10")
        // push s10 out of the window by inserting 11 rows right after the playing one, twice in one turn
        h.seq.insertNextInQueue(rows(*(0 until 6).map { "x$it" }.toTypedArray()))
        h.seq.insertNextInQueue(rows(*(0 until 6).map { "y$it" }.toTypedArray()))
        runCurrent()
        assertEquals(listOf(listOf("s10")), h.cancelled)
    }

    @Test
    fun endOfSession_cancelsEverythingButThePlayingRow() = runTest {
        val h = H(this, ids(30).toSet())
        h.start(*ids(30))
        h.seq.notePlaybackRipQueued("s0")
        h.seq.notePlaybackRipQueued("s3")
        h.seq.notePlaybackRipQueued("s7")
        h.seq.stop()
        runCurrent()
        assertEquals(listOf(listOf("s3", "s7")), h.cancelled)
        assertTrue(h.seq.trackedPlaybackRips.isEmpty())
    }

    @Test
    fun aFreshPlayOverARunningSet_cancelsTheOldSessionsRips() = runTest {
        val h = H(this, ids(30).toSet() + "z1")
        h.start(*ids(30))
        h.seq.notePlaybackRipQueued("s0")
        h.seq.notePlaybackRipQueued("s4")
        h.seq.play(rows("z1"))
        runCurrent()
        assertEquals(listOf(listOf("s4")), h.cancelled)
    }

    @Test
    fun ripAllowed_followsTheWindow_andIgnoresNonMembers() = runTest {
        val h = H(this, ids(30).toSet())
        h.start(*ids(30))
        assertTrue(h.seq.playbackRipAllowed("s10"))
        assertFalse(h.seq.playbackRipAllowed("s11"))
        assertTrue("a Browse single that is not a row is not this session's call", h.seq.playbackRipAllowed("elsewhere"))
    }

    @Test
    fun notePlaybackRipQueued_ignoresNonMembers() = runTest {
        val h = H(this, ids(5).toSet())
        h.start(*ids(5))
        h.seq.notePlaybackRipQueued("elsewhere")
        assertTrue(h.seq.trackedPlaybackRips.isEmpty())
        assertTrue(h.cancelled.isEmpty())
    }

    // ---- ANS-PB-5 (Q21): play during start does not reload ------------------------------------------------

    @Test
    fun playDuringStart_doesNotReload() = runTest {
        val h = H(this, setOf("a"))
        h.port.gates["a"] = kotlinx.coroutines.CompletableDeferred()
        h.start("a")
        assertEquals(listOf("a"), h.port.loadedIds)
        // Idle-play (remote/headset ▶) while a's start is still resolving/loading.
        assertTrue(h.seq.startCurrent())
        runCurrent()
        assertEquals("one load only", listOf("a"), h.port.loadedIds)
        h.port.gates["a"]!!.complete(Unit)
        runCurrent()
        assertEquals(listOf("a"), h.port.loadedIds)
        // Once audio is flowing the start is over: an explicit restart of the row reloads again.
        h.engine.playing = true
        h.seq.onFirstAudio("a", "player")
        assertTrue(h.seq.startCurrent())
        runCurrent()
        assertEquals(listOf("a", "a"), h.port.loadedIds)
    }

    @Test
    fun supervisorRetryInPlace_requestsAReResolve() = runTest {
        val h = H(this, setOf("a"))
        h.start("a")
        assertFalse(h.port.loads.last().reResolve)
        h.seq.supervisorRetryInPlace()
        runCurrent()
        assertEquals(2, h.port.loads.size)
        assertTrue(h.port.loads.last().reResolve)
    }
}

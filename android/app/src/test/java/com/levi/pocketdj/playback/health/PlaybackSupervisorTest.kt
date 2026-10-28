package com.levi.pocketdj.playback.health

import com.levi.pocketdj.playback.health.PlaybackSupervisor.Action
import com.levi.pocketdj.playback.health.PlaybackSupervisor.Core
import com.levi.pocketdj.playback.health.PlaybackSupervisor.Lane
import com.levi.pocketdj.playback.health.PlaybackSupervisor.Probe
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Core table tests ported against the iOS timings (L1 3 s, L2 +12 s <= 2/song, L3 +8 s, 60 s report). */
class PlaybackSupervisorTest {
    private val wants = Probe(lane = Lane.LOCAL, intentPlaying = true, songId = "song")
    private val silent = wants
    private val sound = wants.copy(audible = true)

    /** Drive [core] second by second with [probe] from `from` to `to` (inclusive), returning (second, action, lines). */
    private fun run(core: Core, probe: Probe, from: Int, to: Int): List<Triple<Int, Action?, List<String>>> =
        (from..to).map { s ->
            val st = core.step(probe, s * 1000L)
            Triple(s, st.action, st.lines)
        }

    private fun actions(r: List<Triple<Int, Action?, List<String>>>) = r.filter { it.second != null }.map { it.first to it.second }

    @Test
    fun silent_thenL1At3s_L2At15s_L3At23s() {
        val core = Core()
        val r = run(core, silent, 0, 30)
        assertEquals(
            listOf(3 to Action.REKICK, 15 to Action.RETRY_IN_PLACE, 23 to Action.ESCALATE),
            actions(r),
        )
        // the first silent tick logs the `silent` row, once
        assertTrue(r[0].third.single().startsWith("silent owner=PlayerEngine lane=local song=song since=0s startPending=0 ended=0"))
        assertEquals("step=L1 action=rekick song=song silent=3s", r[3].third.single())
        assertEquals("step=L2 action=retryInPlace song=song silent=15s retry=1", r[15].third.single())
        assertEquals("step=L3 action=escalate song=song silent=23s", r[23].third.single())
        assertEquals(3, core.stage)
    }

    @Test
    fun proofOfSound_resetsTheLadder_andLogsOk() {
        val core = Core()
        run(core, silent, 0, 4) // L1 fired at 3
        val ok = core.step(sound, 5_000)
        assertNull(ok.action)
        assertEquals(listOf("ok after=5s lane=local stage=L1"), ok.lines)
        assertEquals(0, core.stage)
        // silence again restarts from L0
        val r = run(core, silent, 6, 12)
        assertEquals(listOf(9 to Action.REKICK), actions(r))
    }

    @Test
    fun retriesPerSong_areCappedAtTwo_thenL2GoesStraightToL3() {
        val core = Core()
        var t = 0
        val seen = mutableListOf<Action>()
        val lines = mutableListOf<String>()
        // Three full silences on the same song, each broken by a moment of sound.
        repeat(3) {
            repeat(30) {
                val st = core.step(silent, t * 1000L)
                st.action?.let(seen::add)
                lines += st.lines
                t++
            }
            core.step(sound, t * 1000L); t++
        }
        assertEquals(
            listOf(
                Action.REKICK, Action.RETRY_IN_PLACE, Action.ESCALATE,
                Action.REKICK, Action.RETRY_IN_PLACE, Action.ESCALATE,
                Action.REKICK, Action.ESCALATE, // retries exhausted: L2 becomes L3 right away
            ),
            seen,
        )
        assertTrue(lines.any { it.endsWith("(retries exhausted)") })
    }

    @Test
    fun retryCounterIsPerSong() {
        val core = Core()
        var t = 0
        fun silenceOn(song: String) {
            repeat(24) { core.step(silent.copy(songId = song), (t++) * 1000L) }
            core.step(sound, (t++) * 1000L)
        }
        silenceOn("a"); silenceOn("a")
        val before = (0..23).map { core.step(silent.copy(songId = "b"), (t++) * 1000L).action }
        assertTrue("song b still has both retries", Action.RETRY_IN_PLACE in before)
    }

    @Test
    fun detectorOnly_whileAStartWindowIsOpen_countsDeadAirButNeverActs() {
        val core = Core()
        val r = run(core, silent.copy(startPending = true), 0, 60)
        assertTrue(actions(r).isEmpty())
        assertEquals(60.0, core.deadAirTotal, 1e-9)
        assertEquals("transition dead air is the share spent in a start window", 60.0, core.transitionDeadTotal, 1e-9)
        // the ladder clock starts only once the window closes
        val after = run(core, silent, 61, 70)
        assertEquals(listOf(64 to Action.REKICK), actions(after))
    }

    @Test
    fun detectorOnly_trackEnded_andAppleMusicLane() {
        for (p in listOf(silent.copy(trackEnded = true), silent.copy(lane = Lane.APPLE_MUSIC))) {
            val core = Core()
            assertTrue(actions(run(core, p, 0, 40)).isEmpty())
            assertEquals(40.0, core.deadAirTotal, 1e-9)
        }
    }

    @Test
    fun appleMusicLane_logsSilentWithTheAppleMusicOwner() {
        val core = Core()
        val line = core.step(silent.copy(lane = Lane.APPLE_MUSIC), 0).lines.single()
        assertTrue(line, line.startsWith("silent owner=AppleMusic lane=appleMusic"))
    }

    @Test
    fun neverActs_whenTheListenerDoesNotWantSound() {
        val cases = mapOf(
            "idle lane" to silent.copy(lane = Lane.IDLE),
            "no intent" to silent.copy(intentPlaying = false),
            "user paused" to silent.copy(userPaused = true),
            "interruption" to silent.copy(interruptionOpen = true),
            "held restore" to silent.copy(held = true),
        )
        for ((name, p) in cases) {
            val core = Core()
            val r = run(core, p, 0, 60)
            assertTrue(name, actions(r).isEmpty())
            assertEquals("$name must not even count as dead air", 0.0, core.deadAirTotal, 0.0)
            assertEquals(name, 0.0, core.activeTotal, 0.0)
        }
    }

    @Test
    fun cascadeHalted_holds_andLogsOnce() {
        val core = Core()
        val r = run(core, silent.copy(cascadeHalted = true), 0, 30)
        assertTrue(actions(r).isEmpty())
        val halted = r.flatMap { it.third }.filter { it.startsWith("halted") }
        assertEquals(listOf("halted lane=local song=song (cascade breaker) — holding"), halted)
        assertEquals(0.0, core.deadAirTotal, 0.0)
        // after the halt clears, the line can fire again
        core.step(sound, 31_000)
        val again = core.step(silent.copy(cascadeHalted = true), 32_000).lines
        assertEquals(1, again.count { it.startsWith("halted") })
    }

    @Test
    fun activeAndDead_accumulate_withTheTickGapCappedAt5s() {
        val core = Core()
        core.step(sound, 0)
        core.step(sound, 1_000)
        core.step(sound, 120_000) // a suspended process: one huge gap counts as 5 s, not 119
        assertEquals(6.0, core.activeTotal, 1e-9)
        assertEquals(0.0, core.deadAirTotal, 0.0)
    }

    @Test
    fun midSongDeadAir_isDeadMinusTransition() {
        val core = Core()
        run(core, silent.copy(startPending = true), 0, 4) // 4 s transition dead
        run(core, silent, 5, 8) // 4 s mid-song dead
        assertEquals(8.0, core.deadAirTotal, 1e-9)
        assertEquals(4.0, core.transitionDeadTotal, 1e-9)
    }

    @Test
    fun sixtySecondReport_logsTheRunningTotals_onlyWhenDeadAirWasSeen() {
        val core = Core()
        val quiet = run(core, sound, 0, 130)
        assertTrue(quiet.flatMap { it.third }.none { it.startsWith("dead-air total") })

        val core2 = Core()
        // 10 s of silence then sound; the first window report lands at t=60 with last60=10s.
        run(core2, silent.copy(startPending = true), 0, 10)
        val rest = run(core2, sound, 11, 130)
        val reports = rest.filter { r -> r.third.any { it.startsWith("dead-air total") } }
        assertEquals(1, reports.size)
        assertEquals(60, reports.single().first)
        assertEquals("dead-air total=10s last60=10s", reports.single().third.single { it.startsWith("dead-air") })
    }

    @Test
    fun customTimings_areHonoured() {
        val core = Core(PlaybackSupervisor.Config(l1Seconds = 1.0, l2Seconds = 2.0, l3Seconds = 3.0, maxRetriesPerSong = 0))
        val r = run(core, silent, 0, 10)
        assertEquals(listOf(1 to Action.REKICK, 3 to Action.ESCALATE), actions(r))
    }

    // ---- Shell ----------------------------------------------------------------------------------

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun shell_ticksOneHertzOnlyWhileStarted_andPerformsActions() = runTest {
        var probe = silent
        val performed = mutableListOf<Action>()
        val logs = mutableListOf<String>()
        val shell = PlaybackSupervisor.Shell(
            scope = backgroundScope,
            probe = { probe },
            perform = { performed += it },
            nowMs = { currentTime },
            log = { logs += it },
        )
        advanceTimeBy(10_000)
        assertTrue("not started: no ticks", logs.isEmpty())
        shell.start()
        shell.start() // idempotent
        advanceTimeBy(4_100)
        assertEquals(listOf(Action.REKICK), performed)
        shell.stopTicking()
        assertFalse(shell.isTicking)
        val n = logs.size
        advanceTimeBy(60_000)
        assertEquals("stopped: no ticks", n, logs.size)
    }

    @Test
    fun shell_feedsTheMeter_andAbandonsTheTransitionWhenTheListenerPaused() {
        run {
            val meterLogs = mutableListOf<String>()
            val meter = DeadAirMeter(file = null, log = { meterLogs += it }, nowMs = { 0L })
            var now = 0L
            var probe = silent.copy(startPending = true)
            val shell = PlaybackSupervisor.Shell(
                scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Job()),
                probe = { probe },
                perform = {},
                nowMs = { now },
                log = {},
                meter = meter,
            )
            meter.transitionBegan("advance", 0)
            meter.trackStarting("rip")
            shell.tick()
            now = 1_000; shell.tick()
            now = 2_000; shell.tick()
            val d = meter.day(0)
            assertEquals(2.0, d.activeSeconds, 1e-9)
            assertEquals(2.0, d.deadSeconds, 1e-9)
            assertEquals(2.0, d.transitionDeadSeconds, 1e-9)
            assertTrue(meter.hasOpenTransition)
            probe = probe.copy(userPaused = true)
            now = 3_000; shell.tick()
            assertFalse(meter.hasOpenTransition)
            assertTrue(meterLogs.any { it == "abandoned cause=advance from=none reason=paused" })
        }
    }
}

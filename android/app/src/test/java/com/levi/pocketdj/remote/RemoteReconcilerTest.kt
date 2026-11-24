package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.TransitionCause
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The speaker half over [LoopbackHub] (ports the reconcile / drift / pausedHere / hold cases of iOS
 * `RemoteSessionTests` and the review-round regressions: system pauses, duplicate advance, unavailable-row loops).
 * One shared fake clock drives every controller and every in-memory player.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RemoteReconcilerTest {
    private class Clk { var t = 1_000_000.0 }

    /** A player whose ▶/⏸ can be made to not take (a start that hasn't settled). */
    private class StickyPlay(val inner: InMemoryRemoteTarget) : RemotePlaybackTarget by inner {
        var ignorePlay = false
        val playCalls = ArrayList<Boolean>()
        override fun setPlaying(on: Boolean) { playCalls += on; if (!ignorePlay) inner.setPlaying(on) }
    }

    private inner class Dev(val id: String, val clk: Clk, scope: CoroutineScope, val hub: LoopbackHub) {
        val link by lazy { hub.join(id) }
        val mem = InMemoryRemoteTarget { clk.t }
        val target = StickyPlay(mem)
        val missing = HashSet<String>()
        val clock = SharedClock { clk.t }
        val controller = RemoteSessionController(
            target = target,
            resolver = RemoteSongResolver(catalogItem = { if (it in missing) null else QueueItem(id = it, lengthMs = 200_000) }),
            deviceName = { "Dev $id" }, platform = "test", clock = clock, scope = scope,
        )
        val rec = RemoteReconciler.bind(controller, target, clock)
        fun host(ids: List<String>, index: Int = 0, playing: Boolean = true, mode: RemoteSessionMode = RemoteSessionMode.LISTEN_TOGETHER) {
            controller.attach(
                link, mode, asHost = true, autoTick = false,
                seed = RemoteQueueModel(rows = ids.map(::row), index = index, isPlaying = playing, anchor = clk.t, revision = 1),
            )
        }
        fun guest(mode: RemoteSessionMode = RemoteSessionMode.LISTEN_TOGETHER) = controller.attach(link, mode, asHost = false, autoTick = false)
        fun kinds(k: RemoteMessageKind) = link.sent.filter { it.first.kind == k.wire }
        fun sentCommands() = kinds(RemoteMessageKind.COMMAND).mapNotNull { it.first.decode(RemoteCommandMessage.serializer())?.command }
        val log get() = mem.log
        val songs get() = (0 until mem.queueCount).map { mem.item(it).id }
        val curSong get() = if (mem.isRunning) mem.item(mem.currentIndex).id else null
        /** Make the clock agree with the host's (a synced speaker; the loopback needs no real ping). */
        fun sync() = clock.ingest(SharedClock.Sample(0.0, 1.0))
    }

    private class Rig(val scope: TestScope, withLatency: Boolean = false) {
        val clk = Clk()
        val hub = if (withLatency) LoopbackHub(scope.backgroundScope) else LoopbackHub()
    }

    private fun row(id: String) = RemoteRow("r-$id", SessionRow(songId = id, title = "T$id", artist = "A", lengthMs = 200_000))
    private fun TestScope.rig() = Rig(this)
    private fun Rig.dev(id: String) = Dev(id, clk, scope.backgroundScope, hub)
    private fun TestScope.settle() { repeat(4) { runCurrent() } }

    /** Advance the shared clock and tick every device once (a 0.5 s beat repeated). */
    private fun TestScope.advance(r: Rig, ms: Long, vararg devs: Dev) {
        var left = ms
        while (left > 0) {
            val step = minOf(500L, left)
            r.clk.t += step; left -= step
            for (d in devs) d.controller.tick()
            settle()
        }
    }

    // ---- mirroring ----

    @Test fun guestMirrorsTheSessionRowPositionAndTail() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3", "s4"), index = 1)
        r.clk.t += 10_000
        b.guest(); settle()
        assertEquals(listOf("s1", "s2", "s3", "s4"), b.songs)
        assertEquals("s2", b.curSong)
        assertTrue(b.mem.isPlaying)
        assertEquals(10_000L, b.mem.positionMs)
        assertEquals("the host mirrors its own seed too", "s2", a.curSong)
        assertEquals("the speaker's rids are the session's", "r-s2", b.controller.ridByUid[b.mem.item(1).uid])
    }

    @Test fun pausedSessionLoadsPausedAndNothingSounds() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2"), playing = false)
        b.guest(); settle()
        assertEquals("s1", b.curSong)
        assertFalse(b.mem.isPlaying)
        assertTrue("loaded paused, never played-then-paused", "play" !in b.log)
    }

    @Test fun tailEditsAreAppliedWithoutReplayingTheRow() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        val before = b.log.toList()
        a.controller.send(RemoteCommand.Append(listOf(row("s9"))))
        a.controller.send(RemoteCommand.Remove("r-s2"))
        settle()
        assertEquals(listOf("s1", "s3", "s9"), b.songs)
        assertEquals("s1", b.curSong)
        assertTrue("no restart: only tail edits", (b.log - before.toSet()).none { it.startsWith("play") || it.startsWith("jump") })
        assertTrue(b.mem.isPlaying)
    }

    @Test fun movingOntoARowAlreadyHeldIsAJumpWithTheStartCue() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        a.controller.send(RemoteCommand.JumpTo("r-s3")); settle()
        assertEquals("s3", b.curSong)
        assertTrue(b.log.last { it.startsWith("jump") || it.startsWith("play") }.startsWith("jump"))
        // A fresh set that shares nothing with the local queue is a fresh play.
        a.controller.send(RemoteCommand.Play(listOf(row("n1"), row("n2")), 1)); settle()
        assertEquals(listOf("n1", "n2"), b.songs)
        assertEquals("n2", b.curSong)
    }

    @Test fun repeatModeIsMirroredAndShuffleOnlyOnParticipants() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        a.controller.send(RemoteCommand.SetRepeat(RepeatMode.ALL)); settle()
        assertEquals(RepeatMode.ALL, b.mem.repeatMode)
        assertEquals(RepeatMode.ALL, a.mem.repeatMode)
        a.controller.send(RemoteCommand.SetShuffle(true)); settle()
        assertTrue("a participant mirrors the flag", b.mem.shuffleEnabled)
        assertFalse("the host's own set is never re-shuffled underneath it", a.mem.shuffleEnabled)
    }

    // ---- unavailable rows ----

    @Test fun anUnavailableRowIsSkippedReportedAndNeverLoopedBackOnto() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        b.missing += "s2"
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        assertEquals(listOf("s1", "s3"), b.songs)
        assertEquals(setOf("r-s2"), b.controller.localUnavailable.value)
        assertEquals(setOf("r-s2"), a.controller.unavailableByPeer.value["B"])
        a.controller.send(RemoteCommand.SkipNext); settle() // the session is on s2: B stands in with s3
        assertEquals("s3", b.curSong)
        assertTrue("B's availability is reported once, not per tick", b.kinds(RemoteMessageKind.AVAILABILITY).size == 1)
        advance(r, 3_000, a, b)
        assertEquals("s3", b.curSong)
        assertTrue("standing in for the unavailable row sends nothing", b.sentCommands().isEmpty())
    }

    @Test fun aRowTheLocalPlayerAutoSkippedIsTreatedAsUnavailableHere() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        b.mem.simulateAutoAdvance(TransitionCause.AUTO_SKIP) // s1 was dead here; the player hopped to s2
        advance(r, 1_000, a, b)
        assertEquals(setOf("r-s1"), b.controller.localUnavailable.value)
        assertTrue("never echoed", b.sentCommands().isEmpty())
        assertEquals("the session never moved", "s1", a.controller.model.currentRow?.songId)
        // Session restarts s1: B mirrors AROUND it, it does not loop back onto the dead row.
        a.controller.send(RemoteCommand.Seek(0)); advance(r, 1_000, a, b)
        assertEquals("s2", b.curSong)
        assertFalse("s1" == b.curSong)
    }

    // ---- local change diffing ----

    @Test fun listenersSkipBecomesACommandAndTheSessionFollows() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        b.mem.userSkipNext()
        advance(r, 500, a, b)
        assertEquals(listOf(RemoteCommand.Advanced("r-s1")), b.sentCommands())
        assertEquals("s2", a.controller.model.currentRow?.songId)
        assertEquals("s2", b.curSong)
        advance(r, 2_000, a, b)
        assertEquals("duplicate advance never re-sent", 1, b.sentCommands().size)
    }

    @Test fun naturalEndNearTheEndAdvancesForEveryoneExactlyOnce() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        advance(r, 196_000, a, b) // 4 s before the row's 200 s end
        b.mem.simulateAutoAdvance(TransitionCause.NATURAL_END)
        advance(r, 500, a, b)
        assertEquals(listOf(RemoteCommand.Advanced("r-s1")), b.sentCommands())
        assertEquals("s2", a.controller.model.currentRow?.songId)
        advance(r, 3_000, a, b)
        assertEquals(1, b.sentCommands().size)
        assertEquals("s2", b.curSong)
    }

    @Test fun aShorterLocalCopyThatEndedEarlyHoldsSilentUntilTheSessionMoves() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        advance(r, 60_000, a, b)
        b.mem.simulateAutoAdvance(TransitionCause.NATURAL_END) // far from the session row's end
        advance(r, 1_000, a, b)
        assertTrue("no advance sent for everyone", b.sentCommands().isEmpty())
        assertEquals("s1", a.controller.model.currentRow?.songId)
        assertFalse("held silent, not re-mirrored", b.mem.isPlaying)
        advance(r, 3_000, a, b)
        assertFalse(b.mem.isPlaying)
        a.controller.send(RemoteCommand.SkipNext); advance(r, 1_000, a, b)
        assertEquals("s2", b.curSong)
        assertTrue("the hold lifts when the session moves", b.mem.isPlaying)
    }

    @Test fun remoteTransitionsAreNeverEchoed() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        a.controller.send(RemoteCommand.SkipNext); advance(r, 2_000, a, b)
        assertTrue(b.sentCommands().isEmpty())
        assertTrue(a.sentCommands().isEmpty())
    }

    @Test fun aLocalEditHoldsReconcileUntilTheHostsNewerState() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        r.hub.drop = { _, from, _ -> from == "A" } // the host's answers are lost for now
        b.mem.userAppend(listOf(QueueItem(id = "mine")))
        advance(r, 500, b)
        assertTrue(b.sentCommands().any { it is RemoteCommand.Append })
        assertTrue("the user's row is not reverted underneath them", "mine" in b.songs)
        advance(r, 2_000, b)
        assertTrue("still held inside the 3 s window", "mine" in b.songs)
        r.hub.drop = null
        advance(r, 1_500, a, b)
        assertEquals(listOf("s1", "s2", "s3", "mine"), a.controller.model.rows.map { it.songId })
        assertEquals(listOf("s1", "s2", "s3", "mine"), b.songs)
    }

    @Test fun aLocalStopNeverPausesEveryone() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        b.mem.silenceForController() // the player stopped on its own (no listener intent)
        advance(r, 1_000, a, b)
        assertTrue(b.sentCommands().none { it is RemoteCommand.SetPlaying || it is RemoteCommand.PlayPause })
        assertTrue(a.controller.model.isPlaying)
        // The listener's own ⏸ does pause the session.
        b.mem.userSetPlaying(true); advance(r, 500, a, b)
        b.mem.userSetPlaying(false); advance(r, 500, a, b)
        assertEquals(RemoteCommand.SetPlaying(false), b.sentCommands().last())
        assertFalse(a.controller.model.isPlaying)
    }

    // ---- system pause ----

    @Test fun aSystemPauseSetsPausedHereAndIsNeverAutoResumed() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        b.mem.simulateSystemPause()
        advance(r, 6_000, a, b)
        assertTrue(b.controller.pausedHere.value)
        assertFalse("never resumed out of the phone speaker", b.mem.isPlaying)
        assertTrue("nothing is sent: the session plays on", b.sentCommands().isEmpty())
        assertTrue(a.controller.model.isPlaying)
        // The session moves on: the speaker follows SILENTLY (loads paused, no jump that would sound).
        a.controller.send(RemoteCommand.SkipNext); advance(r, 1_000, a, b)
        assertEquals("s2", b.curSong)
        assertFalse(b.mem.isPlaying)
        assertTrue(b.controller.pausedHere.value)
        assertTrue(b.sentCommands().isEmpty())
        // Rejoin resumes HERE at the session position, a local action.
        b.controller.rejoinHere(); settle()
        assertTrue(b.mem.isPlaying)
        assertFalse(b.controller.pausedHere.value)
        assertEquals(a.controller.model.position(r.clk.t), b.mem.positionMs)
        assertTrue(b.sentCommands().isEmpty())
    }

    @Test fun theListenersOwnPlayAfterASystemPauseResumesAtTheSessionPosition() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        advance(r, 4_000, a, b)
        b.mem.simulateSystemPause()
        advance(r, 20_000, a, b)
        assertTrue(b.controller.pausedHere.value)
        b.sync()
        b.mem.userSetPlaying(true) // the listener's ▶
        advance(r, 500, a, b)
        assertFalse(b.controller.pausedHere.value)
        assertTrue(b.mem.isPlaying)
        assertTrue("agrees with the session: no command", b.sentCommands().isEmpty())
        advance(r, 1_500, a, b) // two drift strikes bring it to the session position
        assertTrue("resumed in sync, not where it stopped",
            kotlin.math.abs(b.mem.positionMs - a.controller.model.position(r.clk.t)) < 1_000)
    }

    // ---- drift / seeks ----

    @Test fun plainDriftNeedsTwoStrikesThenCoolsDownFor5s() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        b.sync(); advance(r, 2_000, a, b)
        b.mem.userSeek(b.mem.positionMs + 1_200) // drifted 1.2 s ahead; sets position only (own landing)
        b.rec.local.expected = b.rec.local.observe() // the listener didn't scrub: absorb the move as drift
        val seeks0 = b.log.count { it == "seek" }
        advance(r, 500, a, b)
        assertEquals("one strike is not enough", seeks0, b.log.count { it == "seek" })
        advance(r, 500, a, b)
        assertEquals("second strike corrects", seeks0 + 1, b.log.count { it == "seek" })
        assertTrue(kotlin.math.abs(b.mem.positionMs - a.controller.model.position(r.clk.t)) < 100)
        b.mem.userSeek(b.mem.positionMs + 1_200); b.rec.local.expected = b.rec.local.observe()
        advance(r, 2_000, a, b)
        assertEquals("inside the 5 s cooldown", seeks0 + 1, b.log.count { it == "seek" })
        advance(r, 4_000, a, b)
        assertEquals("after the cooldown", seeks0 + 2, b.log.count { it == "seek" })
    }

    @Test fun driftBelowTheThresholdAndCoarseClockAreLeftAlone() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        b.sync(); advance(r, 2_000, a, b)
        b.mem.userSeek(a.controller.model.position(r.clk.t) + 600); b.rec.local.expected = b.rec.local.observe()
        advance(r, 3_000, a, b)
        assertEquals("under 750 ms", 0, b.log.count { it == "seek" })
        b.mem.userSeek(a.controller.model.position(r.clk.t) + 1_500)
        b.mem.hasCoarsePosition = true
        b.rec.local.expected = b.rec.local.observe()
        advance(r, 3_000, a, b)
        assertEquals("under the 2000 ms coarse threshold", 0, b.log.count { it == "seek" })
    }

    @Test fun unsyncedClockNeverCorrectsPlainDrift_sameAsIos() = runTest {
        // iOS reconcileLocal: `if synced { driftStrikes += 1 }` and the plain-drift fix needs `synced`; an unsynced speaker
        // only applies a NEW revision (a session seek) fresh off the wire.
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        advance(r, 2_000, a, b)
        b.clock.reset("someone-else", false) // the speaker's clock is not the session host's: unsynced for reconcile
        b.mem.userSeek(b.mem.positionMs + 1_500); b.rec.local.expected = b.rec.local.observe()
        val seeks0 = b.log.count { it == "seek" }
        advance(r, 6_000, a, b)
        assertEquals("no synced clock: plain drift is left alone", seeks0, b.log.count { it == "seek" })
    }

    @Test fun neverCorrectsDriftWhileBuffering() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        b.sync(); advance(r, 2_000, a, b)
        b.mem.userSeek(b.mem.positionMs + 5_000); b.rec.local.expected = b.rec.local.observe()
        b.mem.isTransitioning = true
        advance(r, 4_000, a, b)
        assertEquals(0, b.log.count { it == "seek" })
        b.mem.isTransitioning = false
        advance(r, 1_000, a, b)
        assertTrue(b.log.count { it == "seek" } >= 1)
    }

    @Test fun aSessionSeekWithANewRevisionIsAppliedAtOnce() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        b.sync(); advance(r, 3_000, a, b)
        a.controller.send(RemoteCommand.Seek(120_000)); settle()
        assertEquals("one tick, no strikes, no cooldown", 1, b.log.count { it == "seek" })
        assertTrue(kotlin.math.abs(b.mem.positionMs - 120_000) < 100)
        assertTrue("our own seek is not a user scrub", b.sentCommands().isEmpty())
        advance(r, 2_000, a, b)
        assertTrue(b.sentCommands().isEmpty())
    }

    @Test fun aListenerScrubOverThreeSecondsBecomesASeekCommand() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        advance(r, 1_000, a, b)
        b.mem.userSeek(90_000)
        advance(r, 500, a, b)
        val seeks = b.sentCommands().filterIsInstance<RemoteCommand.Seek>()
        assertEquals(1, seeks.size)
        assertTrue(kotlin.math.abs(seeks[0].ms - 90_000) < 600)
        assertTrue(kotlin.math.abs(a.controller.model.position(r.clk.t) - 90_000) < 1_500)
    }

    // ---- play / pause re-issue ----

    @Test fun aPlayThatDidNotTakeIsReissuedOnlyAfterTwoSeconds() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        b.target.ignorePlay = true
        b.target.playCalls.clear()
        a.controller.send(RemoteCommand.SetPlaying(false)); settle()
        b.mem.silenceForController() // the player really is paused locally, the session now says ▶ again
        a.controller.send(RemoteCommand.SetPlaying(true)); settle()
        assertEquals("first issue", listOf(true), b.target.playCalls.filter { it })
        advance(r, 1_000, a, b)
        assertEquals("not before 2 s", 1, b.target.playCalls.count { it })
        advance(r, 1_500, a, b)
        assertEquals("re-issued after 2 s", 2, b.target.playCalls.count { it })
        b.target.ignorePlay = false
        advance(r, 2_500, a, b)
        assertTrue(b.mem.isPlaying)
    }

    // ---- controller silence + roles ----

    @Test fun controllerSilenceIsReassertedEveryTickOnEveryRegisteredEngine() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.mem.play(listOf(QueueItem(id = "x1"), QueueItem(id = "x2")), 0, 0, false)
        var extra = 0
        a.controller.registerControllerSilencer { extra++ }
        a.host(listOf("s1", "s2"), mode = RemoteSessionMode.BACKSEAT)
        assertEquals(RemoteDeviceRole.CONTROLLER, a.controller.localRole.value)
        val e0 = extra
        a.mem.setPlaying(true) // something starts it again
        a.controller.tick()
        assertFalse(a.mem.isPlaying)
        assertEquals("the Mix-deck / DSP silencers run each tick", e0 + 1, extra)
        a.controller.tick()
        assertEquals(e0 + 2, extra)
        b.guest(mode = RemoteSessionMode.BACKSEAT); settle()
        assertEquals("s1", b.curSong)
        assertTrue("the controller's own player is never reconciled", a.songs.none { it == "s1" })
    }

    @Test fun flippingBackToSpeakerReMirrorsTheSessionFromScratch() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2", "s3")); b.guest(); settle()
        b.controller.setLocalRole(RemoteDeviceRole.CONTROLLER); settle()
        assertFalse(b.mem.isPlaying)
        a.controller.send(RemoteCommand.SkipNext); advance(r, 1_000, a, b)
        assertEquals("a controller is not reconciled", "s1", b.curSong)
        b.controller.setLocalRole(RemoteDeviceRole.SPEAKER); settle()
        assertEquals("s2", b.curSong)
        assertTrue(b.mem.isPlaying)
    }

    // ---- lifecycle ----

    @Test fun leavingKeepsTheLocalMusicAndClearsReconcilerState() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(listOf("s1", "s2")); b.guest(); settle()
        b.controller.leave(); settle()
        assertTrue("the music never dies with the session", b.mem.isPlaying)
        assertNull(b.rec.local.expected)
        assertTrue(b.rec.local.locallyFailed.isEmpty())
        assertFalse(b.controller.pausedHere.value)
    }

    @Test fun reconcilingUnderLatencyAndALostStateConverges() = runTest {
        val r = Rig(this, withLatency = true); r.hub.latency = { _, _ -> 0.2 }
        val a = r.dev("A"); val b = r.dev("B")
        var dropped = false
        r.hub.drop = { env, from, _ -> if (!dropped && from == "A" && env.kind == RemoteMessageKind.STATE.wire && b.controller.state.value == null) { dropped = true; true } else false }
        a.host(listOf("s1", "s2", "s3")); b.guest()
        advanceTimeBy(1_000); settle()
        // The joiner re-requests (heartbeat shows a revision it never got) and ends up in step.
        repeat(8) { r.clk.t += 2_000; a.controller.tick(); b.controller.tick(); advanceTimeBy(500); settle() }
        assertEquals(listOf("s1", "s2", "s3"), b.songs)
        assertEquals("s1", b.curSong)
    }
}

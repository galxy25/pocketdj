package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The host/session half of the controller over [LoopbackHub] (ports the election / hand-over / heartbeat / size-cap /
 * refill cases of iOS `RemoteSessionTests`). Time is a shared fake clock; controllers are ticked by hand.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RemoteSessionHostTest {
    private class Clock { var t = 1_000_000.0 }

    private inner class Dev(
        val id: String, val clk: Clock, scope: CoroutineScope, val hub: LoopbackHub,
        maxState: Int = LoopbackHub.DEFAULT_MAX_STATE_BYTES,
    ) {
        val link: LoopbackTransport = hub.join(id, maxState)
        val target = InMemoryRemoteTarget { clk.t }
        val controller = RemoteSessionController(
            target = target, resolver = RemoteSongResolver(catalogItem = { QueueItem(id = it) }),
            deviceName = "Dev $id", platform = "test", clock = SharedClock { clk.t }, scope = scope,
        )
        fun host(mode: RemoteSessionMode = RemoteSessionMode.LISTEN_TOGETHER, seed: RemoteQueueModel? = null) =
            controller.attach(link, mode, asHost = true, seed = seed, autoTick = false)
        fun guest(mode: RemoteSessionMode = RemoteSessionMode.LISTEN_TOGETHER) =
            controller.attach(link, mode, asHost = false, autoTick = false)
        fun kinds(kind: RemoteMessageKind) = link.sent.filter { it.first.kind == kind.wire }
        val rev get() = controller.state.value?.revision
        val currentSong get() = controller.state.value?.currentRow?.songId
    }

    private fun row(id: String, rid: String = "r-$id", pad: Int = 0) =
        RemoteRow(rid, SessionRow(songId = id, title = "T$id" + "x".repeat(pad), artist = "A" + "y".repeat(pad), lengthMs = 200_000))

    private fun seed(ids: List<String>, index: Int = 0, t: Double = 1_000_000.0) = RemoteQueueModel(
        rows = ids.map { row(it) }, index = index, isPlaying = true, anchor = t, revision = 1,
    )

    private class Rig(val scope: TestScope) {
        val clk = Clock()
        val hub = LoopbackHub()
    }

    private fun TestScope.rig() = Rig(this)
    private fun Rig.dev(id: String, maxState: Int = LoopbackHub.DEFAULT_MAX_STATE_BYTES) =
        Dev(id, clk, scope.backgroundScope, hub, maxState)

    private fun TestScope.settle() { repeat(4) { runCurrent() } }

    // ---- attach / host seeding ----

    @Test fun hostSeedsFromItsLocalPlayerAndJoinerReceivesTheState() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.target.play((1..3).map { QueueItem(id = "s$it") }, 1, 5_000, false)
        a.host()
        assertTrue(a.controller.isHost)
        assertEquals(listOf("s1", "s2", "s3"), a.controller.model.rows.map { it.songId })
        assertEquals(1, a.controller.model.index)
        assertEquals("rows keep the local uid as rid (no reload on the host)", a.target.item(0).uid, a.controller.model.rows[0].rid)
        b.guest(); settle()
        assertEquals("A", b.controller.hostId.value)
        assertFalse(b.controller.isHost)
        assertEquals("s2", b.currentSong)
        assertEquals(a.rev, b.rev)
        assertEquals(setOf("A", "B"), a.controller.roster.value)
        assertEquals("Dev B", a.controller.peers.first { !it.isLocal }.name)
        assertEquals(RemoteDeviceRole.SPEAKER, a.controller.localRole.value)
    }

    @Test fun participantCommandsConvergeAllDevicesOnTheSameRevision() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B"); val c = r.dev("C")
        a.host(seed = seed(listOf("s1", "s2", "s3"))); b.guest(); c.guest(); settle()
        b.controller.send(RemoteCommand.SkipNext)
        b.controller.send(RemoteCommand.Append(listOf(row("s5", "r-new"))))
        settle()
        for (d in listOf(a, b, c)) {
            assertEquals(a.controller.model.revision, d.rev)
            assertEquals("s2", d.currentSong)
            assertEquals("s5", d.controller.state.value?.rows?.last()?.songId)
        }
        // A hand-applied command from the host itself follows the same path.
        a.controller.send(RemoteCommand.SkipNext); settle()
        assertEquals("s3", c.currentSong)
        assertEquals(a.rev, c.rev)
    }

    @Test fun backseatHostIsAControllerAndKeepsItsLocalPlayerSilent() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.target.play((1..3).map { QueueItem(id = "s$it") }, 0, 0, false)
        assertTrue(a.target.isPlaying)
        a.host(RemoteSessionMode.BACKSEAT)
        assertEquals(RemoteDeviceRole.CONTROLLER, a.controller.localRole.value)
        assertFalse("the controller's own audio stops", a.target.isPlaying)
        assertEquals(3, a.controller.model.rows.size)
        b.guest(RemoteSessionMode.BACKSEAT); settle()
        assertEquals(RemoteDeviceRole.SPEAKER, b.controller.localRole.value)
        assertEquals(RemoteSessionMode.BACKSEAT, b.controller.mode.value)
        // Something starts the controller's player again: the next tick silences it.
        a.target.setPlaying(true)
        assertTrue(a.target.isPlaying)
        a.controller.tick()
        assertFalse(a.target.isPlaying)
        assertEquals(RemoteDeviceRole.SPEAKER, a.controller.peers.first { !it.isLocal }.role)
        // The passenger flips to controller: the hello reaches the host.
        b.controller.setLocalRole(RemoteDeviceRole.CONTROLLER); settle()
        assertEquals(RemoteDeviceRole.CONTROLLER, a.controller.peers.first { !it.isLocal }.role)
    }

    // ---- hand-over ----

    @Test fun hostLeaveHandsOverToTheLowestRemainingIdFromTheLastState() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B"); val c = r.dev("C")
        a.target.play((1..4).map { QueueItem(id = "s$it") }, 1, 0, false)
        a.host(); b.guest(); c.guest(); settle()
        val revBefore = a.controller.model.revision
        a.controller.leave(); settle()
        assertFalse(a.controller.isActive.value)
        assertTrue("leaving keeps this device's music playing", a.target.isPlaying)
        assertTrue(b.controller.isHost)
        assertEquals("B", c.controller.hostId.value)
        assertEquals(listOf("s1", "s2", "s3", "s4"), b.controller.model.rows.map { it.songId })
        assertEquals("s2", b.controller.model.currentRow?.songId)
        assertTrue("the new host's revision moves forward", b.controller.model.revision > revBefore)
        assertEquals("B", c.controller.state.value?.hostId)
        c.controller.send(RemoteCommand.SkipNext); settle()
        assertEquals("s3", b.currentSong); assertEquals("s3", c.currentSong)
        assertEquals(b.rev, c.rev)
    }

    @Test fun emptySelfElectedHostNeverWipesTheRealHost() = runTest {
        val r = rig(); val real = r.dev("H"); val empty = r.dev("E")
        real.host(seed = seed(listOf("s1", "s2", "s3")))
        empty.controller.attach(empty.link, RemoteSessionMode.LISTEN_TOGETHER, asHost = true, seed = RemoteQueueModel(), autoTick = false)
        settle()
        assertTrue("the real host never yields to an empty one", real.controller.isHost)
        assertEquals(listOf("s1", "s2", "s3"), real.controller.model.rows.map { it.songId })
        assertEquals("H", empty.controller.hostId.value)
        assertFalse(empty.controller.isHost)
        assertEquals("s1", empty.currentSong)
    }

    @Test fun emptyHostAppearingAfterTheRealHostLeftIsTakenOverWithTheSet() = runTest {
        val r = rig(); val a = r.dev("A"); val c = r.dev("C")
        a.host(seed = seed(listOf("s1", "s2")))
        c.guest(); settle()
        assertEquals("s1", c.currentSong)
        // A real session state from a stranger that is EMPTY while the followed host still lives: ignored.
        val ghost = RemoteQueueModel().state("Z", RemoteSessionMode.LISTEN_TOGETHER, "x", r.clk.t, sessionActive = false)
        c.link.inject(RemoteEnvelope.make(RemoteMessageKind.STATE, RemotePlaybackState.serializer(), ghost), "Z")
        settle()
        assertEquals("A", c.controller.hostId.value)
        assertEquals(2, c.controller.state.value?.rows?.size)
        // The followed host is gone from the roster: the empty one's state makes C host the set it holds.
        a.controller.leave(); settle()
        assertTrue(c.controller.isHost)
        assertEquals(listOf("s1", "s2"), c.controller.model.rows.map { it.songId })
    }

    @Test fun noSelfElectionWhileOthersArePresentButAloneHostsItself() = runTest {
        val r = rig(); val b = r.dev("B")
        r.hub.join("A") // a peer that hasn't spoken yet
        b.guest(); settle()
        assertEquals(setOf("A", "B"), b.controller.roster.value)
        val hellos0 = b.kinds(RemoteMessageKind.HELLO).size
        r.clk.t += RemoteTuning.ELECTION_TIMEOUT_MS + 100
        b.controller.tick()
        assertFalse(b.controller.isHost)
        assertTrue("re-hello so a live host answers", b.kinds(RemoteMessageKind.HELLO).size > hellos0)
        // Right after, no second hello; one more timeout later there is.
        val hellos1 = b.kinds(RemoteMessageKind.HELLO).size
        b.controller.tick()
        assertEquals(hellos1, b.kinds(RemoteMessageKind.HELLO).size)

        val r2 = rig(); val solo = r2.dev("C")
        solo.guest(); settle()
        assertEquals(setOf("C"), solo.controller.roster.value)
        r2.clk.t += RemoteTuning.ELECTION_TIMEOUT_MS + 100
        solo.controller.tick()
        assertTrue("alone: nobody to wait for", solo.controller.isHost)
        solo.controller.leave()
    }

    // ---- state / heartbeat / requests ----

    @Test fun heartbeatIsSmallEveryTwoSecondsAndNeverResendsAnUnchangedState() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(seed = seed(listOf("s1", "s2", "s3"))); b.guest(); settle()
        val states0 = a.kinds(RemoteMessageKind.STATE).size
        repeat(5) { r.clk.t += 2_000; a.controller.tick() }
        assertEquals(states0, a.kinds(RemoteMessageKind.STATE).size)
        val beats = a.kinds(RemoteMessageKind.HEARTBEAT)
        assertEquals(5, beats.size)
        assertTrue(RemoteElection.encodedSize(beats.first().first) < 600)
        // Ticks inside the 2 s window send nothing.
        r.clk.t += 500; a.controller.tick()
        assertEquals(5, a.kinds(RemoteMessageKind.HEARTBEAT).size)
        settle()
        assertTrue(b.kinds(RemoteMessageKind.STATE_REQUEST).isEmpty())
        // The heartbeat re-anchors the joiner's position without a full state.
        assertEquals(1, b.controller.lastRevision)
        assertEquals(r.clk.t - 500, b.controller.state.value!!.anchorSharedTime, 0.001)
    }

    @Test fun aMissedRevisionIsRequestedAndAnsweredWithTheFullState() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(seed = seed(listOf("s1", "s2", "s3"))); b.guest(); settle()
        val states0 = a.kinds(RemoteMessageKind.STATE).size
        val hb = RemoteHeartbeat(revision = a.controller.model.revision + 5, hostId = "A", currentRid = "r-s1", positionMs = 0,
            isPlaying = true, anchorSharedTime = r.clk.t, sessionActive = true)
        b.link.inject(RemoteEnvelope.make(RemoteMessageKind.HEARTBEAT, RemoteHeartbeat.serializer(), hb), "A")
        settle()
        assertEquals(1, b.kinds(RemoteMessageKind.STATE_REQUEST).size)
        assertEquals(states0 + 1, a.kinds(RemoteMessageKind.STATE).size)
        val req = b.kinds(RemoteMessageKind.STATE_REQUEST).first().first.decode(RemoteStateRequest.serializer())!!
        assertEquals(1, req.haveRevision)
    }

    @Test fun unansweredStateRequestIsRetriedWithBackoff() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(seed = seed(listOf("s1", "s2"))); b.guest(); settle()
        r.hub.drop = { env, from, _ -> from == "B" && env.kind == RemoteMessageKind.STATE_REQUEST.wire }
        val rev = a.controller.model.revision + 3
        val times = ArrayList<Double>()
        val t0 = r.clk.t
        repeat(16) {
            val n = b.kinds(RemoteMessageKind.STATE_REQUEST).size
            val hb = RemoteHeartbeat(rev, "A", "r-s1", 0, true, r.clk.t, true)
            b.link.inject(RemoteEnvelope.make(RemoteMessageKind.HEARTBEAT, RemoteHeartbeat.serializer(), hb), "A")
            settle()
            if (b.kinds(RemoteMessageKind.STATE_REQUEST).size > n) times += r.clk.t - t0
            r.clk.t += 1_000
        }
        assertEquals(listOf(0.0, 2_000.0, 6_000.0, 14_000.0), times)
    }

    @Test fun staleStatesAreIgnoredAndOnlyANewerRevisionIsStructural() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        var structural = 0
        b.controller.speaker = object : RemoteSpeakerHooks { override fun onStructuralState() { structural++ } }
        a.host(seed = seed(listOf("s1", "s2", "s3"))); b.guest(); settle()
        assertEquals(1, structural)
        val old = a.controller.state.value!!
        a.controller.send(RemoteCommand.SkipNext); settle()
        assertEquals(2, structural)
        assertEquals(2, b.rev)
        // Re-delivery of the older revision changes nothing; the same revision again is not structural.
        b.link.inject(RemoteEnvelope.make(RemoteMessageKind.STATE, RemotePlaybackState.serializer(), old), "A"); settle()
        assertEquals(2, b.rev); assertEquals("s2", b.currentSong)
        b.link.inject(RemoteEnvelope.make(RemoteMessageKind.STATE, RemotePlaybackState.serializer(), a.controller.state.value!!), "A"); settle()
        assertEquals(2, structural)
        // A state claiming to be from a host other than its sender is dropped.
        b.link.inject(RemoteEnvelope.make(RemoteMessageKind.STATE, RemotePlaybackState.serializer(), old.copy(revision = 99)), "X"); settle()
        assertEquals(2, b.rev)
    }

    @Test fun encodedStateIsCappedByTrimmingTheWindow() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        val long = "x".repeat(600)
        val m = RemoteQueueModel(
            rows = (0 until 300).map { i -> RemoteRow("r$i", SessionRow(songId = "s1", title = long, artist = long, lengthMs = 200_000)) },
            index = 5, isPlaying = true, anchor = r.clk.t, revision = 1,
        )
        a.host(seed = m); b.guest(); settle()
        val sent = a.kinds(RemoteMessageKind.STATE)
        assertTrue(sent.isNotEmpty())
        for ((env, _) in sent) assertTrue(RemoteElection.encodedSize(env) <= RemoteTuning.MAX_STATE_BYTES)
        val got = b.controller.state.value!!
        assertEquals("the current row always rides", "r5", got.currentRow?.rid)
        assertTrue(got.rows.size < 221)
        assertEquals(300, got.totalCount)
        assertEquals("the host's own view keeps the full window", 206, a.controller.state.value?.rows?.size)
    }

    @Test fun aTransportWithASmallerBudgetCapsTheWireStateFurther() = runTest {
        val r = rig(); val a = r.dev("A", maxState = 12_000); val b = r.dev("B")
        val m = RemoteQueueModel(
            rows = (0 until 300).map { row("s$it", pad = 100) }, index = 0, isPlaying = true, anchor = r.clk.t, revision = 1,
        )
        a.host(seed = m); b.guest(); settle()
        for ((env, _) in a.kinds(RemoteMessageKind.STATE)) assertTrue(RemoteElection.encodedSize(env) <= 12_000)
        assertTrue(b.controller.state.value!!.rows.size < 201)
    }

    // ---- host duties ----

    @Test fun hostKeepsAndRefillsFromItsLocalQueue() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        val ids = (0 until 300).map { "x$it" }
        a.target.play(ids.map { QueueItem(id = it) }, 0, 0, false)
        a.host(); b.guest(); settle()
        assertEquals(201, a.controller.model.rows.size)
        repeat(3) { r.clk.t += 500; a.controller.tick() }
        assertEquals("the host's local set is never truncated", 300, a.target.queueCount)
        // Jump deep into the window: the tail runs low and is refilled from the local set.
        a.controller.send(RemoteCommand.JumpTo(a.controller.model.rows[150].rid))
        a.controller.tick(); settle()
        assertEquals(300, a.controller.model.rows.size)
        assertEquals("x299", a.controller.model.rows.last().songId)
        assertEquals("x150", b.currentSong)
        assertEquals("x299", b.controller.state.value?.rows?.last()?.songId)
    }

    @Test fun hostAdvancesByItselfWhenNoSpeakerReportsTheTrackEnd() = runTest {
        val r = rig(); val a = r.dev("A")
        a.host(seed = seed(listOf("s1", "s2")))
        r.clk.t += 200_000 + RemoteTuning.HOST_ADVANCE_SLACK_MS - 1_000
        a.controller.tick()
        assertEquals("s1", a.controller.model.currentRow?.songId)
        r.clk.t += 2_000
        a.controller.tick()
        assertEquals("s2", a.controller.model.currentRow?.songId)
    }

    @Test fun pingsAreAnsweredByTheHostAndSyncAParticipantsClock() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(seed = seed(listOf("s1"))); b.guest(); settle()
        assertFalse(b.controller.clock.isSynced)
        b.controller.tick(); settle()
        assertTrue(b.kinds(RemoteMessageKind.PING).isNotEmpty())
        assertEquals(1, a.kinds(RemoteMessageKind.PONG).size)
        assertTrue(b.controller.clock.isSynced)
    }

    // ---- lifecycle / extension points ----

    @Test fun leaveEndsTheSessionAndTheProbeFollowsIt() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        val seen = ArrayList<Boolean>()
        a.controller.registerSessionObserver { seen += it }
        assertFalse(a.controller.isActive.value)
        a.host(seed = seed(listOf("s1"))); b.guest(); settle()
        assertTrue(a.controller.isActive.value)
        a.controller.leave()
        assertFalse(a.controller.isActive.value)
        assertNull(a.controller.hostId.value)
        assertNull(a.controller.state.value)
        assertTrue(a.controller.roster.value.isEmpty())
        assertEquals(listOf(true, false), seen)
        // The session ending under a participant (everyone gone) ends it too, without a leave.
        r.hub.end(); settle()
        assertFalse(b.controller.isActive.value)
    }

    @Test fun reattachingLeavesTheOldSessionFirst() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(seed = seed(listOf("s1"))); b.guest(); settle()
        val hub2 = LoopbackHub()
        val t2 = hub2.join("A")
        a.controller.attach(t2, RemoteSessionMode.BACKSEAT, asHost = true, seed = seed(listOf("n1")), autoTick = false)
        settle()
        assertEquals(RemoteSessionMode.BACKSEAT, a.controller.mode.value)
        assertEquals(listOf("n1"), a.controller.model.rows.map { it.songId })
        assertEquals(setOf("A"), a.controller.roster.value)
        assertTrue("the first session lost A", "A" !in r.hub.participantIds)
    }

    @Test fun unknownKindsNewerEnvelopesAndGarbageAreIgnoredButExtensionsGetTheirKinds() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(seed = seed(listOf("s1", "s2"))); b.guest(); settle()
        val got = ArrayList<Pair<String, String>>()
        a.controller.registerHandler("mix.event") { env, from -> got += env.kind to from }
        val rev = a.controller.model.revision
        a.link.inject(RemoteEnvelope(1, "mix.event", "e30="), "B")
        a.link.inject(RemoteEnvelope(1, "totally.new", "e30="), "B")
        a.link.inject(RemoteEnvelope(7, RemoteMessageKind.COMMAND.wire, "e30="), "B")
        a.link.inject(RemoteEnvelope(1, RemoteMessageKind.COMMAND.wire, "%%%not-base64"), "B")
        settle()
        assertEquals(listOf("mix.event" to "B"), got)
        assertEquals(rev, a.controller.model.revision)
        assertTrue(a.controller.isHost)
    }

    @Test fun activityProbeCountsAnEmptyHostAsActiveInTheElection() = runTest {
        val r = rig(); val a = r.dev("A")
        a.host(seed = RemoteQueueModel())
        assertFalse(a.controller.hostIsActive)
        a.controller.registerActivityProbe { true }
        assertTrue(a.controller.hostIsActive)
        assertEquals(true, a.controller.state.value?.let { true })
    }

    @Test fun controllerGateForwardsLocalTransportToTheSessionOnlyWhenAController() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        a.host(RemoteSessionMode.BACKSEAT, seed(listOf("s1", "s2", "s3"))); b.guest(RemoteSessionMode.BACKSEAT); settle()
        assertTrue(a.controller.interceptLocalTransport(RemoteRedirect.Next)); settle()
        assertEquals("s2", b.currentSong)
        assertTrue(a.controller.interceptLocalTransport(RemoteRedirect.Pause)); settle()
        assertFalse(b.controller.state.value!!.isPlaying)
        assertTrue(a.controller.interceptLocalTransport(RemoteRedirect.Seek(42_000))); settle()
        assertEquals(42_000L, b.controller.state.value!!.snapshot.positionMs)
        // A brand-new set started on the controller becomes the session's set (windowed like a broadcast).
        val items = (0 until 500).map { QueueItem(id = "n$it") }
        assertTrue(a.controller.interceptLocalTransport(RemoteRedirect.PlayItems(items, 250))); settle()
        assertEquals("n250", b.currentSong)
        assertEquals(RemoteQueueModel.WINDOW_BEHIND + 1 + RemoteQueueModel.WINDOW_AHEAD, a.controller.model.rows.size)
        // PlayNow on a live session splices after the current row.
        assertTrue(a.controller.interceptLocalTransport(RemoteRedirect.PlayNow(QueueItem(id = "now")))); settle()
        assertEquals("now", b.currentSong)
        // A speaker handles its own transport.
        assertFalse(b.controller.interceptLocalTransport(RemoteRedirect.Next))
        a.controller.setLocalRole(RemoteDeviceRole.SPEAKER)
        assertFalse(a.controller.interceptLocalTransport(RemoteRedirect.Next))
    }

    @Test fun controllerSilencersRunOnBecomingAControllerAndEveryTick() = runTest {
        val r = rig(); val a = r.dev("A")
        var silenced = 0
        a.controller.registerControllerSilencer { silenced++ }
        a.host(RemoteSessionMode.BACKSEAT, seed(listOf("s1")))
        assertEquals(1, silenced)
        a.controller.tick(); a.controller.tick()
        assertEquals(3, silenced)
        a.controller.setLocalRole(RemoteDeviceRole.SPEAKER)
        a.controller.tick()
        assertEquals(3, silenced)
    }

    @Test fun shareInviteDismissWithdrawsThePendingStart() = runTest {
        val r = rig(); val a = r.dev("A")
        a.controller.pendingStartMode = RemoteSessionMode.BACKSEAT
        a.controller.shareInviteEnded(succeeded = true)
        assertEquals(RemoteSessionMode.BACKSEAT, a.controller.pendingStartMode)
        a.controller.shareInviteEnded(succeeded = false)
        assertNull(a.controller.pendingStartMode)
    }

    @Test fun helloCarriesNamePlatformRoleAndCaps() = runTest {
        val r = rig(); val a = r.dev("A"); val b = r.dev("B")
        b.controller.localCaps = listOf("mix")
        a.host(seed = seed(listOf("s1"))); b.guest(); settle()
        val hello = b.kinds(RemoteMessageKind.HELLO).first().first.decode(RemoteHello.serializer())
        assertNotNull(hello)
        assertEquals("Dev B", hello!!.name)
        assertEquals("test", hello.platform)
        assertEquals(listOf("mix"), hello.caps)
        assertEquals(listOf("mix"), a.controller.peerInfo.value["B"]?.caps)
        assertEquals(RemoteDeviceRole.SPEAKER, hello.role)
    }
}

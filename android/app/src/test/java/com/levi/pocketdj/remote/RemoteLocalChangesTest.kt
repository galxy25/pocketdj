package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.TransitionCause
import com.levi.pocketdj.shell.ShellActionException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [RemoteLocalChanges] (cause-tagged diffing of the listener's own actions into commands) and the Auto-DJ suspension
 * seam. The diff is exercised directly over hand-built [LocalObservation]s, so each rule is isolated.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RemoteLocalChangesTest {
    @After fun clearBlock() { MixTogetherBlock.set(null); MixTogetherBlock.onChanged = null }

    private var t = 1_000_000.0
    private fun row(id: String) = RemoteRow("r-$id", SessionRow(songId = id, title = "T$id", artist = "A", lengthMs = 200_000))

    private class Env(val controller: RemoteSessionController, val target: InMemoryRemoteTarget, val local: RemoteLocalChanges, val clock: SharedClock)

    /** A hosting controller over an in-memory player, with rids == the session rows' ids. */
    private fun TestScope.env(ids: List<String> = listOf("s1", "s2", "s3", "s4"), index: Int = 0): Env {
        val clock = SharedClock { t }
        val target = InMemoryRemoteTarget { t }
        val controller = RemoteSessionController(
            target = target, resolver = RemoteSongResolver(catalogItem = { QueueItem(id = it) }),
            deviceName = { "me" }, platform = "test", clock = clock, scope = backgroundScope,
        )
        val hub = LoopbackHub()
        controller.attach(
            hub.join("A"), RemoteSessionMode.LISTEN_TOGETHER, asHost = true, autoTick = false,
            seed = RemoteQueueModel(rows = ids.map(::row), index = index, isPlaying = true, anchor = t, revision = 1),
        )
        runCurrent()
        val local = RemoteLocalChanges(controller, target, clock, { t })
        return Env(controller, target, local, clock)
    }

    private fun obs(
        cur: String? = "u1", upcoming: List<String> = listOf("u2", "u3"), playing: Boolean = true, pos: Long = 10_000,
        at: Double = t, gen: Long = 0, running: Boolean = true, shuffle: Boolean = false, repeat: RepeatMode = RepeatMode.OFF,
        tSeq: Long = 0, uSeq: Long = 0, cause: TransitionCause = TransitionCause.USER, iSeq: Long = 0, intent: Boolean = true,
    ) = LocalObservation(running, gen, cur, upcoming, playing, pos, at, repeat, shuffle, tSeq, uSeq, cause, iSeq, intent)

    /** Map local uids u1.. onto the session's rids r-s1.. . */
    private fun Env.map(vararg pairs: Pair<String, String>) { for ((u, r) in pairs) controller.ridByUid[u] = r }
    private fun Env.mapDefault() = map("u1" to "r-s1", "u2" to "r-s2", "u3" to "r-s3", "u4" to "r-s4")

    // ---- USER ----

    @Test fun userSkipToTheNextRowIsAdvancedFromTheLeftRow() = runTest {
        val e = env(); e.mapDefault()
        val exp = obs(cur = "u1", upcoming = listOf("u2", "u3", "u4"))
        val ob = obs(cur = "u2", upcoming = listOf("u3", "u4"), tSeq = 1, uSeq = 1, pos = 0)
        assertEquals(listOf(RemoteCommand.Advanced("r-s1")), e.local.diff(exp, ob))
    }

    @Test fun userJumpAwayFromTheNextRowIsJumpToAndARestartIsASeek() = runTest {
        val e = env(); e.mapDefault()
        val exp = obs(cur = "u1", upcoming = listOf("u2", "u3", "u4"))
        assertEquals(
            listOf<RemoteCommand>(RemoteCommand.JumpTo("r-s3")),
            e.local.diff(exp, obs(cur = "u3", upcoming = listOf("u4"), tSeq = 1, uSeq = 1)),
        )
        assertEquals(
            listOf<RemoteCommand>(RemoteCommand.Seek(0)),
            e.local.diff(exp, obs(cur = "u1", upcoming = listOf("u2", "u3", "u4"), tSeq = 1, uSeq = 1, pos = 0)),
        )
    }

    @Test fun aBrandNewSetStartedHereBecomesTheSessionsSetWindowedAroundTheCurrentRow() = runTest {
        val e = env(); e.mapDefault()
        e.target.userPlay((1..60).map { QueueItem(id = "n$it") })
        val exp = obs(cur = "u1", upcoming = listOf("u2"))
        val ob = obs(cur = e.target.item(0).uid, upcoming = emptyList(), tSeq = 1, uSeq = 1)
        val cmds = e.local.diff(exp, ob)
        val play = cmds.single() as RemoteCommand.Play
        assertEquals(0, play.startIndex)
        assertEquals(1 + RemoteQueueModel.WINDOW_AHEAD, play.rows.size)
        assertEquals("the rows carry the local uid as rid", e.target.item(0).uid, play.rows[0].rid)
        assertEquals(e.target.item(0).uid, e.controller.ridByUid[e.target.item(0).uid])
    }

    // ---- automatic causes ----

    @Test fun naturalEndWithinTenSecondsOfTheRowsEndIsAdvanced() = runTest {
        val e = env(); e.mapDefault()
        t += 195_000 // 5 s before the end
        val exp = obs(cur = "u1"); val ob = obs(cur = "u2", tSeq = 1, cause = TransitionCause.NATURAL_END)
        assertEquals(listOf<RemoteCommand>(RemoteCommand.Advanced("r-s1")), e.local.diff(exp, ob))
        assertNull(e.local.heldAfterEnd)
    }

    @Test fun naturalEndFarFromTheEndHoldsSilentAndSendsNothing() = runTest {
        val e = env(); e.mapDefault()
        t += 60_000
        val cmds = e.local.diff(obs(cur = "u1"), obs(cur = "u2", tSeq = 1, cause = TransitionCause.NATURAL_END))
        assertTrue(cmds.isEmpty())
        val h = e.local.heldAfterEnd
        assertNotNull(h)
        assertEquals("r-s1", h!!.rid); assertEquals("r-s1", h.sessionRid)
    }

    @Test fun naturalEndOfARowThatIsNotTheSessionsCurrentOneIsHeldNotAdvanced() = runTest {
        val e = env(); e.mapDefault()
        e.controller.send(RemoteCommand.SkipNext) // the session is already on s2
        val cmds = e.local.diff(obs(cur = "u1"), obs(cur = "u2", tSeq = 1, cause = TransitionCause.NATURAL_END))
        assertTrue("never a duplicate advance of a row the session left", cmds.isEmpty())
        assertEquals("r-s2", e.local.heldAfterEnd?.sessionRid)
    }

    @Test fun autoSkipStallHopAndUnplayableMarkTheRowUnavailableHereWithoutACommand() = runTest {
        for ((i, cause) in listOf(TransitionCause.AUTO_SKIP, TransitionCause.STALL_HOP, TransitionCause.UNPLAYABLE).withIndex()) {
            val e = env(); e.mapDefault()
            val cmds = e.local.diff(obs(cur = "u1"), obs(cur = "u2", tSeq = 1, cause = cause))
            assertTrue("$cause", cmds.isEmpty())
            assertEquals("$cause", setOf("r-s1"), e.local.locallyFailed.toSet())
            assertTrue(i >= 0)
        }
    }

    @Test fun remoteTransitionsAreNeverEchoed() = runTest {
        val e = env(); e.mapDefault()
        assertTrue(e.local.diff(obs(cur = "u1"), obs(cur = "u2", tSeq = 1, cause = TransitionCause.REMOTE)).isEmpty())
        assertTrue(e.local.locallyFailed.isEmpty())
        assertNull(e.local.heldAfterEnd)
    }

    // ---- scrubs ----

    @Test fun aPositionJumpOverThreeSecondsIsAScrubButNormalPlaybackIsNot() = runTest {
        val e = env(); e.mapDefault()
        val exp = obs(pos = 10_000, at = t)
        assertTrue("playing along", e.local.diff(exp, obs(pos = 10_500, at = t + 500)).isEmpty())
        assertTrue("just under 3 s of surprise", e.local.diff(exp, obs(pos = 13_400, at = t + 500)).isEmpty())
        assertEquals(listOf<RemoteCommand>(RemoteCommand.Seek(40_000)), e.local.diff(exp, obs(pos = 40_000, at = t + 500)))
    }

    @Test fun ourOwnSeeksLateLandingIsNotAScrubAndABufferingPlayerIsIgnored() = runTest {
        val e = env(); e.mapDefault()
        e.local.pendingSeekMs = 90_000
        val exp = obs(pos = 10_000)
        assertTrue(e.local.diff(exp, obs(pos = 90_800, at = t + 500)).isEmpty())
        assertNull("consumed", e.local.pendingSeekMs)
        e.target.isTransitioning = true
        assertTrue("a start in flight reads garbage positions", e.local.diff(exp, obs(pos = 90_000, at = t + 500)).isEmpty())
    }

    @Test fun aPausedPlayerPredictsNoMotion() = runTest {
        val e = env(); e.mapDefault()
        val exp = obs(pos = 10_000, playing = false)
        assertTrue(e.local.diff(exp, obs(pos = 10_000, playing = false, at = t + 60_000)).isEmpty())
        assertEquals(1, e.local.diff(exp, obs(pos = 20_000, playing = false, at = t + 500)).size)
    }

    // ---- play intent / repeat / shuffle ----

    @Test fun onlyAListenersPlayIntentThatDisagreesWithTheSessionBecomesACommand() = runTest {
        val e = env(); e.mapDefault() // the session is playing
        val exp = obs()
        assertTrue("a stop with no intent bump never pauses everyone", e.local.diff(exp, obs(playing = false)).isEmpty())
        assertTrue("intent that agrees with the session", e.local.diff(exp, obs(iSeq = 1, intent = true)).isEmpty())
        assertEquals(listOf<RemoteCommand>(RemoteCommand.SetPlaying(false)), e.local.diff(exp, obs(playing = false, iSeq = 1, intent = false)))
    }

    @Test fun repeatAndShuffleChangesMirrorToTheSession() = runTest {
        val e = env(); e.mapDefault()
        val exp = obs()
        assertEquals(listOf<RemoteCommand>(RemoteCommand.SetRepeat(RepeatMode.ALL)), e.local.diff(exp, obs(repeat = RepeatMode.ALL)))
        assertEquals(listOf<RemoteCommand>(RemoteCommand.SetShuffle(true)), e.local.diff(exp, obs(shuffle = true)))
    }

    // ---- queue edits ----

    private fun items(vararg ids: String) = ids.map { QueueItem(id = it.removePrefix("u"), uid = it) }

    @Test fun queueEditsRemoveReorderAndAppend() = runTest {
        val e = env(); e.mapDefault()
        val exp = obs(upcoming = listOf("u2", "u3", "u4"), gen = 0)
        // u3 removed
        assertEquals(
            listOf<RemoteCommand>(RemoteCommand.Remove("r-s3")),
            e.local.queueEditCommands(exp, obs(upcoming = listOf("u2", "u4"), gen = 1), items("u2", "u4")),
        )
        // re-ordered
        assertEquals(
            listOf<RemoteCommand>(RemoteCommand.Reorder(listOf("r-s4", "r-s2", "r-s3"))),
            e.local.queueEditCommands(exp, obs(upcoming = listOf("u4", "u2", "u3"), gen = 1), items("u4", "u2", "u3")),
        )
        // a new trailing row
        val n = QueueItem(id = "new", uid = "unew")
        val cmds = e.local.queueEditCommands(exp, obs(upcoming = listOf("u2", "u3", "u4", "unew"), gen = 1), items("u2", "u3", "u4") + n)
        assertEquals(1, cmds.size)
        assertEquals(listOf("unew"), (cmds[0] as RemoteCommand.Append).rows.map { it.rid })
        assertEquals("a local row's uid is its rid until the host says otherwise", "unew", e.controller.ridByUid["unew"])
    }

    @Test fun aLeadingNewRowIsPlayNextAndWithNothingKnownItIsAnAppend() = runTest {
        val e = env(); e.mapDefault()
        val n = QueueItem(id = "new", uid = "unew")
        val exp = obs(upcoming = listOf("u2", "u3"))
        val next = e.local.queueEditCommands(exp, obs(upcoming = listOf("unew", "u2", "u3"), gen = 1), listOf(n) + items("u2", "u3"))
        assertEquals(1, next.size)
        assertTrue(next[0] is RemoteCommand.EnqueueNext)
        val e2 = env()
        val none = e2.local.queueEditCommands(obs(upcoming = emptyList()), obs(upcoming = listOf("unew"), gen = 1), listOf(n))
        assertTrue("nothing was upcoming before: an append", none.single() is RemoteCommand.Append)
    }

    @Test fun aQueueGenerationBumpWithTheSameUpcomingRowsSendsNothing() = runTest {
        val e = env(); e.mapDefault()
        val exp = obs(upcoming = listOf("u2", "u3"))
        e.target.play(listOf(QueueItem(id = "q", uid = "u1"), QueueItem(id = "q2", uid = "u2"), QueueItem(id = "q3", uid = "u3")), 0, 0, false)
        assertTrue(e.local.diff(exp, obs(upcoming = listOf("u2", "u3"), gen = 5)).isEmpty())
    }

    // ---- observeAndSend: pending hold ----

    @Test fun aParticipantsSentEditHoldsReconcileForThreeSecondsOrUntilANewerRevision() = runTest {
        val clock = SharedClock { t }
        val hub = LoopbackHub()
        val host = RemoteSessionController(null, RemoteSongResolver(catalogItem = { QueueItem(id = it) }), { "h" }, "test", SharedClock { t }, backgroundScope)
        host.attach(hub.join("A"), RemoteSessionMode.LISTEN_TOGETHER, true, RemoteQueueModel(rows = listOf(row("s1"), row("s2")), isPlaying = true, anchor = t, revision = 1), autoTick = false)
        val target = InMemoryRemoteTarget { t }
        val guest = RemoteSessionController(target, RemoteSongResolver(catalogItem = { QueueItem(id = it) }), { "g" }, "test", clock, backgroundScope)
        guest.attach(hub.join("B"), RemoteSessionMode.LISTEN_TOGETHER, false, autoTick = false)
        runCurrent(); runCurrent()
        val rev = guest.lastRevision
        assertTrue(rev >= 1)
        target.play(listOf(QueueItem(id = "s1"), QueueItem(id = "s2")), 0, 0, false)
        guest.ridByUid[target.item(0).uid] = "r-s1"; guest.ridByUid[target.item(1).uid] = "r-s2"
        val local = RemoteLocalChanges(guest, target, clock, { t })
        local.observeAndSend() // baseline
        target.userSkipNext()
        local.observeAndSend()
        runCurrent()
        assertTrue(local.holdsReconcile(t + 1_000, rev))
        assertFalse("a newer revision releases the hold", local.holdsReconcile(t + 1_000, rev + 1))
        assertFalse("and so does the 3 s timeout", local.holdsReconcile(t + 3_500, rev))
        assertEquals("r-s1", ((host.model.rows.firstOrNull()?.rid) ?: ""))
    }

    // ---- Auto-DJ suspension ----

    @Test fun mixTogetherBlockPublishesItsReasonAndNotifies() {
        var fired = 0
        MixTogetherBlock.onChanged = { fired++ }
        assertNull(MixTogetherBlock.reason)
        MixTogetherBlock.set(MixTogetherBlock.REASON)
        MixTogetherBlock.set(MixTogetherBlock.REASON) // unchanged: no second notification
        assertEquals(1, fired)
        assertEquals("Auto DJ is off while you mix together.", MixTogetherBlock.reason)
        assertTrue(MixTogetherBlock.blocked)
        MixTogetherBlock.set(null)
        assertEquals(2, fired)
        assertFalse(MixTogetherBlock.blocked)
    }

    @Test fun theAssistantAndAutoMixTabSeeTheBlockAsAShellActionException() {
        val ex = ShellActionException.MixTogetherActive(MixTogetherBlock.REASON)
        assertEquals("Auto DJ is off while you mix together.", ex.message)
    }
}

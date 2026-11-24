package com.levi.pocketdj.remote

import com.levi.pocketdj.playback.durable.SessionRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure election / size-cap / backoff rules (iOS `RemoteSessionTests` statics). */
class RemoteElectionTest {
    private fun claim(active: Boolean, rev: Int, id: String) = HostClaim(active, rev, id)

    @Test fun shouldYieldIsSymmetricAndActiveBeatsEmptyThenRevisionThenLowerId() {
        val real = claim(true, 3, "H"); val empty = claim(false, 9, "E")
        // An empty host with a newer revision still yields to a real session, and the real one never yields.
        assertTrue(RemoteElection.shouldYield(theirs = real, mine = empty))
        assertFalse(RemoteElection.shouldYield(theirs = empty, mine = real))
        // Newer revision wins between two active hosts; a tie goes to the lower id.
        assertTrue(RemoteElection.shouldYield(claim(true, 4, "Z"), claim(true, 3, "A")))
        assertFalse(RemoteElection.shouldYield(claim(true, 3, "A"), claim(true, 4, "Z")))
        assertTrue(RemoteElection.shouldYield(claim(true, 3, "A"), claim(true, 3, "Z")))
        assertFalse(RemoteElection.shouldYield(claim(true, 3, "Z"), claim(true, 3, "A")))
        // Exactly one side yields, for every pairing.
        val all = listOf(true, false).flatMap { a -> listOf(1, 2).flatMap { r -> listOf("A", "B").map { claim(a, r, it) } } }
        for (x in all) for (y in all) if (x != y) {
            assertNotEquals("$x vs $y", RemoteElection.shouldYield(x, y), RemoteElection.shouldYield(y, x))
        }
    }

    @Test fun lowestRemainingIdWinsTheHandOver() {
        assertEquals("B", RemoteElection.winner(setOf("C", "B")))
        assertNull(RemoteElection.winner(emptySet()))
    }

    @Test fun joinerSelfHostsOnlyWhenAloneAndReHellosOtherwise() {
        val to = RemoteTuning.ELECTION_TIMEOUT_MS
        fun act(hasState: Boolean = false, now: Double, helloAt: Double = 0.0, roster: Set<String>) =
            RemoteElection.joinerAction(hasState, now, attachedAt = 0.0, lastHelloAt = helloAt, roster = roster, localId = "B")
        assertEquals(RemoteElection.JoinerAction.NONE, act(now = to - 1, roster = setOf("B")))
        assertEquals(RemoteElection.JoinerAction.SELF_HOST, act(now = to + 1, roster = setOf("B")))
        assertEquals(RemoteElection.JoinerAction.REHELLO, act(now = to + 1, roster = setOf("A", "B")))
        // A hello went out recently: wait a full timeout before the next one.
        assertEquals(RemoteElection.JoinerAction.NONE, act(now = to + 1, helloAt = 4_000.0, roster = setOf("A", "B")))
        assertEquals(RemoteElection.JoinerAction.REHELLO, act(now = 4_000.0 + to, helloAt = 4_000.0, roster = setOf("A", "B")))
        // Once a state arrived there is nothing to elect.
        assertEquals(RemoteElection.JoinerAction.NONE, act(hasState = true, now = to * 3, roster = setOf("B")))
    }

    @Test fun stateRequestBacksOffTwoFourEightThenCapsAtSixteen() {
        val t = StateRequestTracker()
        val sent = ArrayList<Double>()
        var now = 0.0
        while (now <= 80_000) {
            if (t.shouldSend("H", 5, now)) sent += now
            now += 500
        }
        assertEquals(listOf(0.0, 2_000.0, 6_000.0, 14_000.0, 30_000.0, 46_000.0, 62_000.0, 78_000.0), sent)
        // A request for a NEWER revision goes out at once; an answer clears the entry.
        assertTrue(t.shouldSend("H", 6, now))
        t.answered("H")
        assertTrue(t.shouldSend("H", 6, now))
        // Hosts are tracked independently.
        assertTrue(t.shouldSend("G", 6, now))
    }

    private fun row(i: Int, pad: Int) = RemoteRow(
        "r$i", SessionRow(songId = "s$i", title = "x".repeat(pad), artist = "y".repeat(pad), lengthMs = 200_000),
    )

    private fun stateBuilder(rows: List<RemoteRow>, index: Int): (Int, Int) -> RemotePlaybackState = { behind, ahead ->
        val m = RemoteQueueModel(rows = rows, index = index, isPlaying = true, revision = 1)
        m.state("H", RemoteSessionMode.LISTEN_TOGETHER, "ses", 0.0, behind = behind, ahead = ahead)
    }

    @Test fun fullWindowRidesWhenItFitsTheBudget() {
        val f = RemoteElection.fitState(RemoteTuning.MAX_STATE_BYTES, stateBuilder((0 until 300).map { row(it, 4) }, 5))
        assertEquals(RemoteQueueModel.WINDOW_AHEAD, f.ahead)
        assertEquals(RemoteQueueModel.WINDOW_BEHIND, f.behind)
        assertTrue(f.bytes <= RemoteTuning.MAX_STATE_BYTES)
        val s = f.envelope.decode(RemotePlaybackState.serializer())!!
        assertEquals(206, s.rows.size) // 5 behind + current + 200 ahead
    }

    @Test fun oversizedWindowHalvesUntilItFitsAndKeepsTheCurrentRow() {
        val rows = (0 until 300).map { row(it, 600) }
        val f = RemoteElection.fitState(RemoteTuning.MAX_STATE_BYTES, stateBuilder(rows, 5))
        assertTrue(f.bytes <= RemoteTuning.MAX_STATE_BYTES)
        assertTrue(f.ahead < RemoteQueueModel.WINDOW_AHEAD)
        val s = f.envelope.decode(RemotePlaybackState.serializer())!!
        assertEquals("r5", s.currentRow?.rid)
        assertTrue(s.rows.size < 221)
        assertEquals(300, s.totalCount)
        // A tighter transport budget trims further.
        val mid = (0 until 300).map { row(it, 100) }
        val roomy = RemoteElection.fitState(1_000_000, stateBuilder(mid, 5))
        val tight = RemoteElection.fitState(20_000, stateBuilder(mid, 5))
        assertEquals(RemoteQueueModel.WINDOW_AHEAD, roomy.ahead)
        assertTrue(tight.bytes <= 20_000)
        assertTrue(tight.ahead < roomy.ahead)
    }

    @Test fun windowNeverShrinksBelowTheMinimum() {
        val rows = (0 until 100).map { row(it, 4_000) }
        val f = RemoteElection.fitState(1_000, stateBuilder(rows, 0))
        assertEquals(RemoteTuning.MIN_WINDOW_AHEAD, f.ahead)
        assertTrue("sent anyway, like iOS", f.bytes > 1_000)
    }

    @Test fun deviceNameIsOwnerPlusModel() {
        assertEquals("Levi’s Pixel 9", RemoteDevice.name("Levi", "Pixel 9"))
        assertEquals("Pixel 9", RemoteDevice.name("  ", "Pixel 9"))
    }

}

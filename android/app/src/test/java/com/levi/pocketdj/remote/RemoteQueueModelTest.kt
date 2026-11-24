package com.levi.pocketdj.remote

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.playback.durable.SessionRow
import com.levi.pocketdj.playback.sequencer.RepeatMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ports the model cases of iOS `RemoteSessionTests` (testModelCommands + the model parts of the session tests). */
class RemoteQueueModelTest {
    private fun row(id: String, rid: String = "r-$id") =
        RemoteRow(rid, SessionRow(songId = id, title = "T $id", artist = "A", lengthMs = 200_000))

    private fun RemoteQueueModel.ups() = upcoming.map { it.songId }

    private fun playing(ids: List<String>, start: Int = 0, now: Double = 0.0) = RemoteQueueModel().also {
        assertTrue(it.apply(RemoteCommand.Play(ids.map { i -> row(i) }, start), now))
    }

    @Test fun modelCommandsPortedFromIos() {
        val m = RemoteQueueModel()
        val ids = listOf("s1", "s2", "s3", "s4", "s5")
        assertTrue(m.apply(RemoteCommand.Play(ids.map { row(it) }, 1), 0.0))
        assertEquals("s2", m.currentRow?.songId)
        val r0 = m.revision
        // Natural advance reported by TWO speakers moves the set once.
        assertTrue(m.apply(RemoteCommand.Advanced("r-s2"), 1_000.0))
        assertFalse(m.apply(RemoteCommand.Advanced("r-s2"), 1_001.0))
        assertEquals("s3", m.currentRow?.songId)
        assertEquals(r0 + 1, m.revision)
        // Position runs while playing, freezes on pause.
        assertEquals(5_000L, m.position(6_000.0))
        m.apply(RemoteCommand.SetPlaying(false), 6_000.0)
        assertEquals(5_000L, m.position(60_000.0))
        // Previous past 3 s restarts; within 3 s goes back.
        m.apply(RemoteCommand.SkipPrevious, 60_000.0)
        assertEquals("s3", m.currentRow?.songId)
        assertEquals(0L, m.positionMs)
        m.apply(RemoteCommand.SkipPrevious, 60_100.0)
        assertEquals("s2", m.currentRow?.songId)
        // Remove / move / reorder only touch the upcoming tail.
        assertFalse("the current row is never removed", m.apply(RemoteCommand.Remove("r-s2"), 0.0))
        m.apply(RemoteCommand.Move("r-s5", 0), 0.0)
        assertEquals(listOf("s5", "s3", "s4"), m.ups())
        m.apply(RemoteCommand.Reorder(listOf("r-s4", "r-s5")), 0.0)
        assertEquals("unlisted rows keep their slot", listOf("s4", "s3", "s5"), m.ups())
        // Shuffle is reversible to the canonical order, keeping rows added while shuffled.
        m.apply(RemoteCommand.SetShuffle(true), 0.0) { it.reversed() }
        assertEquals(listOf("s5", "s3", "s4"), m.ups())
        m.apply(RemoteCommand.Append(listOf(row("s1", "r-again"))), 0.0)
        m.apply(RemoteCommand.SetShuffle(false), 0.0)
        assertEquals(listOf("s4", "s3", "s5", "s1"), m.ups())
        // End of set: stops on the last row; repeat-all wraps.
        m.apply(RemoteCommand.JumpTo("r-again"), 0.0)
        m.apply(RemoteCommand.SkipNext, 0.0)
        assertFalse(m.isPlaying)
        m.apply(RemoteCommand.SetRepeat(RepeatMode.ALL), 0.0)
        m.apply(RemoteCommand.PlayPause, 0.0)
        m.apply(RemoteCommand.SkipNext, 0.0)
        assertEquals(0, m.index)
    }

    @Test fun broadcastWindowIsBoundedAndIndexRelative() {
        val big = RemoteQueueModel()
        big.apply(RemoteCommand.Play((0 until 1_000).map { row("s1", "r$it") }, 500), 0.0)
        val s = big.state("H", RemoteSessionMode.LISTEN_TOGETHER, "x", 0.0)
        assertEquals(500 - RemoteQueueModel.WINDOW_BEHIND, s.windowStart)
        assertEquals(RemoteQueueModel.WINDOW_BEHIND + 1 + RemoteQueueModel.WINDOW_AHEAD, s.snapshot.queue.size)
        assertEquals("r500", s.currentRow?.rid)
        assertEquals(1_000, s.totalCount)
        assertEquals(RemoteQueueModel.WINDOW_BEHIND, s.snapshot.index)
        assertEquals(s.rowIds.size, s.snapshot.queue.size)
        assertEquals(10, RemoteQueueModel.MIN_WINDOW_AHEAD)
        // Shrunk window (the size-budget trim) still carries the current row.
        val small = big.state("H", RemoteSessionMode.LISTEN_TOGETHER, "x", 0.0, behind = 2, ahead = RemoteQueueModel.MIN_WINDOW_AHEAD)
        assertEquals(2 + 1 + 10, small.rowIds.size)
        assertEquals("r500", small.currentRow?.rid)
    }

    @Test fun windowNearTheStartHasNoNegativeStart() {
        val m = playing((0 until 30).map { "s$it" }, 3)
        val s = m.state("H", RemoteSessionMode.BACKSEAT, "x", 0.0)
        assertEquals(0, s.windowStart)
        assertEquals(3, s.snapshot.index)
        assertEquals(30, s.rowIds.size)
        assertEquals("backseat", PdjJson.lenient.encodeToJsonElement(RemoteSessionMode.serializer(), s.mode).toString().trim('"'))
    }

    @Test fun emptyModelStateIsInactive() {
        val s = RemoteQueueModel().state("H", RemoteSessionMode.LISTEN_TOGETHER, "x", 5.0)
        assertTrue(s.rowIds.isEmpty())
        assertFalse(s.isActiveSession)
        assertNull(s.currentRow)
    }

    @Test fun revisionBumpsOnlyOnARealChange() {
        val m = playing(listOf("a", "b", "c"))
        val rev = m.revision
        assertFalse(m.apply(RemoteCommand.SetPlaying(true), 0.0))
        assertFalse(m.apply(RemoteCommand.SetShuffle(false), 0.0))
        assertFalse(m.apply(RemoteCommand.JumpTo("r-a"), 0.0)) // already current
        assertFalse(m.apply(RemoteCommand.JumpTo("nope"), 0.0))
        assertFalse(m.apply(RemoteCommand.Remove("nope"), 0.0))
        assertFalse(m.apply(RemoteCommand.Move("r-a", 1), 0.0)) // current, not upcoming
        assertFalse(m.apply(RemoteCommand.Play(emptyList(), 0), 0.0))
        assertFalse(m.apply(RemoteCommand.Append(emptyList()), 0.0))
        assertEquals(rev, m.revision)
        assertTrue(m.apply(RemoteCommand.SetRepeat(RepeatMode.ONE), 0.0))
        assertFalse("same repeat mode again is not a change", m.apply(RemoteCommand.SetRepeat(RepeatMode.ONE), 0.0))
        assertEquals(rev + 1, m.revision)
    }

    @Test fun commandsOnAnEmptyModelAreNoOps() {
        val m = RemoteQueueModel()
        for (c in listOf(RemoteCommand.PlayPause, RemoteCommand.SetPlaying(true), RemoteCommand.Seek(5),
            RemoteCommand.SkipNext, RemoteCommand.SkipPrevious, RemoteCommand.Advanced("x"))) {
            assertFalse("$c", m.apply(c, 0.0))
        }
        assertEquals(0, m.revision)
    }

    @Test fun enqueueNextAndAppendOnAnEmptyModelStartPlaying() {
        val a = RemoteQueueModel()
        assertTrue(a.apply(RemoteCommand.EnqueueNext(listOf(row("x"))), 7.0))
        assertTrue(a.isPlaying)
        assertEquals(1, a.revision)
        val b = RemoteQueueModel()
        assertTrue(b.apply(RemoteCommand.Append(listOf(row("x"), row("y"))), 7.0))
        assertTrue(b.isPlaying)
        assertEquals(listOf("y"), b.ups())
    }

    @Test fun playNowInsertsAfterCurrentAndStarts() {
        val m = playing(listOf("a", "b", "c"))
        m.apply(RemoteCommand.SetPlaying(false), 0.0)
        assertTrue(m.apply(RemoteCommand.PlayNow(listOf(row("z"))), 10.0))
        assertEquals("z", m.currentRow?.songId)
        assertTrue(m.isPlaying)
        assertEquals(listOf("b", "c"), m.ups())
        assertEquals(listOf("a", "z", "b", "c"), m.rows.map { it.songId })
    }

    @Test fun playClampsStartIndexAndResetsShuffle() {
        val m = playing(listOf("a", "b", "c", "d"))
        m.apply(RemoteCommand.SetShuffle(true), 0.0) { it.reversed() }
        assertTrue(m.shuffleEnabled)
        assertTrue(m.canonicalUpcoming != null)
        m.apply(RemoteCommand.Play(listOf(row("p"), row("q")), 99), 0.0)
        assertFalse(m.shuffleEnabled)
        assertNull(m.canonicalUpcoming)
        assertEquals(1, m.index)
        m.apply(RemoteCommand.Play(listOf(row("p"), row("q")), -4), 0.0)
        assertEquals(0, m.index)
    }

    @Test fun advancedOnlyWhileCurrentSoManySpeakersAdvanceOnce() {
        val m = playing(listOf("a", "b", "c"))
        val reports = (1..5).count { m.apply(RemoteCommand.Advanced("r-a"), 100.0 + it) }
        assertEquals(1, reports)
        assertEquals("b", m.currentRow?.songId)
    }

    @Test fun advancedUnderRepeatOneRestartsTheTrack() {
        val m = playing(listOf("a", "b"))
        m.apply(RemoteCommand.SetRepeat(RepeatMode.ONE), 0.0)
        assertTrue(m.apply(RemoteCommand.Advanced("r-a"), 4_000.0))
        assertEquals("a", m.currentRow?.songId)
        assertEquals(0L, m.positionMs)
        assertEquals(4_000.0, m.anchor, 0.0)
    }

    @Test fun skipPreviousAtTheFirstRowUnderRepeatAllWrapsWithinThreeSeconds() {
        val m = playing(listOf("a", "b", "c"))
        m.apply(RemoteCommand.SetRepeat(RepeatMode.ALL), 0.0)
        assertTrue(m.apply(RemoteCommand.SkipPrevious, 1_000.0))
        assertEquals("c", m.currentRow?.songId)
    }

    @Test fun skipPreviousAtTheFirstRowWithoutRepeatJustRestarts() {
        val m = playing(listOf("a", "b"))
        assertTrue(m.apply(RemoteCommand.Seek(1_000), 0.0))
        assertTrue(m.apply(RemoteCommand.SkipPrevious, 500.0))
        assertEquals(0, m.index)
        assertEquals(0L, m.positionMs)
    }

    @Test fun seekAnchorsAndPlayPauseFreezesPosition() {
        val m = playing(listOf("a", "b"))
        m.apply(RemoteCommand.Seek(10_000), 1_000.0)
        assertEquals(12_000L, m.position(3_000.0))
        m.apply(RemoteCommand.PlayPause, 3_000.0)
        assertFalse(m.isPlaying)
        assertEquals(12_000L, m.positionMs)
        assertEquals(12_000L, m.position(99_999.0))
        m.apply(RemoteCommand.Seek(-50), 4_000.0)
        assertEquals(0L, m.positionMs)
    }

    @Test fun moveClampsOffsetWithinTheUpcomingTail() {
        val m = playing(listOf("a", "b", "c", "d"))
        m.apply(RemoteCommand.Move("r-b", 99), 0.0)
        assertEquals(listOf("c", "d", "b"), m.ups())
        m.apply(RemoteCommand.Move("r-b", -5), 0.0)
        assertEquals(listOf("b", "c", "d"), m.ups())
    }

    @Test fun reorderWithRidsNotUpcomingIgnoresThem() {
        val m = playing(listOf("a", "b", "c", "d"))
        m.apply(RemoteCommand.Reorder(listOf("r-a", "r-d", "ghost", "r-b")), 0.0) // r-a is current
        assertEquals(listOf("d", "c", "b"), m.ups())
        assertEquals("a", m.currentRow?.songId)
    }

    @Test fun enqueueNextWhileShuffledJoinsTheCanonicalHead() {
        val m = playing(listOf("a", "b", "c"))
        m.apply(RemoteCommand.SetShuffle(true), 0.0) { it.reversed() }
        m.apply(RemoteCommand.EnqueueNext(listOf(row("n"))), 0.0)
        assertEquals(listOf("n", "c", "b"), m.ups())
        m.apply(RemoteCommand.SetShuffle(false), 0.0)
        assertEquals(listOf("n", "b", "c"), m.ups())
    }

    @Test fun removeWhileShuffledAlsoDropsFromTheCanonicalOrder() {
        val m = playing(listOf("a", "b", "c", "d"))
        m.apply(RemoteCommand.SetShuffle(true), 0.0) { it.reversed() }
        m.apply(RemoteCommand.Remove("r-c"), 0.0)
        m.apply(RemoteCommand.SetShuffle(false), 0.0)
        assertEquals(listOf("b", "d"), m.ups())
    }

    @Test fun shuffleKeepsHeadAndCurrentRow() {
        val m = playing(listOf("a", "b", "c", "d", "e"), 2)
        m.apply(RemoteCommand.SetShuffle(true), 0.0) { it.reversed() }
        assertEquals(listOf("a", "b", "c", "e", "d"), m.rows.map { it.songId })
        assertEquals("c", m.currentRow?.songId)
    }

    @Test fun adoptingAWindowedStateRebuildsTheModel() {
        val host = RemoteQueueModel()
        host.apply(RemoteCommand.Play((0 until 300).map { row("s$it", "r$it") }, 100), 0.0)
        host.apply(RemoteCommand.SetRepeat(RepeatMode.ALL), 0.0)
        host.sourceName = "Golden Hour"
        val s = host.state("H", RemoteSessionMode.LISTEN_TOGETHER, "sess", 2_000.0)
        val adopted = RemoteQueueModel.adopting(s, positionNow = 2_000, now = 9_000.0)
        assertEquals("r100", adopted.currentRow?.rid)
        assertEquals(RemoteQueueModel.WINDOW_BEHIND, adopted.index)
        assertEquals(host.revision, adopted.revision)
        assertEquals(RepeatMode.ALL, adopted.repeatMode)
        assertEquals("Golden Hour", adopted.sourceName)
        assertEquals(2_000L, adopted.positionMs)
        assertEquals(9_000.0, adopted.anchor, 0.0)
        assertEquals(300 - (100 - RemoteQueueModel.WINDOW_BEHIND), adopted.rows.size)
    }

    @Test fun stateStampsPositionAtTheAnchorAndCarriesFlags() {
        val m = playing(listOf("a", "b"), now = 1_000.0)
        val s = m.state("H", RemoteSessionMode.BACKSEAT, "sess", 4_000.0, sessionActive = true)
        assertEquals(3_000L, s.snapshot.positionMs)
        assertEquals(4_000.0, s.anchorSharedTime, 0.0)
        assertEquals(m.revision, s.revision)
        assertEquals("off", s.snapshot.repeatMode)
        assertEquals(false, s.snapshot.shuffleEnabled)
        assertEquals("remote", s.snapshot.source.kind)
        assertEquals(true, s.sessionActive)
    }
}

package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.rows
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class SessionWriterRulesTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test
    fun play_and_indexMoves_persistPositionZero_edits_persistLivePosition() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b", "c", "d")
        d.observe()
        d.h.mode = com.levi.pocketdj.playback.PlaybackMode.CLOUD
        d.seq.historyContextProvider = { PlayContext.playlist(it!!, "Road") }
        d.seq.originProvider = { "playlist" to "pl_9" }
        d.pos = 77_000
        d.seq.play(rows("a", "b", "c"), "set_now_playing"); d.h.settle()
        var disk = d.snapshotOnDisk()!!
        assertEquals(0L, disk.positionMs)
        assertEquals(0, disk.index)
        assertEquals("set_now_playing", disk.source.id)
        assertEquals("Road", disk.source.name)
        assertEquals("playlist", disk.source.kind)
        assertEquals("pl_9", disk.source.originId)
        assertTrue(disk.sessionId.startsWith("pses_"))

        d.pos = 12_000; d.playing = true
        d.seq.appendToQueue(rows("d")) // live edit: immediate, live position
        disk = d.snapshotOnDisk()!!
        assertEquals(listOf("a", "b", "c", "d"), disk.queue.map { it.songId })
        assertEquals(12_000L, disk.positionMs)

        d.seq.skipNext(); d.h.settle() // index move: position 0 even though the engine still reports 12 s
        disk = d.snapshotOnDisk()!!
        assertEquals(1, disk.index)
        assertEquals(0L, disk.positionMs)
    }

    @Test
    fun reorderRemoveRepeatShuffle_eachPersistImmediately() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b", "c", "d")
        d.observe()
        d.seq.play(rows("a", "b", "c", "d")); d.h.settle()
        d.seq.moveUpcoming(listOf(2), 0)
        assertEquals(listOf("a", "d", "b", "c"), d.snapshotOnDisk()!!.queue.map { it.songId })
        val uid = d.seq.state.value.queue[1].uid
        d.seq.removeUpcoming(setOf(uid))
        assertEquals(listOf("a", "b", "c"), d.snapshotOnDisk()!!.queue.map { it.songId })
        d.seq.cycleRepeatMode()
        assertEquals("all", d.snapshotOnDisk()!!.repeatMode)
        d.seq.setShuffle(true)
        assertEquals(true, d.snapshotOnDisk()!!.shuffleEnabled)
    }

    @Test
    fun tick_persistsPausedAndResumedTransitionsImmediately_andThrottlesPlaying() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        d.observe()
        d.seq.play(rows("a", "b")); d.h.settle()
        val base = d.diskWriter.writeCount
        d.playing = true; d.pos = 1_000; d.clockMs += 1_000; d.writer.tick() // play transition
        assertEquals(base + 1, d.diskWriter.writeCount)
        d.pos = 3_000; d.clockMs += 2_000; d.writer.tick() // < 5 s
        assertEquals(base + 1, d.diskWriter.writeCount)
        d.pos = 6_500; d.clockMs += 3_500; d.writer.tick() // >= 5 s since last write
        assertEquals(base + 2, d.diskWriter.writeCount)
        d.playing = false; d.pos = 6_900; d.clockMs += 10; d.writer.tick() // pause: immediate
        assertEquals(base + 3, d.diskWriter.writeCount)
        assertEquals(6_900L, d.snapshotOnDisk()!!.positionMs)
    }

    @Test
    fun tick_ignoresAStaleEnginePosition_untilTheRowIsLoaded() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        var valid = false
        val w = SessionWriter(d.store, position = { 99_000 }, isPlaying = { true }, positionValid = { valid })
        d.seq.play(rows("a", "b")); d.h.settle()
        w.onState(d.seq.state.value)
        val before = d.diskWriter.writeCount
        d.clockMs += 10_000; w.tick()
        assertEquals(before, d.diskWriter.writeCount)
        valid = true
        d.clockMs += 10_000; w.tick()
        assertTrue(d.diskWriter.writeCount > before)
    }

    @Test
    fun finishingTheSet_clearsTheFile() = runTest {
        val d = DurableHarness(this, tmp.root, "a")
        d.observe()
        d.seq.play(rows("a")); d.h.settle()
        assertTrue(d.file.exists())
        d.seq.handleEnded("a"); d.h.settle() // natural end of the only row
        assertFalse(d.seq.isRunning)
        assertFalse(d.file.exists())
    }

    @Test
    fun staleOldRowPositionNeverOverwritesAfterAnIndexMove() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b", "c")
        d.observe()
        d.seq.play(rows("a", "b", "c")); d.h.settle()
        d.pos = 240_000; d.playing = true
        d.seq.skipNext() // B's resolve has not landed: the engine still holds A at 4:00
        assertEquals(0L, d.snapshotOnDisk()!!.positionMs)
        d.clockMs += 60_000
        d.writer.tick()
        d.seq.appendToQueue(rows("c")) // live edit while B is unresolved
        assertEquals(0L, d.snapshotOnDisk()!!.positionMs)
    }

    @Test
    fun heldThenFreshPlay_newSession_persistsZeroNotTheHeldOffset() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        d.observe()
        d.seq.restoreHeld(
            rows("a", "b"), 0, null, null, null,
            com.levi.pocketdj.playback.sequencer.RepeatMode.OFF, false, 42_000, sessionId = "pses_OLD",
        )
        d.seq.play(rows("a", "b")); d.h.settle()
        assertEquals(0L, d.snapshotOnDisk()!!.positionMs)
    }

    @Test
    fun resumeConsumedBeforeObserving_keepsTheOffset() = runTest {
        val d = DurableHarness(this, tmp.root, "a", "b")
        d.seq.restoreHeld(
            rows("a", "b"), 0, null, null, null,
            com.levi.pocketdj.playback.sequencer.RepeatMode.OFF, false, 90_000, sessionId = "pses_OLD",
        )
        d.seq.resumeFromHold()
        d.observe() // first observed state is running, never held
        assertEquals(90_000L, d.snapshotOnDisk()!!.positionMs)
    }
}

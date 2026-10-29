package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.playback.PlayContext
import com.levi.pocketdj.playback.sequencer.EditionDecider
import com.levi.pocketdj.playback.sequencer.RepeatMode
import com.levi.pocketdj.playback.sequencer.rows
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class)
class HeldRestoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun TestScope.dh(vararg ids: String) = DurableHarness(this, tmp.root, *ids)

    private fun snapshot(index: Int = 1, pos: Long = 42_000, sid: String = "pses_OLD") = SessionSnapshot(
        sessionId = sid,
        source = SessionSourceRef("playlist", "set_now_playing", "Friday", "playlist", "pls_1"),
        queue = listOf(
            SessionRow("a", "A", "x", 100_000),
            SessionRow("b", "B", "y", 200_000, repeatCount = 2),
            SessionRow("c", "C", "z"),
        ),
        index = index, positionMs = pos, isPlaying = true, repeatMode = "one", shuffleEnabled = true,
    )

    private fun seed(d: DurableHarness, s: SessionSnapshot = snapshot()): Long {
        d.file.writeText(SessionSnapshot.encode(s))
        d.file.setLastModified(1_500_000_000_000L)
        return d.file.lastModified()
    }

    private fun restorer(d: DurableHarness, playing: Boolean = false, disabled: Boolean = false) =
        SessionRestorer(d.store, d.seq, anyBackendPlaying = { playing }, disabled = { disabled })

    @Test
    fun restore_isHeld_noAudio_noPlayerCalls_noFileWrite() = runTest {
        val d = dh("a", "b", "c")
        val mtime = seed(d)
        val bytes = d.file.readText()
        d.observe()
        assertTrue(restorer(d).restoreIfIdle())
        d.h.settle()
        val st = d.seq.state.value
        assertTrue(st.isRunning)
        assertTrue(st.isHeldForResume)
        assertEquals(listOf("a", "b", "c"), st.queue.map { it.id })
        assertEquals(1, st.index)
        assertEquals(listOf("a"), st.played.map { it.id })
        assertEquals(listOf("c"), st.upcoming.map { it.id })
        assertEquals(RepeatMode.ONE, st.repeatMode)
        assertTrue(st.shuffleEnabled)
        assertEquals("pses_OLD", st.sessionId)
        assertEquals("Friday", st.capturedContext!!.contextName)
        assertEquals("playlist" to "pls_1", st.capturedOrigin)
        // NO audio: not one PlayerPort call of any kind
        val p = d.h.port
        assertTrue(p.loads.isEmpty() && p.urls.isEmpty())
        assertEquals(0, p.stops + p.pauses + p.resumes)
        // ... and the restore is not a write
        assertEquals(mtime, d.file.lastModified())
        assertEquals(bytes, d.file.readText())
        assertEquals(0, d.diskWriter.writeCount)
        assertNull(d.store.currentSnapshot)
        // a held deck ticking does not write either
        d.clockMs += 60_000; d.playing = true; d.writer.tick()
        assertEquals(0, d.diskWriter.writeCount)
    }

    @Test
    fun restore_persistedResolveIdWins_overTheDecider() = runTest {
        val d = dh("a", "b")
        // a decider that would pick something else must NOT be consulted for a row that carries its id
        d.seq.editionDecider = EditionDecider { item, _ -> item.copy(variant = "explicit", resolveId = "WRONG") }
        val s = snapshot().copy(queue = listOf(
            SessionRow("a", "A", "x", resolveId = "a_clean", variant = "clean"),
            SessionRow("b", "B", "y", resolveId = "b"),
        ), index = 0)
        seed(d, s)
        assertTrue(restorer(d).restoreIfIdle())
        assertEquals(listOf("a_clean", "b"), d.seq.state.value.queue.map { it.resolveId })
        assertEquals("clean", d.seq.state.value.queue[0].variant)
    }

    @Test
    fun restore_withoutResolveId_redecidesUnderTheOriginsCleanOnlyFlag() = runTest {
        val d = dh("a", "b")
        var asked: String? = "unset"
        d.seq.cleanOnlyProvider = { id -> asked = id; true }
        d.seq.editionDecider = EditionDecider { item, cleanOnly ->
            if (cleanOnly) item.copy(variant = "clean", resolveId = item.id + "_clean") else item
        }
        // an iOS-shaped file: no resolveId; a stale variant on row b must not be turned into a guessed id
        val s = snapshot().copy(queue = listOf(SessionRow("a", "A", "x"), SessionRow("b", "B", "y", variant = "explicit")), index = 0)
        seed(d, s)
        assertTrue(restorer(d).restoreIfIdle())
        assertEquals("set_now_playing", asked)
        assertEquals(listOf("a_clean", "b_clean"), d.seq.state.value.queue.map { it.resolveId })
        // no decider at all: the id simply stays the song id (never a built string)
        val d2 = dh("a", "b")
        seed(d2, s)
        assertTrue(restorer(d2).restoreIfIdle())
        assertEquals(listOf("a", "b"), d2.seq.state.value.queue.map { it.resolveId })
    }

    @Test
    fun restore_catalogNotLoaded_keepsTheLegacyVariantId_andDoesNotRedecide() = runTest {
        val d = dh("a", "b")
        var decided = 0
        d.seq.cleanOnlyProvider = { true }
        d.seq.editionDecider = object : EditionDecider {
            override fun decide(item: com.levi.pocketdj.playback.sequencer.QueueItem, cleanOnly: Boolean) =
                item.also { decided++ }.copy(variant = null, resolveId = item.id)
            override fun isReady() = false // cold start: the catalog has not published yet
        }
        seed(d, snapshot().copy(queue = listOf(SessionRow("a", "A", "x", variant = "clean"), SessionRow("b", "B", "y")), index = 0))
        assertTrue(restorer(d).restoreIfIdle())
        assertEquals(0, decided)
        assertEquals(listOf("a_clean", "b"), d.seq.state.value.queue.map { it.resolveId })
        assertEquals("clean", d.seq.state.value.queue[0].variant)
    }

    @Test
    fun restore_keepsTheCleanOnlySkipStamp() = runTest {
        val d = dh("a", "b")
        seed(d, snapshot().copy(queue = listOf(SessionRow("a", "A", "x"), SessionRow("b", "B", "y", cleanOnlySkip = true)), index = 0))
        assertTrue(restorer(d).restoreIfIdle())
        assertEquals(listOf(false, true), d.seq.state.value.queue.map { it.cleanOnlySkip })
    }

    @Test
    fun restore_mintsFreshUids_andClampsTheIndex() = runTest {
        val d = dh("a", "b", "c")
        seed(d, snapshot(index = 99))
        restorer(d).restoreIfIdle()
        val st = d.seq.state.value
        assertEquals(2, st.index)
        assertEquals(3, st.queue.map { it.uid }.toSet().size)
        assertEquals(2, st.queue[1].repeatCount)
    }

    @Test
    fun restore_isSkipped_whenRunning_playing_orDisabled_orNothingPersisted() = runTest {
        val d = dh("a", "b")
        seed(d)
        assertFalse(restorer(d, disabled = true).restoreIfIdle())
        assertFalse(restorer(d, playing = true).restoreIfIdle())
        assertFalse(d.seq.isRunning)
        d.file.delete()
        assertFalse(restorer(d).restoreIfIdle()) // nothing persisted
        seed(d)
        d.seq.play(rows("a", "b")); d.h.settle()
        val before = d.seq.state.value.queue
        assertFalse(restorer(d).restoreIfIdle()) // already running
        assertEquals(before, d.seq.state.value.queue)
    }

    @Test
    fun disableSystemProperty_isHonoured() = runTest {
        val d = dh("a")
        seed(d)
        System.setProperty(SessionRestorer.DISABLE_PROPERTY, "1")
        try {
            assertFalse(SessionRestorer(d.store, d.seq).restoreIfIdle())
        } finally {
            System.clearProperty(SessionRestorer.DISABLE_PROPERTY)
        }
        assertTrue(SessionRestorer(d.store, d.seq).restoreIfIdle())
    }

    @Test
    fun resumeFromHold_startsAtSavedOffset_andAdoptsTheSessionWithThatOffset() = runTest {
        val d = dh("a", "b", "c")
        seed(d)
        d.observe()
        restorer(d).restoreIfIdle(); d.h.settle()
        d.seq.resumeFromHold(); d.h.settle()
        val req = d.h.port.loads.single()
        assertEquals("b", req.item.id)
        assertEquals(42_000L, req.resumeAtMs)
        // adopted + persisted with the resume offset (a kill right after a play must resume where the user was)
        val disk = d.snapshotOnDisk()!!
        assertEquals(42_000L, disk.positionMs)
        assertEquals("pses_OLD", disk.sessionId)
        assertEquals(1, disk.index)
        assertEquals("one", disk.repeatMode)
    }

    @Test
    fun skipWhileHeld_dropsTheOffset_andPersistsZero() = runTest {
        val d = dh("a", "b", "c")
        seed(d)
        d.observe()
        restorer(d).restoreIfIdle(); d.h.settle()
        d.seq.skipNext(); d.h.settle()
        val req = d.h.port.loads.single()
        assertEquals("c", req.item.id)
        assertNull(req.resumeAtMs)
        assertFalse(d.seq.isHeldForResume)
        assertEquals(0L, d.snapshotOnDisk()!!.positionMs)
        assertEquals(2, d.snapshotOnDisk()!!.index)
    }

    @Test
    fun pendingRemotePlay_hookFiresOnRestore_andResumeConsumesIt() = runTest {
        val d = dh("a", "b", "c")
        seed(d)
        var fired = 0
        d.seq.onHeldRestored = { fired++; if (d.seq.isHeldForResume) d.seq.resumeFromHold() } // what the latch does
        restorer(d).restoreIfIdle(); d.h.settle()
        assertEquals(1, fired)
        assertFalse(d.seq.isHeldForResume)
        assertEquals(42_000L, d.h.port.loads.single().resumeAtMs)
    }

    @Test
    fun stop_clearsTheFile_andAFreshPlayMintsANewSessionId() = runTest {
        val d = dh("a", "b", "c")
        seed(d)
        d.observe()
        restorer(d).restoreIfIdle(); d.h.settle()
        d.seq.resumeFromHold(); d.h.settle()
        assertTrue(d.file.exists())
        d.seq.stop(); d.h.settle()
        assertFalse(d.file.exists())
        d.seq.play(rows("a", "b")); d.h.settle()
        val first = d.snapshotOnDisk()!!.sessionId
        assertNotEquals("pses_OLD", first)
        assertTrue(first.startsWith("pses_"))
        d.seq.play(rows("a", "b")); d.h.settle()
        assertNotEquals(first, d.snapshotOnDisk()!!.sessionId)
    }

    @Test
    fun coldStartWithoutARun_neverDeletesTheSnapshot() = runTest {
        val d = dh("a")
        seed(d)
        d.observe()
        d.h.settle()
        assertTrue(d.file.exists()) // idle state observed at launch must not clear the restorable file
    }

    @Test
    fun restoredContextFeedsLaterPlayAttribution() = runTest {
        val d = dh("a", "b", "c")
        seed(d)
        restorer(d).restoreIfIdle(); d.h.settle()
        d.seq.resumeFromHold(); d.h.settle()
        assertEquals(PlayContext("playlist", "set_now_playing", "Friday"), d.h.port.loads.single().context.copy(runTag = null))
    }
}

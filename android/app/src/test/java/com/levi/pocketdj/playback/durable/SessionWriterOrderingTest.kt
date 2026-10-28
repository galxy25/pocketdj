package com.levi.pocketdj.playback.durable

import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SessionWriterOrderingTest {
    @get:Rule val tmp = TemporaryFolder()

    /** Queues work so a test can run it in a hostile order. */
    private class ManualExecutor : Executor {
        val q = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { q.addLast(command) }
        fun runAll() { while (q.isNotEmpty()) q.removeFirst().run() }
        fun runLast() { q.removeLast().run(); q.clear() }
    }

    private fun snap(i: Int, sid: String = "pses_A") = SessionSnapshot(
        sessionId = sid, source = SessionSourceRef("setlist"),
        queue = listOf(SessionRow("a", "A"), SessionRow("b", "B"), SessionRow("c", "C")), index = i,
    )

    @Test
    fun aStaleQueuedWriteNeverOverwritesANewerOne() {
        val f = File(tmp.root, "s.json")
        val ex = ManualExecutor()
        val st = PlaybackSessionStore(f, VersionedJsonWriter(f, ex))
        st.save(snap(0))
        st.save(snap(1))
        st.save(snap(2))
        // newest runs first, then the stragglers: they must be dropped
        val newest = ex.q.removeLast()
        newest.run()
        ex.runAll()
        assertEquals(2, st.load()!!.index)
    }

    @Test
    fun clearCannotBeResurrectedByAQueuedWrite() {
        val f = File(tmp.root, "s.json")
        val ex = ManualExecutor()
        val st = PlaybackSessionStore(f, VersionedJsonWriter(f, ex))
        st.save(snap(1))
        st.clear()
        // delete (newest) lands first, then the older write straggles in
        val items = ex.q.toList(); ex.q.clear()
        items.last().run()
        items.first().run()
        assertFalse(f.exists())
        assertNull(st.load())
    }

    @Test
    fun flushNow_supersedesQueuedOlderSnapshots() {
        val f = File(tmp.root, "s.json")
        val ex = ManualExecutor()
        val st = PlaybackSessionStore(f, VersionedJsonWriter(f, ex))
        st.save(snap(0))
        st.save(snap(1))
        st.flush() // inline, raises the floor
        assertEquals(1, st.load()!!.index)
        ex.runAll() // stragglers (versions 1,2) are dropped
        assertEquals(1, st.load()!!.index)
        assertTrue(f.exists())
    }

    @Test
    fun asyncWritesApplyInVersionOrderWhenFifo() {
        val f = File(tmp.root, "s.json")
        val ex = ManualExecutor()
        val st = PlaybackSessionStore(f, VersionedJsonWriter(f, ex))
        for (i in 0..2) st.save(snap(i))
        ex.runAll()
        assertEquals(2, st.load()!!.index)
    }
}

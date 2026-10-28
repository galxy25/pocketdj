package com.levi.pocketdj.data.store

import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class VersionedJsonWriterTest {
    @get:Rule
    val tmp = TemporaryFolder()

    /** Manual executor: tasks run only when drained, simulating a backlog. */
    private class Queue : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.addLast(command) }
        fun drain() { while (tasks.isNotEmpty()) tasks.removeFirst().run() }
        fun runLast() { tasks.removeLast().run() }
    }

    private fun file() = File(tmp.root, "doc.json")

    @Test
    fun versionOrderDropsStale() {
        val q = Queue()
        val w = VersionedJsonWriter(file(), q)
        w.write(1) { "one" }
        w.write(2) { "two" }
        q.runLast() // v2 lands first
        q.drain() // v1 straggler must be dropped
        assertEquals("two", file().readText())
        assertEquals(1, w.writeCount)
    }

    @Test
    fun flushNowBeatsStraggler() {
        val q = Queue()
        val w = VersionedJsonWriter(file(), q)
        w.write(1) { "queued-1" }
        w.write(2) { "queued-2" }
        w.flushNow(3) { "flushed" }
        q.drain() // stragglers 1 and 2 are superseded
        assertEquals("flushed", file().readText())
        assertEquals(1, w.writeCount)
    }

    @Test
    fun deleteIsVersionOrdered() {
        val q = Queue()
        val w = VersionedJsonWriter(file(), q)
        w.write(1) { "x" }
        w.delete(2)
        w.write(3) { "y" }
        q.drain()
        assertEquals("y", file().readText()) // write after delete wins
        w.delete(2) // stale delete is a no-op
        q.drain()
        assertEquals("y", file().readText())
        w.delete(4)
        q.drain()
        assertFalse(file().exists())
    }

    @Test
    fun invalidateThroughDropsQueued() {
        val q = Queue()
        val w = VersionedJsonWriter(file(), q)
        w.write(1) { "a" }
        w.write(2) { "b" }
        w.invalidate(through = 2)
        w.write(3) { "c" }
        q.drain()
        assertEquals("c", file().readText())
        assertEquals(1, w.writeCount)
    }

    @Test
    fun renderRunsOnExecutorNotCaller() {
        val q = Queue()
        val w = VersionedJsonWriter(file(), q)
        var rendered = false
        w.write(1) { rendered = true; "z" }
        assertFalse(rendered)
        q.drain()
        assertEquals(true, rendered)
    }
}

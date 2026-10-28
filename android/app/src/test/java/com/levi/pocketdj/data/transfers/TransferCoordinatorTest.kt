package com.levi.pocketdj.data.transfers

import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferCoordinatorTest {
    private fun file() = File(tmpTransferDir(), "pocketdj-transfers.json")

    private fun coordinator(
        f: File = file(),
        work: FakeTransferWork = FakeTransferWork(),
        token: String = "",
        clock: () -> Long = { 1_000L },
    ) = TransferCoordinator(f, work, tokenProvider = { token }, ripsHost = { "rips.example.com" }, clock = clock)

    @Test fun recordIsPersistedBeforeWorkIsEnqueued() = runTest {
        val f = file()
        var persistedAtEnqueue: String? = null
        val work = FakeTransferWork { persistedAtEnqueue = if (f.isFile) f.readText() else null }
        val c = coordinator(f, work)
        c.enqueue("https://x/a.mp3", rec("s1"))
        assertNotNull("file must exist when WorkManager is called", persistedAtEnqueue)
        assertTrue(persistedAtEnqueue!!.contains("\"songId\":\"s1\""))
        assertTrue(persistedAtEnqueue!!.contains("\"workId\""))
        assertEquals(listOf("burn:s1"), work.enqueued.map { it.uniqueName })
        assertEquals(work.enqueued.single().workId, c.record("s1")!!.workId)
    }

    @Test fun recordsSurviveRestart() = runTest {
        val f = file()
        coordinator(f).enqueue("https://x/a.mp3", rec("s1"))
        val again = coordinator(f)
        assertEquals(listOf("s1"), again.records.map { it.songId })
    }

    @Test fun enqueueIsUpsertPerSong() = runTest {
        val c = coordinator()
        c.enqueue("u1", rec("s1")); c.enqueue("u2", rec("s1"))
        assertEquals(1, c.records.size)
    }

    @Test fun bearerFlagFollowsPolicy() = runTest {
        val work = FakeTransferWork()
        val c = coordinator(work = work, token = "tok")
        c.enqueue("https://bucket.s3.amazonaws.com/a.mp3", rec("s1"))
        c.enqueue("http://rip.local:8787/a.mp3", rec("s2"))
        c.enqueue("https://rips.example.com/a.mp3", rec("s3"))
        assertEquals(listOf(false, true, false), work.enqueued.map { it.attachBearer })
    }

    @Test fun progressIsRunScopedAndBeginRunResets() = runTest {
        val c = coordinator()
        val seen = ArrayList<Pair<Int, Int>>()
        c.onProgress = { e, f -> seen += e to f }
        c.beginRun()
        c.enqueue("u", rec("a")); c.enqueue("u", rec("b"))
        assertEquals(TransferProgress(2, 0), c.progress.value)
        c.onFinished(c.record("a")!!, 10)
        assertEquals(TransferProgress(2, 1), c.progress.value)
        assertTrue(c.progress.value.active)
        c.onFinished(c.record("b")!!, 10)
        assertFalse(c.progress.value.active)
        c.beginRun()
        assertEquals(TransferProgress(0, 0), c.progress.value)
        assertEquals(0 to 0, seen.last())
        c.enqueue("u", rec("c"))
        assertEquals(TransferProgress(1, 0), c.progress.value) // not "1 of 3"
    }

    @Test fun cancelDecrementsEnqueuedDropsRecordsAndCancelsWork() = runTest {
        val work = FakeTransferWork()
        val f = file()
        val c = coordinator(f, work)
        c.beginRun()
        listOf("a", "b", "c").forEach { c.enqueue("u", rec(it)) }
        c.cancel(listOf("a", "b"))
        assertEquals(listOf("c"), c.records.map { it.songId })
        assertEquals(TransferProgress(1, 0), c.progress.value)
        assertEquals(listOf("burn:a", "burn:b"), work.cancelled)
        assertEquals(listOf("c"), coordinator(f).records.map { it.songId }) // persisted
    }

    @Test fun cancelNeverGoesNegative() = runTest {
        val c = coordinator()
        c.cancel(listOf("ghost"))
        assertEquals(TransferProgress(0, 0), c.progress.value)
    }

    @Test fun cancelAllClearsEverything() = runTest {
        val work = FakeTransferWork()
        val c = coordinator(work = work)
        c.enqueue("u", rec("a"))
        c.cancelAll()
        assertTrue(c.records.isEmpty())
        assertEquals(1, work.cancelAllCalls)
        assertEquals(TransferProgress(0, 0), c.progress.value)
    }

    @Test fun reconcileDropsAbsentAndFinishedKeepsLive() = runTest {
        val work = FakeTransferWork()
        val f = file()
        val c0 = coordinator(f, work)
        listOf("run", "enq", "blk", "done", "failed", "gone").forEach { c0.enqueue("u", rec(it)) }
        val c = coordinator(f, work) // relaunch: a new process
        work.states = mapOf(
            "burn:run" to WorkStateKind.RUNNING, "burn:enq" to WorkStateKind.ENQUEUED, "burn:blk" to WorkStateKind.BLOCKED,
            "burn:done" to WorkStateKind.SUCCEEDED, "burn:failed" to WorkStateKind.FAILED,
        )
        val dropped = c.reconcileOnLaunch()
        assertEquals(setOf("done", "failed", "gone"), dropped.toSet())
        assertEquals(setOf("run", "enq", "blk"), c.records.map { it.songId }.toSet())
        assertEquals(setOf("run", "enq", "blk"), coordinator(f).records.map { it.songId }.toSet())
        assertTrue(c.reconcileOnLaunch().isEmpty()) // idempotent
    }

    @Test fun crashBetweenPersistAndEnqueueIsRecoveredByReconcile() = runTest {
        val f = file()
        val c = coordinator(f, FakeTransferWork { throw IllegalStateException("killed") })
        runCatching { c.enqueue("u", rec("s1")) }
        val after = coordinator(f) // new process; WorkManager never saw the work
        assertEquals(1, after.records.size)
        assertEquals(listOf("s1"), after.reconcileOnLaunch())
        assertTrue(after.records.isEmpty())
    }

    @Test fun bytesPublishAtMostOncePerHalfSecondPerTask() {
        val c = coordinator()
        val out = ArrayList<Pair<String, Long>>()
        c.onBytes = { id, d -> out += id to d }
        c.reportBytes("a", 100, nowMs = 0)      // first => publish
        c.reportBytes("a", 50, nowMs = 200)     // throttled
        c.reportBytes("a", 25, nowMs = 499)     // throttled
        c.reportBytes("b", 7, nowMs = 300)      // other task unaffected
        c.reportBytes("a", 10, nowMs = 500)     // publish accumulated 50+25+10
        assertEquals(listOf("a" to 100L, "b" to 7L, "a" to 85L), out)
    }

    @Test fun finishedAndFailedFireHooksAndDropRecord() = runTest {
        val c = coordinator()
        var fin: Pair<String, Long>? = null
        var fail: Pair<String, String>? = null
        c.onBurnFinalized = { r, b -> fin = r.songId to b }
        c.onBurnFailed = { r, m -> fail = r.songId to m }
        c.enqueue("u", rec("a")); c.enqueue("u", rec("b"))
        c.onFinished(c.record("a")!!, 99)
        c.onFailed(c.record("b")!!, "HTTP 400")
        assertEquals("a" to 99L, fin)
        assertEquals("b" to "HTTP 400", fail)
        assertTrue(c.records.isEmpty())
        assertNull(c.record("a"))
        assertEquals(2, c.counters().finished)
    }

    @Test fun corruptDocIsKeptAsideNotOverwritten() {
        val f = file()
        f.writeText("{not json")
        val c = coordinator(f)
        assertTrue(c.records.isEmpty())
        assertTrue(f.parentFile.list()!!.any { it.startsWith("pocketdj-transfers.json.corrupt-") })
    }

    @Test fun reconcileKeepsRecordsEnqueuedByThisProcess() = kotlinx.coroutines.test.runTest {
        val w = FakeTransferWork()
        val c = TransferCoordinator(java.io.File(tmpTransferDir(), "t.json"), w)
        c.enqueue("https://x/a", rec("s1"))
        w.states = emptyMap() // WorkManager insert not visible yet
        assertEquals(emptyList<String>(), c.reconcileOnLaunch())
        assertEquals(1, c.records.size)
    }
}

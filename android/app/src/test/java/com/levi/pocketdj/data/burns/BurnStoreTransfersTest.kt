package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.transfers.FakeTransferWork
import com.levi.pocketdj.data.transfers.TransferCoordinator
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnStoreTransfersTest {
    private class Env {
        val r = Rig()
        val work = FakeTransferWork()
        val tFile = File(r.dir, "pocketdj-transfers.json")
        fun coordinator() = TransferCoordinator(tFile, work)
        fun store(c: TransferCoordinator) =
            BurnStore(r.ledger, r.folder, r.rips, lookup = { r.catalog[it] ?: (null to null) }, clock = { r.nowMs }, transfers = c)
        init {
            r.rips.entries["s1"] = digital("s1"); r.rips.entries["s2"] = digital("s2")
        }
    }

    @Test fun burnQueuesBackgroundWorkInsteadOfDownloadingInProcess() = runTest {
        val e = Env(); val c = e.coordinator(); val store = e.store(c)
        val res = store.burn(listOf(bs("s1"), bs("s2")))
        assertEquals(2, res.queued)
        assertTrue(e.r.rips.downloads.isEmpty())
        assertEquals(listOf("burn:s1", "burn:s2"), e.work.enqueued.map { it.uniqueName })
        assertEquals(BurnState.DOWNLOADING, store.items.value.getValue("s1").state)
        assertEquals(2, c.records.size)
        assertTrue(c.records.first().sidecarText.isNotEmpty())
        // ledger on disk already holds the downloading rows (persist-before-enqueue)
        assertTrue(e.r.ledger.readText().contains("downloading"))
        assertEquals(2, c.progress.value.enqueued)
    }

    @Test fun workerFinalizationFlipsItemToReadyAndFiresFanOut() = runTest {
        val e = Env(); val c = e.coordinator(); val store = e.store(c)
        var fan: Pair<String, Long>? = null
        store.onAnyBurnFinalized = { id, b -> fan = id to b }
        store.burn(listOf(bs("s1")))
        c.onFinished(c.record("s1")!!, 4321)
        val item = store.items.value.getValue("s1")
        assertEquals(BurnState.READY, item.state)
        assertEquals(4321L, item.bytes)
        assertEquals("s1" to 4321L, fan)
    }

    @Test fun workerFailureShowsErrorRow() = runTest {
        val e = Env(); val c = e.coordinator(); val store = e.store(c)
        store.burn(listOf(bs("s1")))
        c.onFailed(c.record("s1")!!, "download failed (HTTP 400)")
        val item = store.items.value.getValue("s1")
        assertEquals(BurnState.ERROR, item.state)
        assertEquals("download failed (HTTP 400)", item.error)
    }

    @Test fun stoppingClearsRowsAndOverlay() = runTest {
        val e = Env(); val c = e.coordinator(); val store = e.store(c)
        store.burn(listOf(bs("s1"), bs("s2")))
        store.cancelTransfers(listOf("s1", "s2"))
        assertTrue(store.items.value.isEmpty())
        assertEquals(0, c.progress.value.enqueued)
        assertNull(store.progress.value)
    }

    @Test fun healPromotesFinishedFileAndErrorsLostOnes() = runTest {
        val e = Env(); val c = e.coordinator(); val store = e.store(c)
        store.burn(listOf(bs("s1"), bs("s2")))
        val a = store.items.value.getValue("s1").audioFileName
        // process dies: worker had moved s1's file but never reported; s2 never started
        File(e.r.burns, a).apply { parentFile.mkdirs() }.writeBytes(ByteArray(9_000) { 3 })
        store.flush()
        val c2 = e.coordinator() // new process, same files
        e.work.states = emptyMap()
        c2.reconcileOnLaunch()
        val store2 = e.store(c2)
        assertEquals(2, store2.healStrandedDownloads())
        assertEquals(BurnState.READY, store2.items.value.getValue("s1").state)
        assertEquals(9_000L, store2.items.value.getValue("s1").bytes)
        assertEquals(BurnState.ERROR, store2.items.value.getValue("s2").state)
    }

    @Test fun healLeavesLiveTransfersAlone() = runTest {
        val e = Env(); val c = e.coordinator(); val store = e.store(c)
        store.burn(listOf(bs("s1")))
        assertEquals(0, store.healStrandedDownloads())
        assertEquals(BurnState.DOWNLOADING, store.items.value.getValue("s1").state)
    }

    @Test fun secondBurnWhileRunInFlightDoesNotResetCounters() = runTest {
        val e = Env(); val c = e.coordinator(); val store = e.store(c)
        store.burn(listOf(bs("s1")))
        store.burn(listOf(bs("s2")))
        assertEquals(2, c.progress.value.enqueued)
    }
}

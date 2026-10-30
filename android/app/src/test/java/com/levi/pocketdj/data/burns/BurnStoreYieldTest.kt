package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.transfers.FakeTransferWork
import com.levi.pocketdj.data.transfers.TransferCoordinator
import com.levi.pocketdj.mix.stream.BurnStoreAdopter
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnStoreYieldTest {
    private class Env {
        val r = Rig()
        val work = FakeTransferWork()
        val c = TransferCoordinator(File(r.dir, "pocketdj-transfers.json"), work)
        val store = BurnStore(r.ledger, r.folder, r.rips, lookup = { r.catalog[it] ?: (null to null) }, clock = { r.nowMs }, transfers = c)
        init { r.rips.entries["s1"] = digital("s1"); r.rips.entries["s2"] = digital("s2") }
    }

    @Test fun yieldCancelsOnlyThePendingBackgroundTransferOfThatSong() = runTest {
        val e = Env()
        e.store.burn(listOf(bs("s1"), bs("s2")))
        assertTrue(e.store.yieldBackgroundDownload("s1"))
        assertNull(e.c.record("s1"))
        assertNull(e.store.items.value["s1"])                       // half-done row dropped
        assertEquals(BurnState.DOWNLOADING, e.store.items.value.getValue("s2").state)
        assertTrue(e.c.record("s2") != null)
    }

    @Test fun yieldIsANoOpWhenNothingIsDownloadingOrNoTransfers() = runTest {
        val e = Env()
        assertFalse(e.store.yieldBackgroundDownload("s1"))          // nothing queued
        val plain = Rig().also { it.rips.entries["s1"] = digital("s1") }.store()
        assertFalse(plain.yieldBackgroundDownload("s1"))            // in-process path
    }

    @Test fun adopterYieldsThenAdoptionLandsOneReadyBurn() = runTest {
        val e = Env()
        e.store.burn(listOf(bs("s1")))
        val adopter = BurnStoreAdopter(e.store)
        adopter.yieldBackgroundDownload("s1")                       // MixStreamLoader.open() does this
        val tmp = File(e.r.dir, "stream.tmp").apply { writeBytes(ByteArray(2_000)) }
        assertTrue(adopter.adoptFile("s1", "T", "Artist", tmp) != null)
        assertEquals(BurnState.READY, e.store.items.value.getValue("s1").state)
        assertNull(e.c.record("s1"))
    }
}

package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.BurnFolder
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.data.burns.BurnRoot
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.AppPrivateBurnFolder
import com.levi.pocketdj.data.burns.Rig
import com.levi.pocketdj.data.burns.bs
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PruneWorkerGateTest {
    @Test fun periodicWorkIsDeclaredAndRegisteredForTheShell() {
        val spec = com.levi.pocketdj.work.ShellWork.specs.single { it.id == com.levi.pocketdj.work.WorkIds.STORAGE_PRUNE }
        assertEquals(24 * 60L, spec.repeatMinutes)
        assertFalse(spec.requiresNetwork)
        assertTrue(com.levi.pocketdj.data.transfers.StoragePruneWorker::class.java
            .isAssignableFrom(com.levi.pocketdj.work.WorkerRegistry.resolve(com.levi.pocketdj.work.WorkIds.STORAGE_PRUNE)!!))
    }

    /** Counts roots() calls; the real BurnStore lists once per roots() it asks for. */
    private class CountingFolder(private val inner: AppPrivateBurnFolder, private val dir: File) : BurnFolder {
        var rootsCalls = 0
        override fun roots(): List<BurnRoot> { rootsCalls++; return inner.roots() }
        override fun activeWritable() = inner.activeWritable()
    }

    @Test fun planningListsEachRootOnceAndSweepsOrphanStemsFromTheSameSnapshot() = runTest {
        val r = Rig()
        for (id in listOf("a", "b", "c")) {
            r.rips.entries[id] = com.levi.pocketdj.data.burns.digital(id)
            r.rips.serve("rips/$id.mp3", 5_000)
            r.catalog[id] = com.levi.pocketdj.data.burns.song(id, name = "Song $id") to com.levi.pocketdj.data.burns.album("alb_$id")
        }
        r.store().burn(listOf(bs("a"), bs("b"), bs("c")))
        val orphan = File(r.burns, BurnFileNames.stemFileName("ghost", BurnFileNames.STEM_NAMES.first())).apply { writeText("x".repeat(9_000)) }
        val folder = CountingFolder(r.folder, r.burns)
        val store = com.levi.pocketdj.data.burns.BurnStore(r.ledger, folder, r.rips, lookup = { r.catalog[it] ?: (null to null) }, clock = { r.nowMs })
        assertEquals(3, store.items.value.values.count { it.state == BurnState.READY })
        val before = folder.rootsCalls

        val plan = store.planEvictionSweepingOrphans(listOf("a", "b", "c"), capBytes = 11_000L, capSongs = Int.MAX_VALUE)

        assertEquals("one roots()/listing per prune plan", 1, folder.rootsCalls - before)
        assertFalse("orphan aux swept first", orphan.exists())
        assertTrue(plan.evict.isNotEmpty() && plan.evict.size < 3 && plan.evict.first() == "a")
        assertTrue(File(r.burns, store.items.value.getValue("a").audioFileName).exists()) // plan deletes no burned song
    }
}

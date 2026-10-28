package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.BurnItem
import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.EvictionPlan
import com.levi.pocketdj.data.stats.PlayStatsStore
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StorageManagerPlanTest {
    private class FakeSettings(var gb: Double? = null, var songs: Int? = null, var last: Long? = null) : StorageSettingsPort {
        val events = mutableListOf<String>()
        override suspend fun capGB() = gb
        override suspend fun capSongs() = songs
        override suspend fun lastPruneAt() = last
        override suspend fun stampPrune(nowMs: Long) { last = nowMs; events += "stamp" }
    }

    private fun item(id: String, bytes: Long = 100, downloadedAt: Double = 0.0, state: BurnState = BurnState.READY) =
        BurnItem(songId = id, title = id, artist = "A", audioFileName = "$id.mp3", sidecarFileName = "$id.txt",
            source = "digital", bytes = bytes, downloadedAt = downloadedAt, state = state)

    /** Evicts in `order` until bytes fit / songs fit — the same rule as EvictionPlanner, no disk. */
    private class FakeBurns(val list: List<BurnItem>, val settings: FakeSettings? = null, val failPlan: Boolean = false) : PruneBurns {
        var planCalls = 0
        var lastOrder: List<String> = emptyList()
        val removed = mutableListOf<List<String>>()
        var onRemove: (List<String>) -> Unit = {}
        override fun items() = list
        override fun plan(order: List<String>, capBytes: Long, capSongs: Int): EvictionPlan {
            settings?.events?.add("plan")
            planCalls++
            if (failPlan) throw IllegalStateException("disk scan blew up")
            lastOrder = order
            val byId = list.associateBy { it.songId }
            var usage = list.sumOf { it.bytes }
            val before = usage
            var count = list.count { it.state == BurnState.READY }
            val evict = ArrayList<String>()
            for (id in order) {
                if (!(usage > capBytes || count > capSongs)) break
                evict += id; usage -= byId.getValue(id).bytes; count--
            }
            return EvictionPlan(before, usage, evict)
        }
        override fun removeBurns(songIds: List<String>) { settings?.events?.add("remove"); removed += songIds; onRemove(songIds) }
    }

    private fun stats(vararg plays: Pair<String, Long>): PlayStatsStore {
        val s = PlayStatsStore(File(Files.createTempDirectory("pdj-sm").toFile(), "s.json"), nowMs = 0)
        plays.forEach { (id, at) -> s.notePlayed(id, at) }
        return s
    }

    private fun mgr(b: PruneBurns, s: PlayStatsStore, set: FakeSettings, now: Long = 1_000_000_000L, protect: () -> Set<String> = { emptySet() }) =
        StorageManager(b, s, set, protectedSongIds = protect, clock = { now })

    @Test fun noCapSetNeverDeletesAnything() = runTest {
        val set = FakeSettings(last = null)
        val b = FakeBurns(listOf(item("a"), item("b")))
        val m = mgr(b, stats(), set)
        assertNull(m.pruneIfDue()); assertNull(m.prune())
        assertEquals(0, b.planCalls); assertTrue(b.removed.isEmpty()); assertTrue(set.events.isEmpty())
    }

    @Test fun gateTwentyHoursAndStampBeforeEviction() = runTest {
        val now = 100L * 3600 * 1000
        val set = FakeSettings(songs = 1, last = now - 19 * 3600 * 1000L)
        val b = FakeBurns(listOf(item("a"), item("b")), set)
        val m = mgr(b, stats(), set, now)
        assertNull(m.pruneIfDue())                       // 19 h: too soon
        assertEquals(0, b.planCalls)
        set.last = now - 20 * 3600 * 1000L               // exactly 20 h: due
        val r = m.pruneIfDue()!!
        assertEquals(1, r.evicted)
        assertEquals(listOf("stamp", "plan", "remove"), set.events)
        assertEquals(now, set.last)
        assertNull(m.pruneIfDue())                       // the stamp now blocks an immediate re-run
    }

    @Test fun stampIsWrittenEvenWhenThePlanThrows() = runTest {
        val set = FakeSettings(gb = 1.0)
        val b = FakeBurns(listOf(item("a")), set, failPlan = true)
        val m = mgr(b, stats(), set, now = 777)
        val ex = runCatching { m.prune() }.exceptionOrNull()
        assertTrue(ex is IllegalStateException)
        assertEquals(777L, set.last)                     // a crash mid-prune cannot loop
        assertEquals(listOf("stamp", "plan"), set.events)
        assertFalse(m.isPruning)                         // and the guard is released
    }

    @Test fun lrpOrderNeverPlayedFirstThenOldestThenDownloadedAtAndVariantReadsBase() = runTest {
        val items = listOf(
            item("sng_old", downloadedAt = 1.0),
            item("sng_new", downloadedAt = 2.0),
            item("sng_never_b", downloadedAt = 9.0),
            item("sng_never_a", downloadedAt = 3.0),
            item("sng_0123456789ab_clean", downloadedAt = 0.0),     // plays recorded against base "sng_v"
            item("sng_err", state = BurnState.ERROR),
        )
        val st = stats("sng_old" to 1_000L, "sng_new" to 9_000L, "sng_0123456789ab" to 5_000L)
        val b = FakeBurns(items)
        mgr(b, st, FakeSettings(songs = 1)).prune()
        assertEquals(listOf("sng_never_a", "sng_never_b", "sng_old", "sng_0123456789ab_clean", "sng_new"), b.lastOrder)
    }

    @Test fun capSongsOnlyEvictsDownToCountAndReportsArithmetic() = runTest {
        val items = (1..5).map { item("s$it", bytes = 100, downloadedAt = it.toDouble()) }
        val set = FakeSettings(songs = 2)
        val m = mgr(FakeBurns(items), stats(), set)
        val r = m.prune()!!
        assertEquals(3, r.evicted)
        assertEquals(300L, r.freedBytes); assertEquals(200L, r.usageBytes)
        assertEquals(2, r.usageSongs); assertEquals(2, r.capSongs); assertEquals(0L, r.capBytes)
        assertEquals(r, m.lastResult)
    }

    @Test fun byteCapUsesDecimalGigabytes() {
        assertEquals(ActiveCap(2_500_000_000L, null), resolveActiveCap(2.5, null))
        assertEquals(ActiveCap(null, 40), resolveActiveCap(null, 40))
        assertNull(resolveActiveCap(0.0, 0)); assertNull(resolveActiveCap(null, null))
    }

    @Test fun evictionRunsInChunksOf25AndRereadsProtectedPerChunk() = runTest {
        val items = (1..60).map { item("s%02d".format(it), downloadedAt = it.toDouble()) }
        val b = FakeBurns(items)
        var reads = 0
        // s27 is loaded onto a deck only AFTER the first chunk has been evicted: it must be spared.
        val m = mgr(b, stats(), FakeSettings(songs = 1), protect = {
            reads++
            if (b.removed.isNotEmpty()) setOf("s27") else emptySet()
        })
        val r = m.prune()!!
        assertEquals(listOf(25, 24, 9), b.removed.map { it.size })     // 25 | 25 minus spared s27 | 9
        assertFalse(b.removed.flatten().contains("s27"))
        assertEquals(58, r.evicted)
        assertTrue("protected re-read per chunk, reads=$reads", reads >= 4)    // 1 at plan + 3 chunks
    }

    @Test fun protectedSongsAreExcludedFromThePlanAtStart() = runTest {
        val b = FakeBurns(listOf(item("a", downloadedAt = 1.0), item("b", downloadedAt = 2.0)))
        mgr(b, stats(), FakeSettings(songs = 1), protect = { setOf("a") }).prune()
        assertEquals(listOf("b"), b.lastOrder)
    }

    @Test fun onlyOnePruneRunsAtATime() = runTest {
        val b = FakeBurns(listOf(item("a"), item("b")))
        val m = mgr(b, stats(), FakeSettings(songs = 1))
        var running = false
        b.onRemove = { running = m.isPruning }           // observed from inside the eviction
        assertEquals(1, m.prune()!!.evicted)
        assertTrue(running); assertFalse(m.isPruning)
    }
}

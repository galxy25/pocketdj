package com.levi.pocketdj.data.favorites

import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FavoritesStoreTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private var now = 1_000.0
    private fun file() = File(tmp.root, FavoritesStore.FILE_NAME)
    private fun store(f: File = file()) =
        FavoritesStore(f, writer = VersionedJsonWriter(f), clock = { now.also { now += 10 } })

    @Test
    fun tombstoneNotDeleted() {
        val s = store()
        s.toggle("a", "am1")
        assertTrue(s.isFavorite("a"))
        s.toggle("a", null)
        assertFalse(s.isFavorite("a"))
        val e = s.entry("a")
        assertNotNull(e)
        assertFalse(e!!.favorited)
        assertEquals("am1", e.appleMusicId) // known catalog id survives the unfavorite
        assertTrue(file().readText().contains("\"favorited\":false"))
    }

    @Test
    fun applyRemoteNewerLocalWins() {
        val s = store()
        s.set("a", true, null) // atMs 1000
        assertFalse(s.applyRemote("a", false, null, observedAtMs = 500.0))
        assertTrue(s.isFavorite("a"))
        assertTrue(s.applyRemote("a", false, "am9", observedAtMs = 5_000.0))
        assertFalse(s.isFavorite("a"))
        assertEquals("am9", s.entry("a")!!.appleMusicId)
        assertEquals(5_000.0, s.entry("a")!!.pushedAtMs!!, 0.0)
    }

    @Test
    fun seedOncePerVersionNeverOverExplicit() {
        val s = store()
        s.set("kept-off", false, null) // explicit tombstone
        s.set("kept-on", true, null)
        assertEquals(2, s.applySeed(listOf("kept-off", "kept-on", "x", "y"), mapOf("x" to "amx"), version = 1))
        assertFalse(s.isFavorite("kept-off"))
        assertTrue(s.isFavorite("x"))
        assertEquals("amx", s.entry("x")!!.appleMusicId)
        assertNotNull(s.entry("x")!!.pushedAtMs) // never owes an outbound push
        assertTrue(s.pendingPushes.none { it.songId == "x" })
        assertEquals(0, s.applySeed(listOf("z"), version = 1)) // same version: no-op
        assertFalse(s.isFavorite("z"))
        assertEquals(1, s.applySeed(listOf("z"), version = 2))
        assertEquals(2, s.seedVersion)
    }

    @Test
    fun onChangedOnlyUserToggles() {
        val s = store()
        val fired = mutableListOf<FavoriteEntry>()
        s.onChanged = { fired += it }
        s.toggle("a", null)
        s.set("a", true, null) // idempotent no-op
        assertEquals(1, fired.size)
        s.applyRemote("b", true, null, 9_000.0)
        s.applySeed(listOf("c"), version = 1)
        s.importMerging("""{"entries":[{"songId":"d","favorited":true,"atMs":1}]}""")
        s.remapSongIds(listOf("c" to "c2"))
        s.reloadFromDisk()
        assertEquals(1, fired.size)
        s.toggle("a", null)
        assertEquals(listOf(true, false), fired.map { it.favorited })
    }

    @Test
    fun importMergingKeepsNewerLocal() {
        val s = store()
        s.set("a", true, null) // atMs 1000
        val n = s.importMerging(
            """{"schemaVersion":1,"seedVersion":3,"entries":[
              {"songId":"a","favorited":false,"atMs":10},
              {"songId":"b","favorited":true,"atMs":10},
              {"songId":"c","favorited":false,"atMs":10}]}""",
        )
        assertEquals(2, n)
        assertTrue(s.isFavorite("a"))
        assertTrue(s.isFavorite("b"))
        assertFalse(s.entry("c")!!.favorited) // restored tombstone
        assertEquals(3, s.seedVersion)
        assertEquals(0, s.importMerging("not json"))
    }

    @Test
    fun remapMovesEntry() {
        val s = store()
        s.set("amrec_1", true, "am1")
        s.set("dest-touched", false, null)
        s.set("amrec_2", true, null)
        val rev = s.revision
        s.remapSongIds(listOf("amrec_1" to "real_1", "amrec_2" to "dest-touched"))
        assertTrue(s.revision > rev)
        assertNull(s.entry("amrec_1"))
        assertTrue(s.isFavorite("real_1"))
        assertEquals("real_1", s.entry("real_1")!!.songId)
        assertFalse(s.isFavorite("dest-touched")) // explicit destination wins
        assertFalse(s.isFavorite("amrec_2"))
    }

    @Test
    fun revisionBumpsOnEverySetMutation() {
        val s = store()
        var last = s.state.value.revision
        fun bumped(): Boolean = (s.state.value.revision > last).also { last = s.state.value.revision }
        s.set("a", true, null); assertTrue(bumped())
        s.applySeed(listOf("b"), version = 1); assertTrue(bumped())
        s.remapSongIds(listOf("b" to "b2")); assertTrue(bumped())
        s.reloadFromDisk(); assertTrue(bumped())
        assertEquals(setOf("a", "b2").sorted(), s.favoriteIds.sorted())
    }

    @Test
    fun coalescedSavesOneWrite() {
        val f = file()
        val w = VersionedJsonWriter(f)
        val s = FavoritesStore(f, writer = w, clock = { now++ })
        val before = w.writeCount
        s.withCoalescedSaves {
            repeat(50) { s.set("s$it", true, null) }
        }
        assertEquals(1, w.writeCount - before)
        assertEquals(50, s.favoriteIds.size)
        assertEquals(50, store(f).favoriteIds.size)
    }

    @Test
    fun docRoundTripKeepsAppleMusicIdAndPushedAt() {
        val f = file()
        f.writeText(
            """{"schemaVersion":1,"seedVersion":2,"futureKey":1,"entries":[
              {"songId":"a","favorited":true,"atMs":100.0,"appleMusicId":"am1","pushedAtMs":150.0},
              {"songId":"b","favorited":false,"atMs":200.0}]}""",
        )
        val s = store(f)
        assertEquals("am1", s.entry("a")!!.appleMusicId)
        assertEquals(150.0, s.entry("a")!!.pushedAtMs!!, 0.0)
        assertEquals(2, s.seedVersion)
        assertTrue(s.pendingPushes.isEmpty()) // a pushed; b has no AM id
        s.set("a", false, null)
        assertEquals(listOf("a"), s.pendingPushes.map { it.songId })
        val reread = store(f)
        assertEquals("am1", reread.entry("a")!!.appleMusicId)
        assertNull(reread.entry("a")!!.pushedAtMs)
        assertEquals(2, reread.seedVersion)
        assertTrue(s.exportData().contains("\"seedVersion\":2"))
    }

    @Test
    fun markPushedGuardedByToggleTimestamp() {
        val s = store()
        s.set("a", true, "am1") // atMs 1000
        s.markPushed("a", pushedAtMs = 900.0) // stale push finished before the toggle
        assertEquals(1, s.pendingPushes.size)
        s.markPushed("a", pushedAtMs = 2_000.0)
        assertTrue(s.pendingPushes.isEmpty())
    }

    @Test
    fun toggleTwiceInsideCoalescedBlockFlipsBack() {
        val s = store()
        s.withCoalescedSaves {
            s.toggle("a", null)
            assertTrue(s.isFavorite("a")) // not stale inside the block
            s.toggle("a", null)
            assertFalse(s.isFavorite("a"))
        }
        assertFalse(s.favoriteIds.contains("a"))
        assertFalse(s.entry("a")!!.favorited)
    }

    @Test
    fun onChangedFiresAfterLockReleasedForCoalescedToggles() {
        val s = store()
        val seen = ArrayList<Pair<String, Boolean>>()
        var lockFreeInHook = true
        s.onChanged = { e ->
            // A second thread can read (takes the store lock) only if the hook runs unlocked.
            val t = Thread { s.isFavorite("x") }
            t.start(); t.join(2_000)
            if (t.isAlive) lockFreeInHook = false
            seen.add(e.songId to e.favorited)
        }
        s.withCoalescedSaves {
            s.toggle("a", null)
            s.toggle("b", null)
            assertTrue(seen.isEmpty()) // queued, not fired under the lock
        }
        assertEquals(listOf("a" to true, "b" to true), seen)
        assertTrue(lockFreeInHook)
    }
}

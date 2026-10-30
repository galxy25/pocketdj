package com.levi.pocketdj.data.storage

import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.BurnStore
import com.levi.pocketdj.data.burns.Rig
import com.levi.pocketdj.data.burns.digital
import com.levi.pocketdj.data.stats.PlayStatsStore
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** SURF-2 soft cap end to end: real BurnStore + real planner + real files, only settings faked. */
class StorageSoftCapTest {
    private class Settings(val songs: Int? = null, val gb: Double? = null) : StorageSettingsPort {
        var last: Long? = null
        override suspend fun capGB() = gb
        override suspend fun capSongs() = songs
        override suspend fun lastPruneAt() = last
        override suspend fun stampPrune(nowMs: Long) { last = nowMs }
    }

    private fun adopt(r: Rig, store: BurnStore, id: String, size: Int) {
        r.rips.entries[id] = digital(id)
        val tmp = File(r.dir, "$id.tmp").apply { writeBytes(ByteArray(size)) }
        r.nowMs += 1000
        assertTrue(store.adoptStreamedFile(id, "T$id", "Artist", tmp) != null)
    }

    private fun stats() = PlayStatsStore(File(Files.createTempDirectory("pdj-sc").toFile(), "s.json"), nowMs = 0)

    @Test fun overCapPrunesLeastRecentlyPlayedAndDeletesFilesOnce() = runTest {
        val r = Rig(); val store = r.store()
        adopt(r, store, "a", 5_000); adopt(r, store, "b", 5_000); adopt(r, store, "c", 5_000)
        val st = stats().also { it.notePlayed("a", 9_000); it.notePlayed("b", 1_000) } // c never played -> first out
        val set = Settings(songs = 2)
        val m = StorageManager(BurnStorePruneAdapter(store), st, set, clock = { 123L })
        val res = m.prune()!!
        assertEquals(1, res.evicted)
        assertTrue("audio + sidecar freed, was ${res.freedBytes}", res.freedBytes >= 5_000L)
        assertEquals(setOf("a", "b"), store.items.value.keys)
        assertFalse(r.names().any { it.contains("c.mp3") || it.endsWith("-c.mp3") })
        assertFalse("sidecar left behind", r.names().any { it.contains("c.txt") })
        assertEquals(123L, set.last)
    }

    @Test fun protectedNowPlayingSongSurvivesEvenWhenOldest() = runTest {
        val r = Rig(); val store = r.store()
        adopt(r, store, "a", 4_000); adopt(r, store, "b", 4_000)
        val m = StorageManager(BurnStorePruneAdapter(store), stats(), Settings(songs = 1), protectedSongIds = { setOf("a") }, clock = { 1L })
        m.prune()
        assertEquals(setOf("a"), store.items.value.keys)
        assertEquals(BurnState.READY, store.items.value.getValue("a").state)
    }

    @Test fun underCapAndNoCapDeleteNothing() = runTest {
        val r = Rig(); val store = r.store()
        adopt(r, store, "a", 4_000); adopt(r, store, "b", 4_000)
        val under = StorageManager(BurnStorePruneAdapter(store), stats(), Settings(songs = 5), clock = { 1L }).prune()!!
        assertEquals(0, under.evicted)
        assertEquals(2, store.items.value.size)
        assertEquals(null, StorageManager(BurnStorePruneAdapter(store), stats(), Settings(), clock = { 1L }).prune())
        assertEquals(2, store.items.value.size)
    }
}

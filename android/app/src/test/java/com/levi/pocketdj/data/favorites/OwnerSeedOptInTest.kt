package com.levi.pocketdj.data.favorites

import com.levi.pocketdj.data.store.VersionedJsonWriter
import com.levi.pocketdj.data.applemusic.AmResult
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OwnerSeedOptInTest {
    @get:Rule val tmp = TemporaryFolder()

    private object NoRemote : FavoritesRemote {
        override suspend fun canSync() = true
        override suspend fun love(catalogId: String): AmResult<Unit> = error("no remote call expected")
        override suspend fun unlove(catalogId: String): AmResult<Unit> = error("no remote call expected")
        override suspend fun star(catalogIds: List<String>): AmResult<Unit> = error("no remote call expected")
        override suspend fun lovedIds(catalogIds: List<String>): AmResult<Set<String>> = error("no remote call expected")
    }

    private fun store(): FavoritesStore {
        val f = File(tmp.root, FavoritesStore.FILE_NAME)
        return FavoritesStore(f, writer = VersionedJsonWriter(f))
    }

    private var fetches = 0
    private fun svc(s: FavoritesStore, optIn: Boolean, body: String) = FavoritesSyncService(
        s, NoRemote, twoWayEnabled = { false }, seedOptIn = { optIn },
        catalogPairs = { emptyList() }, fetchSeed = { fetches++; body },
    )

    private val seedV1 = """{"version":1,"songIds":["a","b"],"appleMusicIds":{"a":"am1"},"unknown":true}"""

    @Test fun defaultsAreOff() {
        assertFalse(FavoritesSyncSettings.TWO_WAY.default)
        assertFalse(FavoritesSyncSettings.APPLY_OWNER_SEED.default)
        assertEquals("favoritesTwoWaySync", FavoritesSyncSettings.TWO_WAY.name)
        assertEquals("applyOwnerFavoritesSeed", FavoritesSyncSettings.APPLY_OWNER_SEED.name)
    }

    @Test fun optOutNeverFetchesOrSeeds() = runTest {
        val s = store()
        svc(s, optIn = false, body = seedV1).run()
        assertEquals(0, fetches)
        assertTrue(s.favoriteIds.isEmpty())
    }

    @Test fun seedOptInOncePerVersion() = runTest {
        val s = store()
        val svc = svc(s, true, seedV1)
        svc.run()
        assertEquals(setOf("a", "b"), s.favoriteIds)
        assertEquals(1, s.seedVersion)
        assertTrue(s.pendingPushes.isEmpty()) // seeded rows never generate outbound writes
        s.set("a", false, null) // user un-hearts a seeded song
        svc.run() // same version again: must not resurrect it
        assertFalse(s.isFavorite("a"))
        svc(s, true, """{"version":2,"songIds":["a","c"]}""").run()
        assertFalse(s.isFavorite("a")) // touched songs are never overwritten
        assertTrue(s.isFavorite("c"))
        assertEquals(2, s.seedVersion)
    }

    @Test fun garbageSeedIsIgnored() = runTest {
        val s = store()
        svc(s, true, "<html>").run()
        assertTrue(s.favoriteIds.isEmpty())
        assertEquals(0, s.seedVersion)
    }
}

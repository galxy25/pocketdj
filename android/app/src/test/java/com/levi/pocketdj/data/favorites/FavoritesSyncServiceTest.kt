package com.levi.pocketdj.data.favorites

import com.levi.pocketdj.data.applemusic.AppleMusicApi
import com.levi.pocketdj.data.applemusic.StaticAppleMusicTokens
import com.levi.pocketdj.data.store.VersionedJsonWriter
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FavoritesSyncServiceTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private var ratingsBody = """{"data":[]}"""
    private var ratingPutStatus = 200
    private var now = 1_000.0
    private var failPutPath: String? = null
    private var deleteStatus = 204
    private var failFirstStar = false
    private var starPosts = 0

    @Before fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when {
                request.method == "GET" -> MockResponse().setResponseCode(200).setBody(ratingsBody)
                request.method == "PUT" -> MockResponse().setResponseCode(
                    if (failPutPath != null && request.path == failPutPath) 400 else ratingPutStatus,
                ).setBody("{}")
                request.method == "DELETE" -> MockResponse().setResponseCode(deleteStatus)
                else -> MockResponse().setResponseCode(if (failFirstStar && starPosts++ == 0) 500 else 202)
            }
        }
        server.start()
    }

    @After fun tearDown() { server.shutdown() }

    private fun store(): FavoritesStore {
        val f = File(tmp.root, FavoritesStore.FILE_NAME)
        return FavoritesStore(f, writer = VersionedJsonWriter(f), clock = { now.also { now += 10 } })
    }

    private fun service(
        s: FavoritesStore,
        twoWay: Boolean = true,
        pairs: List<Pair<String, String>> = emptyList(),
        user: String? = "mut",
        seedOpt: Boolean = false,
        seed: String = "{}",
        ready: () -> Boolean = { true },
        cursor: IntArray = intArrayOf(0),
    ): FavoritesSyncService {
        val tokens = StaticAppleMusicTokens("dev", user)
        val api = AppleMusicApi(
            OkHttpClient(), tokens,
            baseUrl = server.url("/").toString().trimEnd('/'), sleeper = {},
        )
        return FavoritesSyncService(
            s, ApiFavoritesRemote(api, tokens),
            twoWayEnabled = { twoWay }, seedOptIn = { seedOpt },
            catalogPairs = { pairs }, fetchSeed = { seed }, clock = { 50_000.0 }, ready = ready,
            loadCursor = { cursor[0] }, saveCursor = { cursor[0] = it },
        )
    }

    private var taken = 0
    private fun requests(): List<RecordedRequest> = (taken until server.requestCount).map { server.takeRequest() }.also { taken = server.requestCount }

    @Test fun optOutNoCalls() = runTest {
        val s = store()
        s.set("a", true, "am1")
        service(s, twoWay = false, pairs = listOf("a" to "am1")).run()
        assertEquals(0, server.requestCount)
        assertEquals(1, s.pendingPushes.size) // still owed
    }

    @Test fun signedOutNoCalls() = runTest {
        val s = store()
        s.set("a", true, "am1")
        service(s, user = null).run()
        assertEquals(0, server.requestCount)
    }

    @Test fun pushMarksPushedFavoritePutsRatingAndStarsTypeScoped() = runTest {
        val s = store()
        s.set("a", true, "am1")
        s.set("b", true, "am2")
        service(s).run()
        val reqs = requests()
        val star = reqs.single { it.method == "POST" }
        assertTrue(star.path!!, star.path!!.startsWith("/v1/me/favorites?ids%5Bsongs%5D=am1%2Cam2"))
        assertFalse(reqs.any { it.path!!.contains("?ids=") && it.method == "POST" }) // never a bare ids=
        assertEquals(listOf("/v1/me/ratings/songs/am1", "/v1/me/ratings/songs/am2"),
            reqs.filter { it.method == "PUT" }.map { it.path })
        assertTrue(s.pendingPushes.isEmpty())
        assertNotNull(s.entry("a")!!.pushedAtMs)
    }

    @Test fun unfavoriteOnlyDeletesRating() = runTest {
        val s = store()
        s.set("a", true, "am1")
        service(s).run()
        requests()
        s.set("a", false, null)
        service(s).run()
        val reqs = requests()
        assertEquals(listOf("DELETE"), reqs.map { it.method })
        assertEquals("/v1/me/ratings/songs/am1", reqs.single().path)
        assertTrue(s.pendingPushes.isEmpty())
    }

    @Test fun failedStaysPending() = runTest {
        val s = store()
        s.set("a", true, "am1")
        ratingPutStatus = 500
        val svc = service(s)
        svc.run()
        assertEquals(1, s.pendingPushes.size)
        assertNotNull(svc.state.value.lastError)
        ratingPutStatus = 200
        requests()
        svc.run()
        assertTrue(s.pendingPushes.isEmpty())
        assertNull(svc.state.value.lastError)
    }

    @Test fun pullAdoptsLovedAndMapsBackToSongIds() = runTest {
        val s = store()
        ratingsBody = """{"data":[{"id":"am1","attributes":{"value":1}}]}"""
        service(s, pairs = listOf("songA" to "am1", "songB" to "am2")).run()
        assertTrue(s.isFavorite("songA"))
        assertNull(s.entry("songB")) // untouched + not loved => not tombstoned
        assertTrue(s.pendingPushes.isEmpty()) // adopted rows are marked pushed
    }

    @Test fun pullTombstonesLocalFavoriteMissingUpstream() = runTest {
        val s = store()
        s.set("songA", true, "am1")
        s.markPushed("songA", s.entry("songA")!!.atMs)
        now = 100_000.0 // keep later local edits out of the way; observedAt is 50_000
        ratingsBody = """{"data":[]}"""
        service(s, pairs = listOf("songA" to "am1")).run()
        assertFalse(s.isFavorite("songA"))
        assertFalse(s.entry("songA")!!.favorited)
    }

    @Test fun pullNewerLocalWins() = runTest {
        val s = store()
        now = 90_000.0 // local toggle newer than observedAt (50_000)
        s.set("songA", false, "am1")
        s.set("songA", true, "am1")
        ratingsBody = """{"data":[]}""" // upstream says not loved
        service(s, pairs = listOf("songA" to "am1")).run()
        assertTrue(s.isFavorite("songA"))
    }

    @Test fun unreadablePullBodyAbortsAndDoesNotTombstone() = runTest {
        val s = store()
        s.set("songA", true, "am1")
        s.markPushed("songA", s.entry("songA")!!.atMs)
        now = 100_000.0
        ratingsBody = "<html>oops</html>"
        val svc = service(s, pairs = listOf("songA" to "am1"))
        svc.run()
        assertTrue(s.isFavorite("songA"))
        assertNotNull(svc.state.value.lastError)
    }

    @Test fun singleFlight() = runTest {
        val s = store()
        s.set("a", true, "am1")
        val gate = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        val slow = object : FavoritesRemote {
            var loves = 0
            override suspend fun canSync(): Boolean { entered.complete(Unit); gate.await(); return true }
            override suspend fun love(catalogId: String): com.levi.pocketdj.data.applemusic.AmResult<Unit> {
                loves++; return com.levi.pocketdj.data.applemusic.AmResult.Ok(Unit)
            }
            override suspend fun unlove(catalogId: String) = com.levi.pocketdj.data.applemusic.AmResult.Ok(Unit)
            override suspend fun star(catalogIds: List<String>) = com.levi.pocketdj.data.applemusic.AmResult.Ok(Unit)
            override suspend fun lovedIds(catalogIds: List<String>) =
                com.levi.pocketdj.data.applemusic.AmResult.Ok(emptySet<String>())
        }
        val svc = FavoritesSyncService(s, slow, { true }, { false }, { emptyList() }, { "{}" })
        val first = async { svc.run() }
        entered.await()
        assertTrue(svc.state.value.isSyncing)
        svc.run() // overlapping pass returns immediately
        gate.complete(Unit)
        first.await()
        assertEquals(1, slow.loves)
        assertFalse(svc.state.value.isSyncing)
    }

    @Test fun pushNowOptOutOrNoAmIdIsNoop() = runTest {
        val s = store()
        s.set("a", true, null)
        service(s).pushNow(s.entry("a")!!) // no AM id
        s.set("b", true, "am2")
        service(s, twoWay = false).pushNow(s.entry("b")!!)
        assertEquals(0, server.requestCount)
        service(s).pushNow(s.entry("b")!!)
        assertTrue(server.requestCount >= 1)
        assertNull(s.pendingPushes.firstOrNull { it.songId == "b" })
    }

    @Test fun exportSeedOnlyAppleMusicFavorites() {
        val s = store()
        s.set("a", true, "am1"); s.set("v", true, null); s.set("t", false, "am3")
        val seed = service(s).exportSeed(4)
        assertEquals(listOf("a"), seed.songIds)
        assertEquals(mapOf("a" to "am1"), seed.appleMusicIds)
        assertEquals(4, seed.version)
    }

    @Test fun runIfReadyNotReadyMakesNoRequestsAndNoStamp() = runTest {
        val s = store()
        s.set("a", true, "am1")
        var ready = false
        val svc = service(s, pairs = listOf("a" to "am1"), ready = { ready })
        svc.runIfReady()
        assertEquals(0, server.requestCount)
        assertNull(svc.state.value.lastSyncedAtMs)
        ready = true
        svc.runIfReady()
        assertTrue(server.requestCount > 0)
        assertNotNull(svc.state.value.lastSyncedAtMs)
    }

    @Test fun emptyCatalogPullDoesNotStampLastSynced() = runTest {
        val s = store()
        val svc = service(s, pairs = emptyList())
        svc.run()
        assertNull(svc.state.value.lastSyncedAtMs)
    }

    @Test fun delete404CountsAsPushed() = runTest {
        val s = store()
        s.set("a", true, "am1"); s.set("a", false, "am1")
        deleteStatus = 404
        val svc = service(s)
        svc.run()
        assertTrue(s.pendingPushes.isEmpty())
        assertNull(svc.state.value.lastError)
    }

    @Test fun oneRejectedEntryDoesNotBlockTheQueue() = runTest {
        val s = store()
        s.set("bad", true, "amBad"); s.set("good", true, "amGood")
        failPutPath = "/v1/me/ratings/songs/amBad"
        val svc = service(s)
        svc.run()
        assertEquals(listOf("bad"), s.pendingPushes.map { it.songId })
        assertNotNull(svc.state.value.lastError)
    }

    @Test fun failedStarChunkDoesNotSkipLaterChunks() = runTest {
        val s = store()
        for (i in 1..260) s.set("s$i", true, "am$i")
        failFirstStar = true
        service(s).run()
        assertEquals(2, starPosts)
        assertTrue(s.pendingPushes.isEmpty())
    }

    private fun bigCatalog(n: Int) = (0 until n).map { "s%05d".format(it) to "am%05d".format(it) }
    private fun gets() = requests().filter { it.method == "GET" }

    @Test fun pullPagesTwentyBatchesAndAdvancesCursor() = runTest {
        val cursor = intArrayOf(0)
        val pairs = bigCatalog(12_000)
        service(store(), pairs = pairs, cursor = cursor).run()
        assertEquals(20, gets().size)
        assertEquals(5_000, cursor[0])
    }

    @Test fun cursorWrapsAtEndOfCatalog() = runTest {
        val cursor = intArrayOf(10_000)
        val pairs = bigCatalog(12_000)
        val svc = service(store(), pairs = pairs, cursor = cursor)
        svc.run()
        assertEquals(8, gets().size) // 2000 ids = 8 batches
        assertEquals(0, cursor[0])
        assertEquals(12_000, svc.state.value.pullDone)
        assertEquals(12_000, svc.state.value.pullTotal)
    }

    @Test fun locallyHeartedAlwaysIncludedOutsidePage() = runTest {
        val s = store()
        s.set("s11999", true, "am11999")
        s.markPushed("s11999", s.entry("s11999")!!.atMs)
        val pairs = bigCatalog(12_000)
        service(s, pairs = pairs, cursor = intArrayOf(0)).run()
        val ids = gets().joinToString(",") { java.net.URLDecoder.decode(it.path!!, "UTF-8") }
        assertTrue(ids.contains("am11999"))
        assertFalse(ids.contains("am07000"))
    }

    @Test fun rateLimitedPageDoesNotAdvanceCursor() = runTest {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(429).setHeader("Retry-After", "0")
        }
        val cursor = intArrayOf(5_000)
        val svc = service(store(), pairs = bigCatalog(12_000), cursor = cursor)
        svc.run()
        assertEquals(5_000, cursor[0])
        assertNotNull(svc.state.value.lastError)
        assertNull(svc.state.value.lastSyncedAtMs)
    }

    @Test fun pageOnlyReconcile_offPageLoveNotTouched() = runTest {
        ratingsBody = """{"data":[{"id":"am11000","type":"ratings","attributes":{"value":1}}]}"""
        val s = store()
        service(s, pairs = bigCatalog(12_000), cursor = intArrayOf(0)).run()
        assertNull(s.entry("s11000")) // off-page: untouched this pass
    }
}

package com.levi.pocketdj.data.applemusic

import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AppleMusicApiTest {
    private lateinit var server: MockWebServer
    private val sleeps = mutableListOf<Long>()

    @Before fun setUp() { server = MockWebServer().also { it.start() } }
    @After fun tearDown() { server.shutdown() }

    private fun api(user: String? = "mut-1") = AppleMusicApi(
        OkHttpClient(), StaticAppleMusicTokens("dev-1", user),
        baseUrl = server.url("/").toString().trimEnd('/'),
        sleeper = { sleeps += it },
    )

    private fun ok(body: String) = MockResponse().setResponseCode(200).setBody(body)

    // ---- catalog search ----
    @Test fun searchRequestShapeAndHeaders() = runTest {
        server.enqueue(ok("""{"results":{"songs":{"data":[{"id":"1","attributes":{"name":"A","artistName":"B","durationInMillis":180000}}],"next":"/v1/catalog/us/search?offset=10"}}}"""))
        val r = api().searchCatalog("daft punk", setOf(AmSearchType.SONGS, AmSearchType.ALBUMS), limit = 10)
        val req = server.takeRequest()
        assertEquals("GET", req.method)
        assertEquals("/v1/catalog/us/search?types=albums%2Csongs&term=daft%20punk&limit=10", req.path)
        assertEquals("Bearer dev-1", req.getHeader("Authorization"))
        assertEquals("mut-1", req.getHeader("Music-User-Token"))
        val v = (r as AmResult.Ok).value
        assertEquals("A", v.songs.items.single().title)
        assertEquals(10, v.songs.nextOffset)
    }

    @Test fun userTokenHeaderOmittedWhenSignedOutAndCatalogStillWorks() = runTest {
        server.enqueue(ok("""{"results":{}}"""))
        assertTrue(api(user = null).searchCatalog("x") is AmResult.Ok)
        assertNull(server.takeRequest().getHeader("Music-User-Token"))
    }

    @Test fun search429BacksOffThenSucceeds() = runTest {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "3"))
        server.enqueue(MockResponse().setResponseCode(429))
        server.enqueue(ok("""{"results":{}}"""))
        assertTrue(api().searchCatalog("x") is AmResult.Ok)
        assertEquals(listOf(3000L, 2000L), sleeps)
        assertEquals(3, server.requestCount)
    }

    @Test fun search429ExhaustedIsRateLimited() = runTest {
        repeat(4) { server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "2")) }
        val r = api().searchCatalog("x")
        assertEquals(AmResult.RateLimited(2L), r)
        assertEquals(4, server.requestCount)
    }

    @Test fun catalog401IsFailureNotNeedsUserToken() = runTest {
        server.enqueue(MockResponse().setResponseCode(401))
        val r = api().searchCatalog("x")
        assertEquals(401, (r as AmResult.Failure).status)
    }

    // ---- library playlists ----
    @Test fun libraryPlaylistsWithoutMutDoesNoNetwork() = runTest {
        assertEquals(AmResult.NeedsUserToken, api(user = null).libraryPlaylists())
        assertEquals(0, server.requestCount)
    }

    @Test fun libraryPlaylists401IsNeedsUserToken() = runTest {
        server.enqueue(MockResponse().setResponseCode(403))
        assertEquals(AmResult.NeedsUserToken, api().libraryPlaylists())
    }

    @Test fun libraryPlaylists429() = runTest {
        repeat(4) { server.enqueue(MockResponse().setResponseCode(429)) }
        assertTrue(api().libraryPlaylists() is AmResult.RateLimited)
        assertEquals(listOf(1000L, 2000L, 4000L), sleeps)
    }

    @Test fun allLibraryPlaylistsPagesViaNextCursor() = runTest {
        server.enqueue(ok("""{"data":[{"id":"p.1","attributes":{"name":"One"}}],"next":"/v1/me/library/playlists?offset=1&limit=1"}"""))
        server.enqueue(ok("""{"data":[{"id":"p.2","attributes":{"name":"Two","canEdit":false}}]}"""))
        val r = api().allLibraryPlaylists(pageSize = 1) as AmResult.Ok
        assertEquals(listOf("p.1", "p.2"), r.value.map { it.id })
        assertTrue(r.value[0].canEdit)
        assertEquals("/v1/me/library/playlists?limit=1&offset=0", server.takeRequest().path)
        assertEquals("/v1/me/library/playlists?limit=1&offset=1", server.takeRequest().path)
    }

    @Test fun playlistTracksParsesCatalogIdsAndPaging() = runTest {
        server.enqueue(ok("""{"data":[{"attributes":{"playParams":{"catalogId":"c1","id":"i.1"}}},{"attributes":{}}],"next":"/x?offset=100"}"""))
        val p = (api().playlistTracks("p.a/b", offset = 0) as AmResult.Ok).value
        assertEquals(listOf("c1"), p.catalogIds)
        assertEquals(2, p.rowCount)
        assertEquals(100, p.nextOffset)
        // opaque id is escaped, never splices a segment
        assertEquals("/v1/me/library/playlists/p.a%2Fb/tracks?limit=100&offset=0", server.takeRequest().path)
    }

    @Test fun createPlaylistBodyAndId() = runTest {
        server.enqueue(MockResponse().setResponseCode(201).setBody("""{"data":[{"id":"p.new"}]}"""))
        val r = api().createPlaylist("Mix", "d", listOf("1", "2"))
        assertEquals("p.new", (r as AmResult.Ok).value)
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/v1/me/library/playlists", req.path)
        val b = req.body.readUtf8()
        assertTrue(b, b.contains(""""name":"Mix"""") && b.contains(""""id":"1","type":"songs""""))
    }

    @Test fun addTracksNoContentIsOk() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        assertTrue(api().addTracksToPlaylist("p.1", listOf("9")) is AmResult.Ok)
        val req = server.takeRequest()
        assertEquals("/v1/me/library/playlists/p.1/tracks", req.path)
        assertEquals("""{"data":[{"id":"9","type":"songs"}]}""", req.body.readUtf8())
    }

    @Test fun addTracksEmptyMakesNoRequest() = runTest {
        assertTrue(api().addTracksToPlaylist("p.1", emptyList()) is AmResult.Ok)
        assertEquals(0, server.requestCount)
    }

    @Test fun removeTracksRequestShapeAndErrorMapping() = runTest {
        server.enqueue(MockResponse().setResponseCode(405))
        val r = api().removeTracksFromPlaylist("p.1", listOf("i.1", "i.2"))
        assertEquals(405, (r as AmResult.Failure).status)
        val req = server.takeRequest()
        assertEquals("DELETE", req.method)
        assertEquals("/v1/me/library/playlists/p.1/tracks?ids%5Blibrary-songs%5D=i.1%2Ci.2", req.path)
    }

    @Test fun addToLibraryAlbums() = runTest {
        server.enqueue(MockResponse().setResponseCode(202))
        assertTrue(api().addToLibrary(AmLibraryKind.ALBUMS, listOf("a1", "a2")) is AmResult.Ok)
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/v1/me/library?ids%5Balbums%5D=a1%2Ca2", req.path)
    }

    // ---- favorites ----
    @Test fun rateAndUnrate() = runTest {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{}"))
        server.enqueue(MockResponse().setResponseCode(204))
        val a = api()
        assertTrue(a.rateSong("77") is AmResult.Ok)
        assertTrue(a.unrateSong("77") is AmResult.Ok)
        val put = server.takeRequest()
        assertEquals("PUT", put.method)
        assertEquals("/v1/me/ratings/songs/77", put.path)
        assertEquals("""{"type":"rating","attributes":{"value":1}}""", put.body.readUtf8())
        assertEquals("DELETE", server.takeRequest().method)
    }

    @Test fun rate401NeedsUserToken() = runTest {
        server.enqueue(MockResponse().setResponseCode(401))
        assertEquals(AmResult.NeedsUserToken, api().rateSong("1"))
    }

    @Test fun starSongsChunksAndTypeScopesIds() = runTest {
        server.enqueue(MockResponse().setResponseCode(202))
        server.enqueue(MockResponse().setResponseCode(202))
        val ids = (1..251).map { "s$it" }
        assertTrue(api().starSongs(ids) is AmResult.Ok)
        val first = server.takeRequest()
        assertTrue(first.path!!.startsWith("/v1/me/favorites?ids%5Bsongs%5D=s1%2Cs2"))
        assertEquals("POST", first.method)
        assertEquals(2, server.requestCount)
    }

    @Test fun starSongs429StopsAfterBackoff() = runTest {
        repeat(4) { server.enqueue(MockResponse().setResponseCode(429)) }
        assertTrue(api().starSongs(listOf("a")) is AmResult.RateLimited)
    }

    @Test fun lovedIdsKeepsOnlyValueOne() = runTest {
        server.enqueue(ok("""{"data":[{"id":"1","attributes":{"value":1}},{"id":"2","attributes":{"value":-1}},{"id":"3"}]}"""))
        val r = api().lovedSongIds(listOf("1", "2", "3", "4")) as AmResult.Ok
        assertEquals(setOf("1"), r.value)
        assertEquals("/v1/me/ratings/songs?ids=1%2C2%2C3%2C4", server.takeRequest().path)
    }

    @Test fun lovedIdsUnreadableBodyIsFailureNotEmptySet() = runTest {
        server.enqueue(ok("<html>oops</html>"))
        assertTrue(api().lovedSongIds(listOf("1")) is AmResult.Failure)
    }

    // ---- artists ----
    @Test fun artistsLatestReleaseRequestAndParse() = runTest {
        server.enqueue(ok("""{"data":[{"id":"5","attributes":{"name":"Art"},"views":{"latest-release":{"data":[{"id":"al1","attributes":{"name":"New","releaseDate":"2026-10-01"}}]},"similar-artists":{"data":[{"id":"6"}]}}}]}"""))
        val r = api(user = null).artistsLatestRelease(listOf("5")) as AmResult.Ok
        assertEquals("New", r.value.single().latestRelease?.title)
        assertEquals(listOf("6"), r.value.single().similarArtistIds)
        assertEquals("/v1/catalog/us/artists?ids=5&views=latest-release%2Csimilar-artists", server.takeRequest().path)
    }

    @Test fun artistsErrorEnvelopeIsFailure() = runTest {
        server.enqueue(ok("""{"errors":[{"status":"500"}]}"""))
        assertTrue(api().artistsLatestRelease(listOf("5")) is AmResult.Failure)
    }

    @Test fun storefrontAndNetworkFailure() = runTest {
        server.enqueue(ok("""{"data":[{"id":"gb"}]}"""))
        assertEquals("gb", api().userStorefront().getOrNull())
        server.shutdown()
        assertTrue(api().userStorefront() is AmResult.Failure)
    }

    @Test fun backoffPolicy() {
        assertEquals(1000L, AppleMusicApi.backoffMs(0, null))
        assertEquals(30000L, AppleMusicApi.backoffMs(9, null))
        assertEquals(60000L, AppleMusicApi.backoffMs(0, 500))
        assertEquals(listOf(listOf("a", "b"), listOf("c")), AppleMusicApi.batches(listOf("a", "b", "c"), 2))
    }

    // ---- review fixes ----
    @Test fun playlistTracks404IsEmptyPage() = runTest {
        server.enqueue(MockResponse().setResponseCode(404))
        val p = (api().playlistTracks("p.new") as AmResult.Ok).value
        assertEquals(emptyList<String>(), p.catalogIds)
        assertEquals(0, p.rowCount)
        assertEquals(false, p.hasNext)
    }

    @Test fun allPlaylistTrackIdsEmptyPlaylist404() = runTest {
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(emptyList<String>(), (api().allPlaylistTrackCatalogIds("p") as AmResult.Ok).value)
    }

    @Test fun allPlaylistTrackIdsWalksUntilShortPage() = runTest {
        server.enqueue(ok("""{"data":[{"attributes":{"playParams":{"catalogId":"a"}}},{"attributes":{"playParams":{"catalogId":"b"}}}],"next":"/x?offset=2"}"""))
        server.enqueue(ok("""{"data":[{"attributes":{"playParams":{"catalogId":"c"}}}]}"""))
        val r = api().allPlaylistTrackCatalogIds("p", pageSize = 2) as AmResult.Ok
        assertEquals(listOf("a", "b", "c"), r.value)
        assertEquals(2, server.requestCount)
    }

    @Test fun allPlaylistTrackIdsFullPageUnparsableNextStillAdvances() = runTest {
        server.enqueue(ok("""{"data":[{"attributes":{"playParams":{"catalogId":"a"}}},{"attributes":{"playParams":{"catalogId":"b"}}}],"next":"cursor-xyz"}"""))
        server.enqueue(ok("""{"data":[]}"""))
        val r = api().allPlaylistTrackCatalogIds("p", pageSize = 2) as AmResult.Ok
        assertEquals(listOf("a", "b"), r.value)
        assertEquals("/v1/me/library/playlists/p/tracks?limit=2&offset=2", server.takeRequest().let { server.takeRequest() }.path)
    }

    @Test fun allLibraryPlaylistsUnparsableNextFallsBackToOffset() = runTest {
        server.enqueue(ok("""{"data":[{"id":"1"},{"id":"2"}],"next":"opaque"}"""))
        server.enqueue(ok("""{"data":[{"id":"3"}]}"""))
        val r = api().allLibraryPlaylists(pageSize = 2) as AmResult.Ok
        assertEquals(3, r.value.size)
    }

    @Test fun artistsBatchedAt50NeverDropsIds() = runTest {
        server.enqueue(ok("""{"data":[{"id":"a1","attributes":{"name":"A"}}]}"""))
        server.enqueue(ok("""{"data":[{"id":"a2","attributes":{"name":"B"}}]}"""))
        val r = api(user = null).artistsLatestRelease((1..60).map { "x$it" }) as AmResult.Ok
        assertEquals(2, r.value.size)
        assertEquals(2, server.requestCount)
    }

    @Test fun artistsBatchFailureFailsWholeCall() = runTest {
        server.enqueue(ok("""{"data":[]}"""))
        server.enqueue(MockResponse().setResponseCode(500))
        assertTrue(api(user = null).artistsLatestRelease((1..60).map { "x$it" }) is AmResult.Failure)
    }

    @Test fun largeRetryAfterBeyondBudgetReturnsRateLimitedImmediately() = runTest {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "120"))
        assertEquals(AmResult.RateLimited(120L), api().rateSong("1"))
        assertEquals(1, server.requestCount)
        assertTrue(sleeps.isEmpty())
    }

    @Test fun corruptTokenDoesNotThrow() = runTest {
        val a = AppleMusicApi(OkHttpClient(), StaticAppleMusicTokens("dev\u00e9\nx", "mut"), baseUrl = server.url("/").toString().trimEnd('/'))
        assertEquals(AmResult.NeedsUserToken, a.libraryPlaylists())
    }

    @Test fun invalidatesDeveloperTokenOn401() = runTest {
        var invalidated = 0
        val t = object : AppleMusicTokens {
            override suspend fun developerToken() = "d"
            override suspend fun musicUserToken(): String? = null
            override suspend fun invalidateDeveloperToken() { invalidated++ }
        }
        server.enqueue(MockResponse().setResponseCode(401))
        AppleMusicApi(OkHttpClient(), t, baseUrl = server.url("/").toString().trimEnd('/')).searchCatalog("x")
        assertEquals(1, invalidated)
    }

    // ---- 401 / 429 over every user-scoped endpoint ----
    private val userCalls: List<Pair<String, suspend (AppleMusicApi) -> AmResult<*>>> = listOf(
        "userStorefront" to { a -> a.userStorefront() },
        "libraryPlaylists" to { a -> a.libraryPlaylists() },
        "allLibraryPlaylists" to { a -> a.allLibraryPlaylists() },
        "playlistTracks" to { a -> a.playlistTracks("p") },
        "allPlaylistTrackCatalogIds" to { a -> a.allPlaylistTrackCatalogIds("p") },
        "createPlaylist" to { a -> a.createPlaylist("n") },
        "addTracksToPlaylist" to { a -> a.addTracksToPlaylist("p", listOf("1")) },
        "removeTracksFromPlaylist" to { a -> a.removeTracksFromPlaylist("p", listOf("1")) },
        "addToLibrary" to { a -> a.addToLibrary(AmLibraryKind.SONGS, listOf("1")) },
        "rateSong" to { a -> a.rateSong("1") },
        "unrateSong" to { a -> a.unrateSong("1") },
        "starSongs" to { a -> a.starSongs(listOf("1")) },
        "lovedSongIds" to { a -> a.lovedSongIds(listOf("1")) },
    )

    @Test fun everyUserEndpoint401IsNeedsUserToken() = runTest {
        for ((name, call) in userCalls) {
            server.enqueue(MockResponse().setResponseCode(401))
            assertEquals(name, AmResult.NeedsUserToken, call(api()))
        }
    }

    @Test fun everyUserEndpoint429IsRateLimited() = runTest {
        for ((name, call) in userCalls) {
            repeat(4) { server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "1")) }
            assertTrue(name, call(api()) is AmResult.RateLimited)
        }
    }

    @Test fun everyUserEndpointWithoutMutDoesNoNetwork() = runTest {
        for ((name, call) in userCalls) assertEquals(name, AmResult.NeedsUserToken, call(api(user = null)))
        assertEquals(0, server.requestCount)
    }

    @Test fun catalogEndpoints401And429() = runTest {
        server.enqueue(MockResponse().setResponseCode(401))
        assertEquals(401, ((api().artistsLatestRelease(listOf("1"))) as AmResult.Failure).status)
        repeat(4) { server.enqueue(MockResponse().setResponseCode(429)) }
        assertTrue(api().artistsLatestRelease(listOf("1")) is AmResult.RateLimited)
    }
}

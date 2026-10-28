package com.levi.pocketdj.data.rips

import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Rip-server protocol details that are easy to get wrong (specs/playback.md §4):
 * the Authorization header is OMITTED entirely for an empty token (a tokened
 * server 401s a bare "Bearer "), X-PocketDJ-Device always rides, and studio ids
 * never reach the network.
 */
class RipServerClientTest {

    private lateinit var server: MockWebServer
    private var token: String = ""

    private fun client(): RipServerClient = RipServerClient(
        http = OkHttpClient(),
        configProvider = {
            RipServerClient.Config(
                baseUrl = server.url("/").toString(),
                token = token,
                installId = "device-uuid-1234",
            )
        },
    )

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        token = ""
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun emptyToken_omitsAuthorizationHeaderEntirely() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true,"version":2}"""))
        client().health()
        val request = server.takeRequest()
        assertNull(request.getHeader("Authorization"))
        assertEquals("device-uuid-1234", request.getHeader("X-PocketDJ-Device"))
        // No profiles on Android P1 — the profile header must be absent too.
        assertNull(request.getHeader("X-PocketDJ-Profile"))
    }

    @Test
    fun nonEmptyToken_sendsBearer() = runTest {
        token = "sekrit"
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        client().health()
        assertEquals("Bearer sekrit", server.takeRequest().getHeader("Authorization"))
    }

    @Test
    fun requestRip_postsSongId_andDecodesJobView() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"jobId":"job_1","songId":"sng_x","phase":"queued","message":null,"unknown":1}""",
            ),
        )
        val job = client().requestRip("sng_x")
        assertEquals("job_1", job.jobId)
        assertEquals("queued", job.phase)
        val request = server.takeRequest()
        assertEquals("/rip", request.path)
        assertTrue(request.body.readUtf8().contains("\"songId\":\"sng_x\""))
    }

    @Test
    fun studioIds_neverReachTheNetwork() = runTest {
        val result = runCatching { client().requestRip("smp_localSample") }
        assertTrue(result.exceptionOrNull() is IllegalArgumentException)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun unauthorized_pointsAtSettingsToken() = runTest {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"unauthorized"}"""))
        val error = runCatching { client().health() }.exceptionOrNull() as RipServerClient.RipServerException
        assertEquals(401, error.code)
        assertTrue(error.message!!.contains("Settings"))
    }

    @Test
    fun unconfiguredServer_failsFast_withIosErrorShape() = runTest {
        val bare = RipServerClient(
            http = OkHttpClient(),
            configProvider = { RipServerClient.Config(baseUrl = "  ", token = "", installId = "x") },
        )
        val error = runCatching { bare.health() }.exceptionOrNull() as RipServerClient.RipServerException
        assertTrue(error.message!!.contains("No import server configured"))
    }

    // ---- SVC-1 ----

    private fun alwaysDispatcher(body: String, code: Int = 200) = object : okhttp3.mockwebserver.Dispatcher() {
        override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest) =
            MockResponse().setResponseCode(code).setBody(body)
    }

    @Test
    fun presign_buildsUrlWithSongIdTtlAndStandardHeaders() = runTest {
        token = "tok"
        server.enqueue(MockResponse().setBody("""{"url":"https://s3.example/x.mp3?sig=1"}"""))
        val url = client().presign("sng_a b", ttlSeconds = 21600)
        assertEquals("https://s3.example/x.mp3?sig=1", url)
        val req = server.takeRequest()
        assertEquals("/rips/presign?songId=sng_a%20b&ttl=21600", req.path)
        assertEquals("Bearer tok", req.getHeader("Authorization"))
        assertEquals("device-uuid-1234", req.getHeader("X-PocketDJ-Device"))
    }

    @Test
    fun presign_withoutTtl_omitsParam_andMissingUrlFails() = runTest {
        server.enqueue(MockResponse().setBody("""{"url":"https://s3/x"}"""))
        client().presign("sng_a")
        assertEquals("/rips/presign?songId=sng_a", server.takeRequest().path)
        server.enqueue(MockResponse().setBody("""{"nope":1}"""))
        assertTrue(runCatching { client().presign("sng_a") }.exceptionOrNull() is RipServerClient.RipServerException)
    }

    @Test
    fun interactiveWait_returnsStillRippingAfter20sOfVirtualTime_notTimedOut() = runTest {
        server.dispatcher = alwaysDispatcher("""{"phase":"queued","jobId":"j1"}""")
        val outcome = client().awaitReadyInteractive("j1", clock = { testScheduler.currentTime })
        assertEquals(RipWaitOutcome.StillRipping("j1"), outcome)
        assertEquals(20_000L, testScheduler.currentTime)
    }

    @Test
    fun interactiveWait_returnsReadyUrl() = runTest {
        server.enqueue(MockResponse().setBody("""{"phase":"ripping","jobId":"j1"}"""))
        server.enqueue(MockResponse().setBody("""{"phase":"ready","jobId":"j1","url":"https://x/y.mp3"}"""))
        val outcome = client().awaitReadyInteractive("j1", clock = { testScheduler.currentTime })
        assertEquals(RipWaitOutcome.Ready("https://x/y.mp3"), outcome)
    }

    @Test
    fun interactiveWait_errorPhaseThrows() = runTest {
        server.enqueue(MockResponse().setBody("""{"phase":"error","jobId":"j1","error":"boom"}"""))
        val e = runCatching { client().awaitReadyInteractive("j1", clock = { testScheduler.currentTime }) }
            .exceptionOrNull() as RipServerClient.RipServerException
        assertEquals("boom", e.message)
    }

    @Test
    fun interactiveWait_tenConsecutivePollFailuresAbort() = runTest {
        server.dispatcher = alwaysDispatcher("""{"error":"x"}""", code = 500)
        val e = runCatching {
            client().awaitReadyInteractive("j1", maxWaitMs = 600_000, clock = { testScheduler.currentTime })
        }.exceptionOrNull()
        assertTrue(e is RipServerClient.RipServerException)
        assertEquals(10, server.requestCount)
    }

    @Test
    fun interactiveWait_aSingleDroppedPollDoesNotAbort() = runTest {
        server.enqueue(MockResponse().setResponseCode(502))
        server.enqueue(MockResponse().setBody("""{"phase":"ready","jobId":"j1","url":"https://x/y.mp3"}"""))
        val outcome = client().awaitReadyInteractive("j1", clock = { testScheduler.currentTime })
        assertTrue(outcome is RipWaitOutcome.Ready)
    }

    @Test
    fun ripCollection_dedupsFencesStudioIdsAndClassifiesCounts() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"results":[{"songId":"a","status":"ready","url":"u"},{"songId":"b","status":"queued","jobId":"j"}],
                  "counts":{"ready":1,"queued":1,"inflight":0,"unknown":0,"total":2}}""",
            ),
        )
        val r = client().ripCollection(listOf("a", "b", "a", "smp_x", "pdj_y"))
        assertEquals(2, r.total)
        assertEquals(1, r.ready)
        assertEquals(1, r.queued)
        val req = server.takeRequest()
        assertEquals("/rip-collection", req.path)
        assertEquals("""{"songIds":["a","b"]}""", req.body.readUtf8())
    }

    @Test
    fun ripCollection_emptyAfterFence_isNoOpWithoutNetwork() = runTest {
        val r = client().ripCollection(listOf("smp_x", "tk_y"))
        assertEquals(BatchRipResult(), r)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun ripCollection_404FallsBackPerSongAndSynthesizesCounts() = runTest {
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest): MockResponse {
                if (request.path == "/rip-collection") return MockResponse().setResponseCode(404)
                val id = request.body.readUtf8()
                return when {
                    id.contains("\"q\"") -> MockResponse().setBody("""{"phase":"queued","jobId":"jq"}""")
                    id.contains("\"r\"") -> MockResponse().setBody("""{"phase":"ripping","jobId":"jr"}""")
                    id.contains("\"d\"") -> MockResponse().setBody("""{"phase":"ready","url":"https://x/d.mp3"}""")
                    else -> MockResponse().setResponseCode(500)
                }
            }
        }
        val r = client().ripCollection(listOf("have", "q", "r", "d", "bad", "q")) { it == "have" }
        assertEquals(5, r.total)
        assertEquals(2, r.ready) // already ripped + server says ready
        assertEquals(1, r.queued)
        assertEquals(1, r.inflight)
        assertEquals(1, r.unknown)
        assertEquals("ready", r.results.first { it.songId == "have" }.status)
    }

    @Test
    fun cancelRips_postsDedupedIds_decodesResults_andIsSilentOn404() = runTest {
        server.enqueue(MockResponse().setBody("""{"results":[{"songId":"a","status":"canceled"},{"songId":"b","status":"notFound"}]}"""))
        val items = client().cancelRips(listOf("a", "b", "a"))
        assertEquals(listOf(CancelItem("a", "canceled"), CancelItem("b", "notFound")), items)
        val req = server.takeRequest()
        assertEquals("/rip-cancel", req.path)
        assertEquals("""{"songIds":["a","b"]}""", req.body.readUtf8())
        server.enqueue(MockResponse().setResponseCode(404))
        assertTrue(client().cancelRips(listOf("a")).isEmpty())
    }

    @Test
    fun cancelRips_undecodable2xx_reportsAllCanceled() = runTest {
        server.enqueue(MockResponse().setBody("ok"))
        assertEquals(listOf(CancelItem("a", "canceled")), client().cancelRips(listOf("a")))
    }

    @Test
    fun cancelStemCollection_postsToStemifyCancel_dedups_andIsSilentOn404() = runTest {
        server.enqueue(MockResponse().setBody("""{"results":[{"songId":"a","status":"canceled"}]}"""))
        val items = client().cancelStemCollection(listOf("a", "a"))
        assertEquals(listOf(CancelItem("a", "canceled")), items)
        val req = server.takeRequest()
        assertEquals("/stemify-cancel", req.path)
        assertEquals("""{"songIds":["a"]}""", req.body.readUtf8())
        server.enqueue(MockResponse().setResponseCode(404))
        assertTrue(client().cancelStemCollection(listOf("a")).isEmpty())
    }

    @Test
    fun stemifyCollection_flagsViaBatchOnlyWhenBatchEndpointAnswered() = runTest {
        server.enqueue(MockResponse().setBody("""{"results":[{"songId":"a","status":"queued","jobId":"j"}],"counts":{"queued":1,"total":1}}"""))
        assertTrue(client().stemifyCollection(listOf("a")).viaBatch)
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(500)) // per-song fallback
        assertFalse(client().stemifyCollection(listOf("a"), fallbackOne = { null }).viaBatch)
    }

    // ---- Discover (BRW-15): /search and /album-tracks ----

    @Test
    fun searchSongs_decodesHitsToleratingMissingOptionalKeys_andSendsQueryAndAuth() = runTest {
        token = "tok"
        server.enqueue(
            MockResponse().setBody(
                """{"results":[{"appleMusicId":"1","title":"A","artist":"B","songId":"amrec_1","ripped":true,"url":"https://r/1.mp3","explicit":true,"future":1},
                    {"appleMusicId":"2","title":"C","artist":"D","songId":"amrec_2"}]}""",
            ),
        )
        val hits = client().searchSongs("daft punk", 25)
        val req = server.takeRequest()
        assertEquals("/search?q=daft%20punk&limit=25", req.path)
        assertEquals("Bearer tok", req.getHeader("Authorization"))
        assertEquals(listOf("1", "2"), hits.map { it.appleMusicId })
        assertEquals(true, hits[0].ripped)
        assertNull(hits[1].url)
        assertNull(hits[1].albumAppleMusicId)
    }

    @Test
    fun searchAlbums_sendsEntityAlbum() = runTest {
        server.enqueue(MockResponse().setBody("""{"results":[{"appleMusicId":"9","albumId":"amrec_album_9","title":"LP","artist":"X","trackCount":10,"year":1999}]}"""))
        val hits = client().searchAlbums("lp")
        assertTrue(server.takeRequest().path!!.contains("entity=album"))
        assertEquals("amrec_album_9", hits.single().albumId)
        assertEquals(10, hits.single().trackCount)
    }

    @Test
    fun searchSongs_unauthorized_throwsWithCode() = runTest {
        server.enqueue(MockResponse().setResponseCode(401).setBody("{}"))
        val e = runCatching { client().searchSongs("x") }.exceptionOrNull() as RipServerClient.RipServerException
        assertEquals(401, e.code)
    }

    @Test
    fun albumTracks_withAlbumEnvelope() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"tracks":[{"id":"t1","title":"One","artist":"X","trackNumber":1,"durationMs":1000},{"id":"t2","title":"Two","artist":"X","discNumber":1}],
                    "album":{"appleMusicId":"9","albumId":"amrec_album_9","title":"LP","artist":"X","releaseDate":"2026-11-01T08:00:00Z"}}""",
            ),
        )
        val exp = client().albumTracks("9")
        assertEquals("/album-tracks?id=9", server.takeRequest().path)
        assertEquals(2, exp.tracks.size)
        assertEquals("2026-11-01T08:00:00Z", exp.album!!.releaseDate)
    }

    @Test
    fun albumTracks_missingAlbumEnvelope_stillDecodesTracks() = runTest {
        server.enqueue(MockResponse().setBody("""{"tracks":[{"id":"t1","title":"One","artist":"X"}]}"""))
        val exp = client().albumTracks("9")
        assertEquals(1, exp.tracks.size)
        assertNull(exp.album)
    }

    @Test
    fun albumTracks_failureOrBlankId_isEmptyNotThrow() = runTest {
        server.enqueue(MockResponse().setResponseCode(500).setBody("{}"))
        assertTrue(client().albumTracks("9").tracks.isEmpty())
        assertTrue(client().albumTracks("  ").tracks.isEmpty())
        assertEquals(1, server.requestCount)
    }
}

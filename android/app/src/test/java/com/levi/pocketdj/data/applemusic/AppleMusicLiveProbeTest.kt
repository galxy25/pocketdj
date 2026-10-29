package com.levi.pocketdj.data.applemusic

import java.util.Base64
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AppleMusicLiveProbeTest {
    private lateinit var server: MockWebServer
    private val seen = mutableListOf<String>()

    @Before fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val p = request.path.orEmpty()
                seen += "${request.method} ${p.substringBefore('?')}"
                return when {
                    p.startsWith("/v1/catalog/us/search") -> MockResponse().setBody(
                        """{"results":{"songs":{"data":[{"id":"111","attributes":{"name":"One More Time","artistName":"Daft Punk"}}]}}}""",
                    )
                    p.startsWith("/v1/me/storefront") -> MockResponse().setBody("""{"data":[{"id":"us"}]}""")
                    p.startsWith("/v1/me/library/playlists") -> MockResponse().setBody("""{"data":[]}""")
                    p.startsWith("/v1/me/ratings/songs") && request.method == "GET" -> MockResponse().setBody("""{"data":[]}""")
                    else -> MockResponse().setResponseCode(204)
                }
            }
        }
        server.start()
    }

    @After fun tearDown() { server.shutdown() }

    private fun api(user: String? = "mut") = AppleMusicApi(
        OkHttpClient(), StaticAppleMusicTokens("dev", user),
        baseUrl = server.url("/").toString().trimEnd('/'), sleeper = {},
    )

    @Test fun probeRestoresRatingAndSkipsStarByDefault() = runTest {
        val lines = AppleMusicLiveProbe.run(api())
        assertTrue(lines.first(), lines.first().startsWith("catalog=Ok") && "id=111" in lines.first())
        assertTrue(lines.any { it.startsWith("libraryAdd=Ok") })
        assertTrue(lines.any { it.startsWith("rateLove=Ok") })
        assertTrue(lines.any { it.startsWith("unrate(restore)=Ok") })
        assertTrue(lines.any { it.startsWith("star=skipped") })
        assertTrue("DELETE /v1/me/ratings/songs/111" in seen)
        assertFalse(seen.any { it.contains("/v1/me/favorites") })
        assertTrue(lines.none { it.contains("mut") || it.contains("Bearer") })
    }

    @Test fun probeWithoutMutReportsNeedsUserToken() = runTest {
        val lines = AppleMusicLiveProbe.run(api(user = null), probeSongId = "222")
        assertTrue(lines.any { it.startsWith("libraryAdd=NeedsUserToken") })
        assertFalse(seen.any { it.startsWith("POST") })
    }

    @Test fun jwtExpiryDecodes() {
        val enc = Base64.getUrlEncoder().withoutPadding()
        val tok = enc.encodeToString("""{"alg":"ES256"}""".toByteArray()) + "." +
            enc.encodeToString("""{"iss":"T","exp":1806250112}""".toByteArray()) + ".sig"
        assertEquals(1806250112000L, AppleMusicLiveProbe.jwtExpiryMs(tok))
        assertNull(AppleMusicLiveProbe.jwtExpiryMs("garbage"))
    }
}

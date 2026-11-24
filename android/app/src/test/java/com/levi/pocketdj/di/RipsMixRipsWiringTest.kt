package com.levi.pocketdj.di

import com.levi.pocketdj.data.rips.RipCollectionCoordinator
import com.levi.pocketdj.data.rips.RipJob
import com.levi.pocketdj.data.rips.RipJobTracker
import com.levi.pocketdj.data.rips.RipServerClient
import com.levi.pocketdj.data.rips.RipsRepository
import kotlinx.coroutines.ExperimentalCoroutinesApi
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
import java.nio.file.Files

/**
 * The production adapter the Mix downloader runs on (P2-MIX-1 review): a wrong token's 401 must reach the lane as a
 * REFUSED batch + a held credential, not a silent "accepted". Real client + coordinator over MockWebServer.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RipsMixRipsWiringTest {
    private lateinit var server: MockWebServer
    private var token = "bad"

    @Before fun setUp() { server = MockWebServer().also { it.start() }; token = "bad" }
    @After fun tearDown() { server.shutdown() }

    private fun adapter(scope: kotlinx.coroutines.CoroutineScope): RipsMixRips {
        val client = RipServerClient(
            http = OkHttpClient(),
            configProvider = { RipServerClient.Config(server.url("/").toString(), token, "dev") },
        )
        val repo = RipsRepository(Files.createTempDirectory("ripswire").toFile(), OkHttpClient(), scope = scope)
        val tracker = RipJobTracker(scope, { RipJob("queued", it) }, pollMs = 1_000)
        return RipsMixRips(repo, client, RipCollectionCoordinator(client, tracker))
    }

    @Test fun batch401_surfacesAsRefused_andHoldsAutomaticTraffic() = runTest {
        val rips = adapter(backgroundScope)
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"unauthorized"}"""))
        rips.refreshAuth()
        assertFalse(rips.isAuthRejected)
        val outcome = rips.requestRips(listOf("a", "b"))
        assertEquals(401, outcome.refusedStatus)
        assertTrue(outcome.unauthorized)
        rips.refreshAuth()
        assertTrue("the lane sees the credential fault", rips.isAuthRejected)
        assertTrue("and holds", rips.authHoldoff)
        val before = server.requestCount
        val held = rips.requestRips(listOf("a", "b"))
        assertTrue("a held automatic request is refused WITHOUT touching the server", held.unauthorized)
        assertEquals(before, server.requestCount)
    }

    @Test fun retypingTheToken_clearsTheHold() = runTest {
        val rips = adapter(backgroundScope)
        server.enqueue(MockResponse().setResponseCode(401))
        rips.requestRips(listOf("a"))
        rips.refreshAuth()
        assertTrue(rips.authHoldoff)
        token = "good"
        rips.refreshAuth()
        assertFalse(rips.isAuthRejected)
        assertFalse(rips.authHoldoff)
    }

    @Test fun acceptedBatch_isNotRefused() = runTest {
        val rips = adapter(backgroundScope)
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"results":[],"queued":1,"total":1}"""))
        val outcome = rips.requestRips(listOf("a"))
        assertNull(outcome.refusedStatus)
    }
}

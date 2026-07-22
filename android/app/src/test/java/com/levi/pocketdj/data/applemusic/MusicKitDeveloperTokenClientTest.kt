package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.rips.RipServerClient
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dev-token fetch/cache/expiry from the rip server (specs/applemusic.md §5). */
class MusicKitDeveloperTokenClientTest {

    private fun config(base: String) = RipServerClient.Config(baseUrl = base, token = "", installId = "dev-1")

    private fun client(server: MockWebServer): MusicKitDeveloperTokenClient =
        MusicKitDeveloperTokenClient(
            http = OkHttpClient(),
            configProvider = { config(server.url("/").toString()) },
            settings = null,
        )

    @Test
    fun fetchesTokenThenServesFromCache() = runTest {
        val server = MockWebServer()
        val exp = System.currentTimeMillis() + 48L * 3600 * 1000
        server.enqueue(MockResponse().setBody("""{"token":"jwt-abc","expiresAt":$exp,"ttlSec":100}"""))
        server.start()
        try {
            val c = client(server)
            assertEquals("jwt-abc", c.developerToken())
            assertEquals("jwt-abc", c.cachedTokenOrNull())
            // Second call is cache-served (well outside the 24 h refetch lead).
            assertEquals("jwt-abc", c.developerToken())
            assertEquals("/musickit-token", server.takeRequest().path)
            assertEquals(1, server.requestCount)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun refetchesWhenTokenIsWithinTheRefreshLead() = runTest {
        val server = MockWebServer()
        val soon = System.currentTimeMillis() + 1_000 // < 24 h left → always refetch
        server.enqueue(MockResponse().setBody("""{"token":"jwt-1","expiresAt":$soon}"""))
        server.enqueue(MockResponse().setBody("""{"token":"jwt-2","expiresAt":$soon}"""))
        server.start()
        try {
            val c = client(server)
            assertEquals("jwt-1", c.developerToken())
            assertEquals("jwt-2", c.developerToken())
            assertEquals(2, server.requestCount)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun noServerConfiguredThrowsAndCacheStaysEmpty() = runTest {
        val c = MusicKitDeveloperTokenClient(
            http = OkHttpClient(),
            configProvider = { config("") }, // unconfigured
            settings = null,
        )
        assertThrows(RipServerClient.RipServerException::class.java) {
            kotlinx.coroutines.runBlocking { c.developerToken() }
        }
        assertNull(c.cachedTokenOrNull())
    }

    @Test
    fun sendsInstallIdHeader() = runTest {
        val server = MockWebServer()
        server.enqueue(MockResponse().setBody("""{"token":"jwt","expiresAt":${System.currentTimeMillis() + 999_999_999}}"""))
        server.start()
        try {
            client(server).developerToken()
            val recorded = server.takeRequest()
            assertEquals("dev-1", recorded.getHeader("X-PocketDJ-Device"))
            assertTrue(recorded.getHeader("Authorization") == null) // empty rip token ⇒ no bearer
        } finally {
            server.shutdown()
        }
    }
}

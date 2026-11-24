package com.levi.pocketdj.data.applemusic

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class RejectedMutTest {

    // ---- pattern match ---------------------------------------------------------------------

    @Test fun matchesAppleRejections() {
        assertTrue(RejectedMut.matches("AM GET /v1/me/library/playlists -> 403"))
        assertTrue(RejectedMut.matches("AM POST /v1/me/library/playlists -> 401"))
        assertTrue(RejectedMut.matches("worker: AM GET /v1/me/library -> 403 {\"errors\":[{\"code\":\"40300\"}]}"))
    }

    @Test fun ignoresEverythingElse() {
        assertFalse(RejectedMut.matches("""{"error":"unauthorized"}""")) // OUR gateway's 401
        assertFalse(RejectedMut.matches("AM GET /v1/me/library/playlists -> 500"))
        assertFalse(RejectedMut.matches("AM GET /v1/me/library/playlists -> 4030"))
        assertFalse(RejectedMut.matches("AM GET /v1/catalog/us/songs/1 -> 404"))
        assertFalse(RejectedMut.matches(null))
        assertFalse(RejectedMut.matches("HTTP 403"))
    }

    @Test fun exceptionClassification() {
        assertTrue(RejectedMut.isAppleAuthRejection(AmSyncException.Worker("AM GET /v1/me/library/playlists -> 403")))
        assertTrue(RejectedMut.isAppleAuthRejection(AmSyncException.Http(400, "AM PUT /v1/me/x -> 401")))
        // our gateway answering 401 with its own body must NOT trigger
        assertFalse(RejectedMut.isAppleAuthRejection(AmSyncException.Http(401, """{"error":"unauthorized"}""")))
        assertFalse(RejectedMut.isAppleAuthRejection(AmSyncException.NotSignedIn()))
        assertFalse(RejectedMut.isAppleAuthRejection(AmSyncException.Stalled("x")))
        assertFalse(RejectedMut.isAppleAuthRejection(java.io.IOException("AM GET /x -> 403")))
    }

    // ---- once per token --------------------------------------------------------------------

    private class FakeStore(var token: String?, var fp: String = "") : MutStore {
        var clears = 0
        override suspend fun currentToken() = token
        override suspend fun clearToken() { token = null; clears++ }
        override suspend fun lastClearedFingerprint() = fp
        override suspend fun markCleared(fingerprint: String) { fp = fingerprint }
    }

    @Test fun clearsTheRejectedTokenExactlyOnce() = runBlocking {
        val store = FakeStore("tok-A")
        val h = MutRejectionHandler(store)
        assertTrue(h.onRejected("tok-A"))
        assertNull(store.token)
        assertEquals(1, store.clears)
        // a second failing job for the same token: nothing left to clear
        assertFalse(h.onRejected("tok-A"))
        assertEquals(1, store.clears)
    }

    @Test fun neverClearsANewerTokenForALateFailure() = runBlocking {
        val store = FakeStore("tok-B") // the user already reconnected
        val h = MutRejectionHandler(store)
        assertFalse(h.onRejected("tok-A"))
        assertEquals("tok-B", store.token)
    }

    @Test fun sameTokenReissuedAfterClearIsNotClearedTwice() = runBlocking {
        val store = FakeStore("tok-A")
        val h = MutRejectionHandler(store)
        assertTrue(h.onRejected("tok-A"))
        store.token = "tok-A" // Apple handed back the very same dead token on reconnect
        assertFalse(h.onRejected("tok-A")) // no daily clear/reconnect loop for the identical token
        assertEquals("tok-A", store.token)
        store.token = "tok-C"
        assertTrue(h.onRejected("tok-C")) // a genuinely new token that is rejected is handled
    }

    @Test fun nullOrBlankUsedTokenIsIgnored() = runBlocking {
        val store = FakeStore("tok-A")
        val h = MutRejectionHandler(store)
        assertFalse(h.onRejected(null))
        assertFalse(h.onRejected("  "))
        assertEquals("tok-A", store.token)
    }

    @Test fun reconnectShowsOnlyWhileFlaggedAndSignedOut() {
        assertTrue(RejectedMut.needsReconnect(flag = true, hasToken = false))
        assertFalse(RejectedMut.needsReconnect(flag = true, hasToken = true)) // reconnected
        assertFalse(RejectedMut.needsReconnect(flag = false, hasToken = false)) // plain signed-out user
    }

    // ---- end to end through the sync client -------------------------------------------------

    private class RecordingTokens(private val mut: String?) : AppleMusicTokens {
        val rejected = mutableListOf<String?>()
        override suspend fun developerToken() = "dev"
        override suspend fun musicUserToken() = mut
        override suspend fun onAppleAuthRejected(usedToken: String?): Boolean { rejected += usedToken; return true }
    }

    private lateinit var server: MockWebServer
    @Before fun up() { server = MockWebServer().also { it.start() } }
    @After fun down() { server.shutdown() }

    private fun client(tokens: AppleMusicTokens) = AMPlaylistSyncClient(
        http = OkHttpClient.Builder().retryOnConnectionFailure(false).build(),
        tokens = tokens,
        jobs = InMemoryAmJobStore(),
        baseProvider = { server.url("/").toString() },
        stallTimeoutMs = 10_000, pollIntervalMs = 1,
        sleep = { },
    )

    @Test fun workerAppleRejectionClearsTokenOnce() = runBlocking {
        val tokens = RecordingTokens("MUT")
        server.enqueue(MockResponse().setResponseCode(202).setBody("""{"jobId":"j1"}"""))
        server.enqueue(MockResponse().setBody("""{"status":"error","error":"AM GET /v1/me/library/playlists -> 403"}"""))
        try { client(tokens).pull(); fail() } catch (e: AmSyncException.Worker) { /* expected */ }
        assertEquals(listOf<String?>("MUT"), tokens.rejected)
    }

    @Test fun ourGatewayUnauthorizedNeverTriggers() = runBlocking {
        val tokens = RecordingTokens("MUT")
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"unauthorized"}"""))
        try { client(tokens).pull(); fail() } catch (e: AmSyncException.Http) { assertEquals(401, e.code) }
        assertTrue(tokens.rejected.isEmpty())
    }

    @Test fun submitTimeAppleRejectionAlsoTriggers() = runBlocking {
        val tokens = RecordingTokens("MUT")
        server.enqueue(MockResponse().setResponseCode(400).setBody("AM GET /v1/me/library/playlists -> 401"))
        try { client(tokens).pull(); fail() } catch (e: AmSyncException.Http) { /* expected */ }
        assertEquals(1, tokens.rejected.size)
    }
}

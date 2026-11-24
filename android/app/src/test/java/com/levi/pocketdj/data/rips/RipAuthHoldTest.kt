package com.levi.pocketdj.data.rips

import com.levi.pocketdj.screens.playlists.CollectionBurnReducer
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
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

@OptIn(ExperimentalCoroutinesApi::class)
class RipAuthHoldTest {
    private lateinit var server: MockWebServer
    private var token = "bad"
    private var now = 0L
    private val logs = mutableListOf<String>()

    private fun state() = RipAuthState(clock = { now }, log = { logs += it })

    @Before fun setUp() { server = MockWebServer().also { it.start() }; token = "bad"; now = 0L }
    @After fun tearDown() { server.shutdown() }

    // ---- RipAuthState (pure) ----

    @Test fun rejection_holdsOff_thenReprobesAfter120s() {
        val s = state()
        s.noteStatus(401, "bad")
        assertTrue(s.isRejected("bad"))
        assertTrue(s.holdoff("bad"))
        now = 119_999
        assertTrue(s.holdoff("bad"))
        now = 120_000
        assertFalse(s.holdoff("bad")) // one automatic probe may go through
        assertTrue(s.isRejected("bad")) // still sticky for the UI copy
    }

    @Test fun anotherRejectionInsideTheWindow_restartsTheClock() {
        val s = state()
        s.noteStatus(403, "bad")
        now = 100_000
        s.noteStatus(401, "bad")
        now = 200_000
        assertTrue(s.holdoff("bad")) // 100 s since the LAST rejection
    }

    @Test fun tokenChange_clearsByConstruction() {
        val s = state()
        s.noteStatus(401, "bad")
        assertFalse(s.isRejected("fixed"))
        assertFalse(s.holdoff("fixed"))
        assertTrue(s.isRejected("bad")) // the old value is still the rejected one
    }

    @Test fun any2xx_clears_andOther5xxDoesNot() {
        val s = state()
        s.noteStatus(401, "bad")
        s.noteStatus(500, "bad")
        assertTrue(s.isRejected("bad"))
        s.noteStatus(204, "other-token")
        assertFalse(s.isRejected("bad"))
        assertFalse(s.holdoff("bad"))
    }

    @Test fun noServer_isNeverRejected() {
        val s = state()
        s.noteStatus(401, "bad")
        assertFalse(s.isRejected("bad", hasServer = false))
        assertFalse(s.holdoff("bad", hasServer = false))
    }

    @Test fun revisionBumpsOnlyOnTransitions_andTokenIsNeverLogged() {
        val s = state()
        s.noteStatus(401, "super-secret-token")
        s.noteStatus(401, "super-secret-token") // repeat: no re-render, no second log line
        assertEquals(1, s.revision.value)
        s.noteStatus(200, "super-secret-token")
        assertEquals(2, s.revision.value)
        assertEquals(2, logs.size)
        assertTrue(logs.none { it.contains("super-secret-token") })
    }

    // ---- RipServerClient wiring ----

    private fun client() = RipServerClient(
        http = OkHttpClient(),
        configProvider = { RipServerClient.Config(server.url("/").toString(), token, "dev") },
    )

    @Test fun presign401_throwsUnauthorized_withHonestCopy_andHolds() = runTest {
        val c = client()
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"unauthorized"}"""))
        val e = runCatching { c.presign("sng_a") }.exceptionOrNull()
        assertTrue(e is RipServerClient.RipUnauthorizedException)
        assertEquals(401, (e as RipServerClient.RipServerException).code)
        assertEquals("The import server rejected this device's token (Settings ▸ Import server)", e.message)
        assertTrue(c.isAuthRejected())
        assertTrue(c.authHoldoff())
    }

    @Test fun fixingTheToken_clearsTheHold_withoutAnyRequest() = runTest {
        val c = client()
        server.enqueue(MockResponse().setResponseCode(403))
        runCatching { c.presign("sng_a") }
        assertTrue(c.authHoldoff())
        token = "good"
        assertFalse(c.isAuthRejected())
        assertFalse(c.authHoldoff())
    }

    @Test fun a2xxFromAnyAuthedCall_clears() = runTest {
        val c = client()
        server.enqueue(MockResponse().setResponseCode(401))
        runCatching { c.presign("sng_a") }
        server.enqueue(MockResponse().setBody("""{"url":"https://s3/x"}"""))
        c.presign("sng_a") // a user action still tries; the server now accepts the same token
        assertFalse(c.isAuthRejected())
    }

    @Test fun healthWithACandidateToken_doesNotTouchTheSavedTokensState() = runTest {
        val c = client()
        server.enqueue(MockResponse().setResponseCode(401))
        runCatching { c.presign("sng_a") }
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        runCatching { c.health(candidateUrl = server.url("/").toString(), candidateToken = "typed") }
        assertTrue(c.isAuthRejected()) // the candidate's 2xx must not clear the saved token's rejection
    }

    @Test fun ripCollection401_reportsRefusedStatus_notEmptySuccess() = runTest {
        val c = client()
        server.enqueue(MockResponse().setResponseCode(401))
        val r = c.ripCollection(listOf("a", "b"))
        assertEquals(401, r.refusedStatus)
        assertTrue(r.unauthorized)
        assertEquals(2, r.total)
        assertTrue(c.isAuthRejected())
        assertEquals(1, server.requestCount) // no per-song fallback storm
    }

    @Test fun ripCollectionTransportFailure_isMinusOne_andNeverFallsBackPerSong() = runTest {
        val c = client()
        server.enqueue(MockResponse().setBody("not json")) // 200 but undecodable
        val r = c.ripCollection(listOf("a", "b", "c"))
        assertEquals(RipAuthState.TRANSPORT_FAILURE, r.refusedStatus)
        assertEquals(-1, r.refusedStatus)
        assertFalse(r.unauthorized)
        assertEquals(1, server.requestCount)
    }

    @Test fun ripCollection500_isRefusedButNotAuth() = runTest {
        val c = client()
        server.enqueue(MockResponse().setResponseCode(500))
        val r = c.ripCollection(listOf("a"))
        assertEquals(500, r.refusedStatus)
        assertFalse(r.unauthorized)
        assertFalse(c.isAuthRejected())
    }

    @Test fun acceptedBatch_hasNullRefusedStatus() = runTest {
        server.enqueue(MockResponse().setBody("""{"results":[],"counts":{"ready":0,"queued":0,"inflight":0,"unknown":0,"total":0}}"""))
        assertNull(client().ripCollection(listOf("a")).refusedStatus)
    }

    // ---- automatic callers ----

    @Test fun prefetch_holdsOffInsideTheWindow_butUrlForStillTries() = runTest {
        val calls = AtomicInteger()
        var hold = true
        val cache = PresignCache(
            scope = backgroundScope, isConfigured = { true },
            presigner = { id, _ -> calls.incrementAndGet(); "https://s3/$id" },
            authHoldoff = { hold },
        )
        cache.prefetch(listOf("a", "b"))
        runCurrent()
        assertEquals(0, calls.get())
        assertEquals("https://s3/a", cache.urlFor("a")) // user-driven
        assertEquals(1, calls.get())
        hold = false
        cache.prefetch(listOf("b"))
        runCurrent()
        assertEquals(2, calls.get())
    }

    @Test fun coordinator_automaticHeldOff_userStillTries() = runTest {
        val tracker = RipJobTracker(backgroundScope, { RipJob("queued", it) }, pollMs = 1_000)
        var served = 0
        val coord = RipCollectionCoordinator(
            tracker, { ids, _ -> served++; BatchRipResult(total = ids.size) }, { emptyList() }, { true },
        )
        val held = coord.ripCollection(listOf("a", "b"), automatic = true)
        assertEquals(0, served)
        assertEquals(401, held.refusedStatus)
        assertTrue(held.unauthorized)
        val user = coord.ripCollection(listOf("a", "b"))
        assertEquals(1, served)
        assertNull(user.refusedStatus)
    }

    // ---- bar copy ----

    @Test fun barCopy_saysTokenRejected_notServerDown() {
        val copy = "The import server rejected this device's token (Settings ▸ Import server)"
        assertEquals(copy, CollectionBurnReducer.ripSummary(BatchRipResult(total = 3, refusedStatus = 403)))
        assertTrue(CollectionBurnReducer.ripSummary(BatchRipResult(refusedStatus = -1)).contains("Couldn't reach"))
        assertTrue(CollectionBurnReducer.ripSummary(BatchRipResult(refusedStatus = 500)).contains("(500)"))
        assertEquals("Nothing to rip.", CollectionBurnReducer.ripSummary(BatchRipResult())) // data-absent unchanged
    }
}

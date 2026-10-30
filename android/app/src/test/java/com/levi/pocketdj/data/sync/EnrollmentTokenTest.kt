package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.config.EndpointConfig
import com.levi.pocketdj.data.config.RemoteEndpoints
import com.levi.pocketdj.data.credentials.InMemorySecretStore
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

/** ANS-SYNC-1: the enroll capability token comes from the endpoints doc at request time, never a build constant. */
class EnrollmentTokenTest {
    private val token = "profile-sync-enroll-0123456789abcdef"
    private fun doc(caps: String) = """{"v":1,"env":"green","endpoints":{
        "catalogBase":"https://d1j6qufkowz1xq.cloudfront.net",
        "ripsBase":"https://pocketdj-rips-623170744161.s3.us-west-2.amazonaws.com",
        "amPlaylistSyncBase":"https://webhj3e832.execute-api.us-west-2.amazonaws.com",
        "recEngineBase":"https://kwgk9osywa.execute-api.us-west-2.amazonaws.com",
        "diagLogsBase":"https://pocketdj-logs-623170744161.s3.us-west-2.amazonaws.com",
        "profileSyncBase":"https://abc123.execute-api.us-west-2.amazonaws.com"}$caps}"""

    @Before @After fun reset() = RemoteEndpoints.resetForTests()

    @Test fun compiledInConfig_carriesNoEnrollToken() {
        assertNull(EndpointConfig.COMPILED_IN.profileSyncEnroll)
        assertEquals("", RemoteEndpoints.profileSyncEnroll())
    }

    @Test fun docCapability_isParsed_andIndependentOfRecEngineEnroll() {
        val ok = EndpointConfig.decode(doc(""","capabilities":{"profileSyncEnroll":"$token","recEngineEnroll":"rec-engine-secret-0123456789"}"""))
            as EndpointConfig.Companion.Decoded.Ok
        assertEquals(token, ok.config.profileSyncEnroll)
        assertEquals("rec-engine-secret-0123456789", ok.config.recEngineEnroll)
        assertTrue(RemoteEndpoints.apply(doc(""","capabilities":{"profileSyncEnroll":"$token"}""")))
        assertEquals(token, RemoteEndpoints.profileSyncEnroll())
    }

    @Test fun malformedCapability_isIgnored_docStillAccepted() {
        for (bad in listOf("\"short\"", "12345", "\"has space in it 0123456789\"", "null")) {
            val r = EndpointConfig.decode(doc(""","capabilities":{"profileSyncEnroll":$bad}"""))
            assertNull(bad, (r as EndpointConfig.Companion.Decoded.Ok).config.profileSyncEnroll)
        }
    }

    @Test fun rotation_changesTheActiveConfig_andNextTokenRead() {
        RemoteEndpoints.apply(doc(""","capabilities":{"profileSyncEnroll":"$token"}"""))
        val rotated = "rotated-enroll-token-fedcba9876543210"
        assertTrue(RemoteEndpoints.apply(doc(""","capabilities":{"profileSyncEnroll":"$rotated"}""")))
        assertEquals(rotated, RemoteEndpoints.profileSyncEnroll())
    }

    @Test fun tokenFrom_prefersDoc_fallsBackToKeystore_elseEmpty() {
        val store = InMemorySecretStore()
        assertEquals("", Enrollment.tokenFrom(store)())
        store.put(ProfileSecretStore.ENROLL_TOKEN, "manual")
        assertEquals("manual", Enrollment.tokenFrom(store)())
        assertEquals("from-doc", Enrollment.tokenFrom(store) { "from-doc" }())
    }

    @Test fun enrollment_sendsTheDocToken_andWithoutOneMakesNoRequest() = runTest {
        val server = MockWebServer().also { it.start() }
        try {
            server.enqueue(MockResponse().setBody("{}"))
            val secrets = ProfileSecretStore(InMemorySecretStore())
            var current = ""
            val e = Enrollment(secrets, { server.url("/").toString().trimEnd('/') }, Enrollment.tokenFrom(InMemorySecretStore()) { current },
                OkHttpClient(), backoff = {})
            assertEquals(Enrollment.Outcome.NotConfigured, e.ensureEnrolled("3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
            assertEquals(0, server.requestCount)
            current = token // the doc arrived after launch: picked up on the next pass, no restart
            assertEquals(Enrollment.Outcome.Enrolled, e.ensureEnrolled("3F2504E0-4F89-41D3-9A0C-0305E82C3301"))
            assertEquals(token, server.takeRequest().getHeader("X-PocketDJ-Enroll"))
        } finally { server.shutdown() }
    }

    @Test fun refusal_isStickyOnlyForTheSameToken_rotationRetries() = runTest {
        val server = MockWebServer().also { it.start() }
        try {
            server.enqueue(MockResponse().setResponseCode(401))
            server.enqueue(MockResponse().setBody("{}"))
            var current = "old-enroll-token-0123456789abcdef"
            val e = Enrollment(ProfileSecretStore(InMemorySecretStore()), { server.url("/").toString().trimEnd('/') },
                { current }, OkHttpClient(), backoff = {})
            val id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
            assertEquals(Enrollment.Outcome.Refused(401), e.ensureEnrolled(id))
            assertEquals(Enrollment.Outcome.Refused(401), e.ensureEnrolled(id)) // same token: cached
            assertEquals(1, server.requestCount)
            current = token // rotated doc arrived
            assertEquals(Enrollment.Outcome.Enrolled, e.ensureEnrolled(id))
            assertEquals(2, server.requestCount)
        } finally { server.shutdown() }
    }
}

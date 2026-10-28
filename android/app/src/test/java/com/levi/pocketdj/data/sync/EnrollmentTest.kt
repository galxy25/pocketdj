package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.credentials.InMemorySecretStore
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class EnrollmentTest {
    private lateinit var server: MockWebServer
    private lateinit var store: InMemorySecretStore
    private lateinit var secrets: ProfileSecretStore
    private val id = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        store = InMemorySecretStore()
        secrets = ProfileSecretStore(store)
    }
    @After fun tearDown() { server.shutdown() }

    private fun enrollment(token: String = "tok", base: String? = server.url("/").toString().trimEnd('/')) =
        Enrollment(secrets, { base }, { token }, OkHttpClient(), maxAttempts = 3, backoff = {})

    @Test fun enrollsOnce_thenNeverTouchesTheNetworkAgain() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true,"created":true}"""))
        val e = enrollment()
        assertEquals(Enrollment.Outcome.Enrolled, e.ensureEnrolled(id))
        assertEquals(Enrollment.Outcome.AlreadyEnrolled, e.ensureEnrolled(id))
        assertEquals(Enrollment.Outcome.AlreadyEnrolled, enrollment().ensureEnrolled(id.lowercase()))
        assertEquals(1, server.requestCount)
    }

    @Test fun requestShape_tokenHeaderAndHashedSecret_neverRawSecret() = runTest {
        server.enqueue(MockResponse().setBody("{}"))
        enrollment().ensureEnrolled(id)
        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/enroll", r.path)
        assertEquals("tok", r.getHeader("X-PocketDJ-Enroll"))
        val body = Json.parseToJsonElement(r.body.readUtf8()).jsonObject
        val secret = secrets.secret()
        assertEquals(64, secret.length)
        assertEquals(id.lowercase(), body["profileId"]!!.jsonPrimitive.content)
        assertEquals(ProfileSecretStore.sha256Hex(secret), body["secretHash"]!!.jsonPrimitive.content)
        assertFalse(body.toString().contains(secret))
        assertEquals(null, r.getHeader("Authorization"))
    }

    @Test fun retriesOn5xx_thenSucceeds() = runTest {
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(MockResponse().setResponseCode(502))
        server.enqueue(MockResponse().setBody("{}"))
        assertEquals(Enrollment.Outcome.Enrolled, enrollment().ensureEnrolled(id))
        assertEquals(3, server.requestCount)
    }

    @Test fun persistent5xx_failsButIsNotRemembered() = runTest {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(500)) }
        val e = enrollment()
        assertTrue(e.ensureEnrolled(id) is Enrollment.Outcome.Failed)
        assertEquals("", secrets.enrolledProfileId())
        server.enqueue(MockResponse().setBody("{}"))
        assertEquals(Enrollment.Outcome.Enrolled, e.ensureEnrolled(id))
    }

    @Test fun refusesOn403_withoutRetry_andStaysRefused() = runTest {
        server.enqueue(MockResponse().setResponseCode(403))
        val e = enrollment()
        assertEquals(Enrollment.Outcome.Refused(403), e.ensureEnrolled(id))
        assertEquals(Enrollment.Outcome.Refused(403), e.ensureEnrolled(id))
        assertEquals(1, server.requestCount)
        assertEquals("", secrets.enrolledProfileId())
    }

    @Test fun conflict409_meansRelink_andIsRemembered() = runTest {
        server.enqueue(MockResponse().setResponseCode(409))
        val e = enrollment()
        assertEquals(Enrollment.Outcome.RelinkRequired, e.ensureEnrolled(id))
        assertEquals(Enrollment.Outcome.RelinkRequired, e.ensureEnrolled(id))
        assertEquals(1, server.requestCount)
    }

    @Test fun noBase_isDisabled_noNetwork() = runTest {
        assertEquals(Enrollment.Outcome.Disabled, enrollment(base = null).ensureEnrolled(id))
        assertEquals(0, server.requestCount)
        assertFalse(secrets.hasSecret())
    }

    @Test fun noToken_isNotConfigured_noNetwork() = runTest {
        assertEquals(Enrollment.Outcome.NotConfigured, enrollment(token = "").ensureEnrolled(id))
        assertEquals(0, server.requestCount)
    }

    @Test fun secretLivesOnlyInSecretStore_andIsStable() = runTest {
        val a = secrets.secretOrMint()
        assertEquals(a, secrets.secretOrMint())
        assertEquals(a, store.get(ProfileSecretStore.SECRET))
        assertFalse(secrets.toString().contains(a))
    }

    @Test fun adoptAndSnapshotRestore() {
        val mine = secrets.secretOrMint()
        val snap = secrets.snapshot()
        secrets.adopt(id, "ab".repeat(32))
        assertEquals("ab".repeat(32), secrets.secret())
        assertEquals(id.lowercase(), secrets.enrolledProfileId())
        secrets.restore(snap)
        assertEquals(mine, secrets.secret())
        assertEquals("", secrets.enrolledProfileId())
    }
}

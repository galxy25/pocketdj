package com.levi.pocketdj.data.sync

import com.levi.pocketdj.data.credentials.InMemorySecretStore
import com.levi.pocketdj.onboarding.LinkProbeResult
import com.levi.pocketdj.screens.settings.sections.SyncUi
import java.io.IOException
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Q120: "This profile was deleted on another device" - detection, copy, and Start fresh. */
class ProfileRecoveryTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var secrets: ProfileSecretStore
    private lateinit var profile: ProfileStore
    private val oldSecret = "ab".repeat(32)

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        secrets = ProfileSecretStore(InMemorySecretStore())
        profile = ProfileStore(tmp.newFile(ProfileStore.FILE_NAME).also { it.delete() })
        profile.setName("DJ Levi")
        secrets.adopt(profile.id, oldSecret)
    }

    @After fun tearDown() { server.shutdown() }

    private fun db() = S3CloudDocDatabase(
        baseUrl = { server.url("/").toString().trimEnd('/') }, profileId = { profile.id }, secrets = secrets,
        http = OkHttpClient(),
        enrollment = Enrollment(secrets, { server.url("/").toString() }, { "tok" }, OkHttpClient(), backoff = {}),
    )

    @Test fun problemIsDeletedOnlyForAConfigured401NotFor409OrUnconfigured() {
        assertEquals(ProfileSyncProblem.DELETED, ProfileSyncProblem.of(configured = true, unauthorized = true, relinkRequired = false))
        assertEquals(ProfileSyncProblem.LOCKED, ProfileSyncProblem.of(configured = true, unauthorized = true, relinkRequired = true))
        assertNull(ProfileSyncProblem.of(configured = true, unauthorized = false, relinkRequired = false))
        assertNull("no profileSyncBase: no request is ever made, nothing can be deleted", ProfileSyncProblem.of(false, true, false))
    }

    @Test fun deletedStateGetsItsOwnCaptionInsteadOfTheGenericOne() {
        assertEquals(SyncUi.PROFILE_DELETED_CAPTION, SyncUi.caption(false, null, "Account unavailable", ProfileSyncProblem.DELETED))
        assertEquals("a locked (409) profile keeps the generic copy", SyncUi.NO_ACCOUNT, SyncUi.caption(false, null, null, ProfileSyncProblem.LOCKED))
        assertEquals(SyncUi.NO_ACCOUNT, SyncUi.caption(false, null, null))
        assertTrue(SyncUi.relinkMessage(LinkProbeResult.Existing("Levi")).startsWith("Linked to Levi"))
        assertEquals("nope", SyncUi.relinkMessage(LinkProbeResult.Unavailable("nope")))
    }

    /** The other device ran Delete account: this device's next request is a 401 -> DELETED, and syncing stops. */
    @Test fun a401AfterRemoteDeleteSurfacesDeletedAndStopsSync() = runTest {
        secrets.markEnrolled(profile.id)
        server.enqueue(MockResponse().setResponseCode(401))
        val d = db()
        assertTrue(d.accountAvailable())
        try { d.fetchMeta(listOf("profile")); fail() } catch (e: IOException) { assertTrue(e.message!!.contains("401")) }
        assertTrue(d.unauthorized.value)
        assertEquals(ProfileSyncProblem.DELETED, ProfileSyncProblem.of(true, d.unauthorized.value, secrets.relinkRequiredFor(profile.id)))
        assertFalse("no further uploads", d.accountAvailable())
        assertEquals(1, server.requestCount)
    }

    @Test fun startFreshMintsANewIdentityKeepsTheNameAndMakesNoRequest() = runTest {
        secrets.markEnrolled(profile.id)
        server.enqueue(MockResponse().setResponseCode(401))
        val d = db()
        runCatching { d.fetchMeta(listOf("profile")) }
        assertTrue(d.unauthorized.value)
        val oldId = profile.id
        var forgot = 0
        val recovery = ProfileRecovery(secrets, profile::adoptIdentity, d::clearUnauthorized, { forgot++ })

        val newId = recovery.startFresh()

        assertEquals(newId, profile.id)
        assertNotEquals(oldId, profile.id)
        assertEquals("local name kept", "DJ Levi", profile.name)
        assertFalse("the dead secret is gone", secrets.hasSecret())
        assertEquals("", secrets.enrolledProfileId())
        assertFalse(d.unauthorized.value)
        assertFalse("flag cleared for the new id too", secrets.unauthorizedFor(newId))
        assertEquals(1, forgot)
        assertEquals("Start fresh itself sends nothing", 1, server.requestCount)
        assertEquals(null, ProfileSyncProblem.of(true, d.unauthorized.value, secrets.relinkRequiredFor(profile.id)))
    }

    /** After Start fresh the next (opted-in) pass enrolls the NEW id with a NEW secret - never the deleted one. */
    @Test fun nextPassAfterStartFreshEnrollsTheNewIdentity() = runTest {
        secrets.markEnrolled(profile.id)
        val d = db()
        server.enqueue(MockResponse().setResponseCode(401))
        runCatching { d.fetchMeta(listOf("profile")) }
        server.takeRequest()
        ProfileRecovery(secrets, profile::adoptIdentity, d::clearUnauthorized, {}).startFresh()

        server.enqueue(MockResponse().setResponseCode(200))
        assertTrue(d.accountAvailable())
        val enroll = server.takeRequest()
        assertEquals("/enroll", enroll.path)
        val body = enroll.body.readUtf8()
        assertTrue(body, body.contains(profile.id.lowercase()))
        assertFalse("never the deleted secret", body.contains(ProfileSecretStore.sha256Hex(oldSecret)))
        assertTrue(secrets.secret() != oldSecret && secrets.hasSecret())
    }
}

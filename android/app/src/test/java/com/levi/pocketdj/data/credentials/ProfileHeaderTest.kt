package com.levi.pocketdj.data.credentials

import com.levi.pocketdj.data.jukebox.JukeboxClient
import com.levi.pocketdj.data.rips.RipServerClient
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class ProfileHeaderTest {
    private lateinit var server: MockWebServer
    private var profileId = ""

    @Before fun setUp() { server = MockWebServer().also { it.start() }; profileId = "" }
    @After fun tearDown() { server.shutdown() }

    private fun rip() = RipServerClient(OkHttpClient(), configProvider = {
        RipServerClient.Config(server.url("/").toString(), "tok", "dev-1", profileId = profileId)
    })

    private fun jukebox() = JukeboxClient(OkHttpClient(), configProvider = {
        JukeboxClient.Config(server.url("/").toString(), "tok", "dev-1", profileId = profileId)
    })

    @Test fun helper_omitsBlank_trimsPresent() {
        assertNull(ProfileHeader.apply(Request.Builder().url("http://x/"), "  ").build().header(ProfileHeader.NAME))
        assertEquals("abc", ProfileHeader.apply(Request.Builder().url("http://x/"), " abc ").build().header("X-PocketDJ-Profile"))
    }

    @Test fun ripClient_sendsProfileOnlyWhenEnrolled() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true,"version":2}"""))
        rip().health()
        assertNull(server.takeRequest().getHeader("X-PocketDJ-Profile"))

        profileId = "7f3a-profile"
        server.enqueue(MockResponse().setBody("""{"ok":true,"version":2}"""))
        rip().health()
        val r = server.takeRequest()
        assertEquals("7f3a-profile", r.getHeader("X-PocketDJ-Profile"))
        assertEquals("dev-1", r.getHeader("X-PocketDJ-Device"))
        assertEquals("Bearer tok", r.getHeader("Authorization"))
    }

    @Test fun ripClient_candidateHealthProbeKeepsProfile() = runTest {
        profileId = "pid"
        server.enqueue(MockResponse().setBody("""{"ok":true,"version":2}"""))
        rip().health(candidateUrl = server.url("/").toString(), candidateToken = "t2")
        assertEquals("pid", server.takeRequest().getHeader("X-PocketDJ-Profile"))
    }

    @Test fun jukeboxClient_sendsProfileOnlyWhenEnrolled() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        runCatching { jukebox().health() }
        assertNull(server.takeRequest().getHeader("X-PocketDJ-Profile"))

        profileId = "pid-2"
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        runCatching { jukebox().health() }
        val r = server.takeRequest()
        assertEquals("pid-2", r.getHeader("X-PocketDJ-Profile"))
        assertEquals("dev-1", r.getHeader("X-PocketDJ-Device"))
    }
}

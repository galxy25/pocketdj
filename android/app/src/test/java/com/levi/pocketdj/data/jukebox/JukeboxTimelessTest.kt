package com.levi.pocketdj.data.jukebox

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.history.HistorySelection
import com.levi.pocketdj.screens.mix.MixBroadcastAction
import com.levi.pocketdj.screens.nowplaying.NowPlayingShareText
import com.levi.pocketdj.ui.selection.SelectionBarSemantics
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

class JukeboxTimelessTest {
    private lateinit var server: MockWebServer
    private lateinit var client: JukeboxClient

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        val base = server.url("/").toString().removeSuffix("/")
        client = JukeboxClient(OkHttpClient(), PdjJson.lenient, { JukeboxClient.Config(base, "srv", "inst") })
    }

    @After fun tearDown() = server.shutdown()

    private val session = JukeboxSessionInfo(jukeboxId = "jb1", hostKey = "HK", name = "P", expiresAt = 1.7e12)

    @Test fun create_sendsTimelessFlag() = runTest {
        server.enqueue(MockResponse().setBody("""{"jukeboxId":"jb1","hostKey":"HK","timeless":true}"""))
        val info = client.createSession("Party", requiresToken = true, timeless = true)
        assertEquals(true, info.timeless)
        val req = server.takeRequest()
        assertEquals("/jukebox", req.path)
        assertEquals("Bearer srv", req.getHeader("Authorization"))
        val body = PdjJson.lenient.parseToJsonElement(req.body.readUtf8()).jsonObject
        assertEquals("true", body["timeless"]!!.jsonPrimitive.content)
        assertEquals("true", body["requiresToken"]!!.jsonPrimitive.content)
    }

    @Test fun create_defaultStaysNotTimeless() = runTest {
        server.enqueue(MockResponse().setBody("""{"jukeboxId":"jb1","hostKey":"HK"}"""))
        client.createSession("Party", requiresToken = false)
        val body = PdjJson.lenient.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("false", body["timeless"]!!.jsonPrimitive.content)
    }

    @Test fun configure_postsToConfigWithHostKey() = runTest {
        server.enqueue(MockResponse().setBody("""{"ok":true,"timeless":true,"extra":1}"""))
        val reply = client.configure(session, timeless = true)
        assertEquals(true, reply.timeless)
        assertNull(reply.expiresAt)
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/jukebox/jb1/config", req.path)
        assertEquals("Bearer HK", req.getHeader("Authorization"))
        assertEquals("""{"timeless":true}""", req.body.readUtf8())
    }

    @Test fun configure_errorSurfacesCode() = runTest {
        server.enqueue(MockResponse().setResponseCode(410))
        try {
            client.configure(session, true)
            org.junit.Assert.fail("expected")
        } catch (e: JukeboxClient.JukeboxException) {
            assertEquals(410, e.code)
        }
    }

    @Test fun urls_config() {
        assertEquals("http://h:8788/jukebox/a%20b/config", JukeboxUrls.config("http://h:8788/", "a b").toString())
    }

    @Test fun merge_timelessClearsExpiry() {
        val merged = session.mergeLifecycle(JukeboxLifecycle(timeless = true, expiresAt = 5.0), requestedTimeless = true)
        assertEquals(true, merged.timeless)
        assertNull(merged.expiresAt)
        assertEquals("HK", merged.hostKey)
    }

    @Test fun merge_offAdoptsServerExpiry() {
        val on = session.copy(timeless = true, expiresAt = null)
        val merged = on.mergeLifecycle(JukeboxLifecycle(timeless = false, expiresAt = 9.0e12), requestedTimeless = false)
        assertEquals(false, merged.timeless)
        assertEquals(9.0e12, merged.expiresAt!!, 0.0)
    }

    @Test fun merge_missingReplyFieldsFallBackToRequest() {
        val merged = session.mergeLifecycle(JukeboxLifecycle(), requestedTimeless = true)
        assertEquals(true, merged.timeless)
        assertNull(merged.expiresAt)
        val off = session.copy(timeless = true, expiresAt = null).mergeLifecycle(JukeboxLifecycle(), false)
        assertEquals(false, off.timeless)
    }

    @Test fun sessionJsonWithoutNewFieldsIsByteStable() {
        val json = PdjJson.lenient
        val decoded = json.decodeFromString<JukeboxSessionInfo>("""{"jukeboxId":"j","hostKey":"k","name":"n","url":"u"}""")
        assertNull(decoded.timeless)
        val once = json.encodeToString(JukeboxSessionInfo.serializer(), decoded)
        val twice = json.encodeToString(JukeboxSessionInfo.serializer(), json.decodeFromString<JukeboxSessionInfo>(once))
        assertEquals(once, twice)
    }

    // ---- Mix antenna decision ----
    @Test fun broadcast_decisions() {
        assertEquals(MixBroadcastAction.OPEN, MixBroadcastAction.decide(true, false, true))
        assertEquals(MixBroadcastAction.OPEN, MixBroadcastAction.decide(false, true, true))
        assertEquals(MixBroadcastAction.CREATE_THEN_OPEN, MixBroadcastAction.decide(false, false, true))
        assertEquals(MixBroadcastAction.OPEN_UNCONFIGURED, MixBroadcastAction.decide(false, false, false))
    }

    // ---- Share ----
    private val song = IndexSong(id = "s1", name = "Title", artist = "Art")

    @Test fun npShare_catalogSongUsesForSong() {
        val t = NowPlayingShareText.build(true, "s1", "x", "y", mapOf("s1" to song))
        assertTrue(t!!.startsWith("Title — Art"))
    }

    @Test fun npShare_unknownIdUsesTitleArtist() {
        val t = NowPlayingShareText.build(true, "zz", "Foo", "Bar", mapOf("s1" to song))
        assertTrue(t!!.startsWith("Foo — Bar"))
    }

    @Test fun npShare_hiddenWhenNothingPlays() {
        assertNull(NowPlayingShareText.build(false, null, "Nothing playing", "", null))
        assertNull(NowPlayingShareText.build(true, null, " ", "", null))
    }

    @Test fun selectionShare_joinsSongsAndSkipsUnknown() {
        val s2 = IndexSong(id = "s2", name = "Two", artist = "B")
        val text = SelectionBarSemantics.shareText(listOf("s1", "gone", "s2"), mapOf("s1" to song, "s2" to s2))!!
        assertTrue(text.contains("\n\n"))
        assertTrue(text.indexOf("Title") < text.indexOf("Two"))
        assertNull(SelectionBarSemantics.shareText(listOf("gone"), mapOf("s1" to song)))
        assertFalse(text.contains("gone"))
    }

    @Test fun historySelection_dedupesSongsInDisplayOrder() {
        val events = listOf("e3" to "a", "e2" to "b", "e1" to "a")
        assertEquals(listOf("a", "b"), HistorySelection.songIds(setOf("e1", "e2", "e3"), events))
        assertEquals(listOf("b"), HistorySelection.songIds(setOf("e2"), events))
        assertEquals(emptyList<String>(), HistorySelection.songIds(emptySet(), events))
    }
}

package com.levi.pocketdj.data.applemusic

import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AppleMusicLibraryPlaylistsTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer().also { it.start() } }
    @After fun tearDown() { server.shutdown() }

    private fun transport(user: String? = "mut"): WebApiPlaylistWriteBackTransport {
        val tokens = StaticAppleMusicTokens("dev", user)
        val api = AppleMusicApi(
            OkHttpClient(), tokens, baseUrl = server.url("/").toString().trimEnd('/'), sleeper = {},
        )
        return WebApiPlaylistWriteBackTransport(api, tokens)
    }

    private fun ok(body: String) = MockResponse().setResponseCode(200).setBody(body)

    private fun playlists(vararg p: Triple<String, String, Boolean?>): String =
        p.joinToString(prefix = """{"data":[""", postfix = "]}") { (id, name, edit) ->
            val e = edit?.let { ""","canEdit":$it""" }.orEmpty()
            """{"id":"$id","attributes":{"name":"$name"$e}}"""
        }

    private fun tracks(vararg catalogIds: String, next: Boolean = false): String =
        catalogIds.joinToString(prefix = """{"data":[""", postfix = "]" + (if (next) ""","next":"/x"""" else "") + "}") {
            """{"id":"i.$it","attributes":{"playParams":{"catalogId":"$it"}}}"""
        }

    private fun pl(id: String, name: String, edit: Boolean? = null) = AmLibraryPlaylist(id, name, edit ?: true)

    // ---- name tiers ----
    @Test fun resolveTiers_exactBeatsTrimmedBeatsFolded() {
        val all = listOf(pl("1", "Sap"), pl("2", "SAP"), pl("3", "Café"))
        // exact tier wins even though "Sap " would also trim-match
        assertEquals(listOf("1"), WriteBackPlaylistMatcher.candidates("Sap", all).map { it.id })
        // THE "Sap " CASE: trailing space in the index, trimmed in the live library
        assertEquals(listOf("1"), WriteBackPlaylistMatcher.candidates("Sap ", all).map { it.id })
        // folded tier: case + diacritics
        assertEquals(listOf("3"), WriteBackPlaylistMatcher.candidates("cafe", all).map { it.id })
        assertTrue(WriteBackPlaylistMatcher.candidates("Nope", all).isEmpty())
    }

    @Test fun resolveTiers_throughTransport_sapWithTrailingSpace() = runTest {
        server.enqueue(ok(playlists(Triple("p.1", "Sap", null), Triple("p.2", "Other", null))))
        assertEquals("p.1", transport().resolvePlaylistId("Sap ", emptyList()))
        assertNull(transport().also { server.enqueue(ok(playlists(Triple("p.9", "Zed", null)))) }.resolvePlaylistId("Sap ", emptyList()))
    }

    @Test fun resolveSkipsPlaylistsTheUserCannotEdit() = runTest {
        server.enqueue(ok(playlists(Triple("ro", "Mix", false), Triple("rw", "Mix", true))))
        val t = transport()
        assertEquals("rw", t.resolvePlaylistId("Mix", emptyList()))
        assertNull(t.lastResolutionNote) // one editable candidate = unambiguous
    }

    // ---- duplicate-name arbitration ----
    @Test fun overlapArbitration_picksPlaylistWhoseTracksOverlapTheIndex() = runTest {
        server.enqueue(ok(playlists(Triple("a", "Mix", null), Triple("b", "Mix", null))))
        server.enqueue(ok(tracks("x1")))               // a: 0 overlap
        server.enqueue(ok(tracks("k1", "k2", "x9")))   // b: 2 overlap
        val t = transport()
        assertEquals("b", t.resolvePlaylistId("Mix", listOf("k1", "k2", "k3")))
        assertNull(t.lastResolutionNote)
    }

    @Test fun noOverlapIsAGuessAndSaysSo() = runTest {
        server.enqueue(ok(playlists(Triple("a", "Mix", null), Triple("b", "Mix", null))))
        server.enqueue(ok(tracks("x1")))
        server.enqueue(ok(tracks("x2")))
        val t = transport()
        assertEquals("a", t.resolvePlaylistId("Mix", listOf("k1")))
        assertNotNull(t.lastResolutionNote)
        assertTrue(t.lastResolutionNote!!.contains("Several Apple Music playlists are called"))
    }

    // ---- pre-check + append ----
    @Test fun precheckSkipsAppend_whenCatalogIdAlreadyInPlaylist() = runTest {
        server.enqueue(ok(tracks("111", "222")))
        transport().addSong("222", "p.1")
        assertEquals(1, server.requestCount)
        assertEquals("GET", server.takeRequest().method) // no POST ever went out
    }

    @Test fun appendPostsCatalogSongRefAfterMembershipRead() = runTest {
        server.enqueue(ok(tracks("111")))
        server.enqueue(MockResponse().setResponseCode(204))
        transport().addSong("222", "p.1")
        val get = server.takeRequest(); val post = server.takeRequest()
        assertEquals("GET", get.method); assertEquals("POST", post.method)
        assertTrue(post.path!!.startsWith("/v1/me/library/playlists/p.1/tracks"))
        assertEquals("""{"data":[{"id":"222","type":"songs"}]}""", post.body.readUtf8())
        assertEquals("mut", post.getHeader("Music-User-Token"))
    }

    @Test fun emptyPlaylist404OnTheTracksReadStillAppends() = runTest {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(204))
        transport().addSong("222", "p.new")
        assertEquals(2, server.requestCount)
    }

    @Test fun post404MeansPlaylistGone() = runTest {
        server.enqueue(ok(tracks()))
        server.enqueue(MockResponse().setResponseCode(404))
        try { transport().addSong("222", "p.gone"); error("expected throw") }
        catch (e: WriteBackException.PlaylistGone) { /* expected */ }
    }

    @Test fun pagination_membershipReadWalksEveryPageBeforeDecidingToAppend() = runTest {
        // Page 1: a FULL page of 100 rows (deduped ids < 100) with a next cursor; target lives on page 2.
        val page1 = (1..100).joinToString(prefix = """{"data":[""", postfix = """],"next":"/v1/me/library/playlists/p.1/tracks?offset=100"}""") {
            """{"id":"i.$it","attributes":{"playParams":{"catalogId":"${if (it > 99) "1" else it.toString()}"}}}"""
        }
        server.enqueue(ok(page1))
        server.enqueue(ok(tracks("777")))
        transport().addSong("777", "p.1")
        assertEquals(2, server.requestCount)
        assertTrue(server.takeRequest().path!!.contains("offset=0"))
        assertTrue(server.takeRequest().path!!.contains("offset=100"))
    }

    // ---- auth + errors ----
    @Test fun noUserTokenIsNotAuthorizedAndNeverHitsTheNetwork() = runTest {
        val t = transport(user = null)
        assertEquals(false, t.canWrite())
        try { t.addSong("1", "p"); error("expected throw") } catch (_: WriteBackException.NotAuthorized) {}
        try { t.resolvePlaylistId("x", emptyList()); error("expected throw") } catch (_: WriteBackException.NotAuthorized) {}
        assertEquals(0, server.requestCount)
    }

    @Test fun http403OnWriteMapsToNotAuthorized_5xxToHttp() = runTest {
        server.enqueue(ok(tracks()))
        server.enqueue(MockResponse().setResponseCode(403))
        try { transport().addSong("1", "p"); error("expected throw") } catch (_: WriteBackException.NotAuthorized) {}
        server.enqueue(ok(tracks()))
        server.enqueue(MockResponse().setResponseCode(500))
        try { transport().addSong("1", "p"); error("expected throw") }
        catch (e: WriteBackException.Http) { assertEquals(500, e.status) }
    }

    // ---- catalog resolution ----
    @Test fun resolveCatalogId_usesUserStorefrontAndTheSharedMatcher() = runTest {
        server.enqueue(ok("""{"data":[{"id":"gb"}]}"""))
        server.enqueue(ok("""{"results":{"songs":{"data":[
            {"id":"500","attributes":{"name":"Halo","artistName":"Beyoncé","albumName":"I Am","durationInMillis":261000}},
            {"id":"600","attributes":{"name":"Halo (Live)","artistName":"Beyoncé","durationInMillis":300000}}]}}}"""))
        val id = transport().resolveCatalogId(WriteBackSong("", "Halo", "Beyoncé", "I Am", 261_000))
        assertEquals("500", id)
        assertTrue(server.takeRequest().path!!.startsWith("/v1/me/storefront"))
        assertTrue(server.takeRequest().path!!.startsWith("/v1/catalog/gb/search"))
    }

    @Test fun resolveCatalogId_blankIdentityIsNullWithoutNetwork() = runTest {
        assertNull(transport().resolveCatalogId(WriteBackSong("", "", "A")))
        assertEquals(0, server.requestCount)
    }
}

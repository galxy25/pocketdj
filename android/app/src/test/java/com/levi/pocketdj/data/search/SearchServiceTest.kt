package com.levi.pocketdj.data.search

import com.levi.pocketdj.net.SigV4
import com.levi.pocketdj.screens.browse.BrowseKind
import com.levi.pocketdj.screens.browse.Clause
import com.levi.pocketdj.screens.browse.FilterOp
import com.levi.pocketdj.screens.browse.SortField
import com.levi.pocketdj.screens.browse.SortKey
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class SearchServiceTest {
    private lateinit var server: MockWebServer
    private val creds = SigV4.Creds("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    private val cfg = SearchConfig({ null }, generation = { "g" })
    private lateinit var svc: SearchService

    private val twoHits = """{"hits":{"total":{"value":123,"relation":"eq"},"hits":[
      {"_id":"s1","_source":{"type":"song","title":"Midnight","artist":"A","album":"Alb","albumId":"a1","genre":"House","year":1999,"bpm":124.5,"key":"Am","camelot":"8A","explicit":true,"trackNumber":3,"source":"My Vinyl"}},
      {"_id":"a1","_source":{"type":"album","title":"Alb","artist":"A"}}]}}"""

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
        svc = SearchService(OkHttpClient(), cfg, now = { 1_440_000_000_000L }, baseUrl = { server.url("").toString().trimEnd('/') })
    }

    @After fun tearDown() = server.shutdown()

    private fun body(): kotlinx.serialization.json.JsonObject =
        Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject

    @Test fun postsSignedRequestToIndexSearchPath() = runBlocking {
        server.enqueue(MockResponse().setBody(twoHits))
        svc.search("midnight", BrowseKind.SONGS, emptyList(), emptyList(), creds, 0, 50)
        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/pocketdj/_search", r.path)
        val auth = r.getHeader("Authorization")!!
        assertTrue(auth, auth.startsWith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150819/us-west-2/aoss/aws4_request"))
        assertTrue(auth, auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date,"))
        assertEquals("20150819T160000Z", r.getHeader("x-amz-date"))
        assertEquals(SigV4.sha256Hex(r.body.readUtf8().toByteArray()), r.getHeader("x-amz-content-sha256"))
    }

    @Test fun parsesTotalAndFlattensHits() = runBlocking {
        server.enqueue(MockResponse().setBody(twoHits))
        val res = svc.search("m", null, emptyList(), emptyList(), creds, 0, 50)
        assertEquals(123, res.total)
        assertEquals(listOf("s1", "a1"), res.hits.map { it.id })
        val s = res.hits[0]
        assertEquals("song", s.type); assertEquals("Midnight", s.title); assertEquals(124.5, s.bpm!!, 0.0)
        assertEquals(1999, s.year); assertEquals(true, s.explicit); assertEquals(3, s.trackNumber)
        assertEquals("8A", s.camelot); assertEquals("My Vinyl", s.source); assertEquals("a1", s.albumId)
        assertEquals("album", res.hits[1].type)
        assertNull(res.hits[1].bpm)
    }

    @Test fun missingTypeDefaultsToSong() {
        val r = SearchService.parse("""{"hits":{"total":{"value":1},"hits":[{"_id":"x","_source":{"title":"T"}}]}}""")
        assertEquals("song", r.hits.single().type)
    }

    @Test fun multiMatchBodyShapeForQuery() = runBlocking {
        server.enqueue(MockResponse().setBody(twoHits))
        svc.search("  midnight  ", BrowseKind.ALBUMS, emptyList(), emptyList(), creds, 50, 50)
        val b = body()
        assertEquals(50, b["from"].toString().toInt())
        val must = b["query"]!!.jsonObject["bool"]!!.jsonObject["must"]!!.jsonArray[0].jsonObject["multi_match"]!!.jsonObject
        assertEquals("\"midnight\"", must["query"].toString())
        assertEquals(
            listOf("title^3", "artist^2", "album^1.5", "lyrics", "sentiment^2"),
            must["fields"]!!.jsonArray.map { it.toString().trim('"') },
        )
        assertEquals("\"best_fields\"", must["type"].toString())
        assertEquals("\"AUTO\"", must["fuzziness"].toString())
        assertEquals("\"and\"", must["operator"].toString())
        val filter = b["query"]!!.jsonObject["bool"]!!.jsonObject["filter"]!!.jsonArray
        assertEquals("""{"term":{"type":"album"}}""", filter[0].toString())
    }

    @Test fun emptyQueryIsMatchAllAndArtistKindHasNoTypeFilter() = runBlocking {
        server.enqueue(MockResponse().setBody(twoHits))
        svc.search("   ", null, emptyList(), emptyList(), creds, 0, 50)
        val bool = body()["query"]!!.jsonObject["bool"]!!.jsonObject
        assertEquals("""[{"match_all":{}}]""", bool["must"].toString())
        assertEquals("[]", bool["filter"].toString())
        assertNull(bool["must_not"])
    }

    @Test fun clausesAndSortReachTheWire() = runBlocking {
        server.enqueue(MockResponse().setBody(twoHits))
        svc.search(
            "", BrowseKind.SONGS,
            listOf(Clause("genre", FilterOp.NOT_IN_LIST, values = linkedSetOf("Rock")), Clause("bpm", FilterOp.BETWEEN, min = 120.0)),
            listOf(SortKey(SortField.BPM, ascending = false)), creds, 0, 50,
        )
        val b = body()
        val bool = b["query"]!!.jsonObject["bool"]!!.jsonObject
        assertEquals("""{"range":{"bpm":{"gte":120}}}""", bool["filter"]!!.jsonArray[1].toString())
        assertEquals("""[{"terms":{"genreCategory":["rock"]}}]""", bool["must_not"].toString())
        assertEquals("""[{"bpm":{"order":"desc"}},{"id":{"order":"asc"}}]""", b["sort"].toString())
    }

    @Test fun non2xxThrowsWithTruncatedBody() {
        server.enqueue(MockResponse().setResponseCode(403).setBody("x".repeat(500)))
        try {
            runBlocking { svc.search("q", null, emptyList(), emptyList(), creds, 0, 50) }
            fail("expected")
        } catch (e: SearchFailedException) {
            assertEquals(403, e.code)
            assertEquals("Search failed (403): " + "x".repeat(180), e.message)
        }
    }

    // ---- SearchConfig host resolution ----

    @Test fun configDefaultsWhenFetchFails() = runBlocking {
        val c = SearchConfig({ null }, generation = { "g" })
        assertEquals(ResolvedSearchConfig(), c.resolved())
    }

    @Test fun configOverlaysOnlyNonEmptyRemoteFields() = runBlocking {
        val c = SearchConfig({ """{"host":"new.aoss.example","region":"","index":"idx2"}""" }, generation = { "g" })
        val r = c.resolved()
        assertEquals("new.aoss.example", r.host)
        assertEquals("us-west-2", r.region)
        assertEquals("idx2", r.index)
    }

    @Test fun userOverrideWinsAndIsStrippedToBareHost() = runBlocking {
        val c = SearchConfig({ """{"host":"remote.example"}""" }, generation = { "g" })
        c.setUserHost("  https://my.host.example/some/path ")
        assertEquals("my.host.example", c.resolved().host)
        c.setUserHost("   ")
        assertEquals("remote.example", c.resolved().host)
    }

    @Test fun configIsMemoisedUntilGenerationChanges() = runBlocking {
        var fetches = 0
        var gen = "blue"
        val c = SearchConfig({ fetches++; """{"host":"h$fetches"}""" }, generation = { gen })
        assertEquals("h1", c.resolved().host)
        assertEquals("h1", c.resolved().host)
        assertEquals(1, fetches)
        gen = "green"
        assertEquals("h2", c.resolved().host)
        assertEquals(2, fetches)
    }

    @Test fun configFetchUsesTheConfigUrl() = runBlocking {
        var seen: String? = null
        val c = SearchConfig({ seen = it; null }, generation = { "g" }, configUrl = { "https://x/search-config.json" })
        c.resolved()
        assertEquals("https://x/search-config.json", seen)
        assertNotNull(seen)
    }

    @Test fun garbageConfigKeepsDefaults() {
        assertEquals(ResolvedSearchConfig(), SearchConfig.parse("<html>spa fallback</html>"))
    }
}

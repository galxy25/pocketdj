package com.levi.pocketdj.data.applemusic

import java.io.File
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppleMusicLibraryIndexerTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private val paths = mutableListOf<String>()
    private var songPages: List<String> = emptyList()
    private var songsStatus = 200
    private var playlistsBody = """{"data":[]}"""
    private var albumsBody = """{"data":[]}"""
    private var playlistTracks = mapOf<String, String>()

    @Before fun setUp() {
        server = MockWebServer().also {
            it.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val path = request.path!!
                    paths += path
                    val offset = Regex("offset=(\\d+)").find(path)?.groupValues?.get(1)?.toInt() ?: 0
                    return when {
                        path.startsWith("/v1/me/library/songs") ->
                            if (songsStatus != 200) MockResponse().setResponseCode(songsStatus)
                            else MockResponse().setBody(songPages[offset / PAGE])
                        path.startsWith("/v1/me/library/albums") -> MockResponse().setBody(albumsBody)
                        path.startsWith("/v1/me/library/playlists/") ->
                            MockResponse().setBody(
                                if (offset > 0) """{"data":[]}"""
                                else playlistTracks[path.substringAfter("playlists/").substringBefore("/")] ?: """{"data":[]}""")
                        path.startsWith("/v1/me/library/playlists") -> MockResponse().setBody(playlistsBody)
                        else -> MockResponse().setResponseCode(404)
                    }
                }
            }
            it.start()
        }
    }

    @After fun tearDown() { server.shutdown() }

    private val store by lazy { AppleMusicLibraryStore(File(tmp.root, "lib.json")) }
    private var now = 5_000.0
    private fun indexer(user: String? = "mut") = AppleMusicLibraryIndexer(
        AppleMusicApi(OkHttpClient(), StaticAppleMusicTokens("dev", user), baseUrl = server.url("/").toString().trimEnd('/'), sleeper = {}),
        store, nowMs = { now }, pageSize = PAGE,
    )

    private fun row(id: String, name: String, artist: String = "Art", album: String? = "Alb", cat: String? = null, track: Int? = null, dateAdded: String? = null, extra: String = ""): String {
        val attrs = buildString {
            append("\"name\":\"$name\",\"artistName\":\"$artist\"")
            if (album != null) append(",\"albumName\":\"$album\"")
            if (track != null) append(",\"trackNumber\":$track")
            if (dateAdded != null) append(",\"dateAdded\":\"$dateAdded\"")
            append(",\"durationInMillis\":180000,\"genreNames\":[\"Rock\"],\"releaseDate\":\"2019-05-01\"")
            append(",\"artwork\":{\"url\":\"https://x/{w}x{h}bb.jpg\"}")
            append(",\"playParams\":{\"id\":\"$id\",\"isLibrary\":true}")
            append(extra)
        }
        val rel = if (cat != null) ""","relationships":{"catalog":{"data":[{"id":"$cat","type":"songs"}]}}""" else ""
        return """{"id":"$id","type":"library-songs","attributes":{$attrs}$rel}"""
    }

    private fun page(rows: List<String>, nextOffset: Int? = null) =
        """{"data":[${rows.joinToString(",")}]${if (nextOffset != null) ""","next":"/v1/me/library/songs?offset=$nextOffset&limit=$PAGE"""" else ""}}"""

    @Test fun fullRunPagesIdsCatalogRelationshipAndGroupsAlbums() = runTest {
        songPages = listOf(
            page(listOf(row("i.1", "B-side", cat = "9001", track = 2), row("i.2", "A-side", cat = "9002", track = 1)), nextOffset = 2),
            page(listOf(row("i.3", "Solo", album = null))),
        )
        albumsBody = """{"data":[{"id":"l.1","attributes":{"name":"Alb","artistName":"Art","genreNames":["Pop"],"artwork":{"url":"https://alb/{w}x{h}.jpg"}}}]}"""
        val out = indexer().run()
        assertEquals(AppleMusicLibraryIndexer.Outcome.Indexed(songs = 3, added = 3, full = true), out)

        val s = store.songs
        assertEquals(listOf("amlib_i.1", "amlib_i.2", "amlib_i.3"), s.map { it.songId })
        assertEquals("9001", s[0].appleMusicId) // from the catalog relationship, never the i.… library id
        assertNull(s[2].appleMusicId)
        assertEquals("https://x/600x600bb.jpg", s[0].artworkUrl)
        assertEquals(2019, s[0].year)
        assertEquals("Rock", s[0].genre)
        assertEquals(5_000.0, s[0].addedAtMs, 0.0) // no dateAdded -> first-indexed time
        assertEquals(AppleMusicLibraryIndexer.albumId("Alb", "Art"), s[0].albumId)

        val alb = store.albums.single()
        assertEquals(listOf("amlib_i.2", "amlib_i.1"), alb.trackIds) // trackNumber order
        assertEquals("Rock", alb.genre) // song genre wins; the library album only fills gaps
        assertEquals("https://x/600x600bb.jpg", alb.artworkUrl)
        assertEquals(5_000.0, store.lastAddedMs!!, 0.0)
        assertTrue(paths.contains("/v1/me/library/songs?limit=$PAGE&offset=0&include=catalog"))
        assertTrue(paths.contains("/v1/me/library/songs?limit=$PAGE&offset=2&include=catalog"))
    }

    @Test fun dateAddedFromApiWinsAndKnownValueBeatsNowOnReindex() = runTest {
        songPages = listOf(page(listOf(row("i.1", "T", dateAdded = "2020-01-01T00:00:00Z"), row("i.2", "U"))))
        indexer().run()
        assertEquals(1_577_836_800_000.0, store.songs[0].addedAtMs, 0.0)
        // a pulled (iOS) add time for i.2 survives a full re-index when the API carries none
        store.replaceAll(store.songs.map { if (it.libraryId == "i.2") it.copy(addedAtMs = 777.0) else it }, emptyList(), emptyList(), 777.0)
        now = 9_000.0
        indexer().run(AppleMusicLibraryIndexer.Mode.FULL)
        assertEquals(777.0, store.songs.first { it.libraryId == "i.2" }.addedAtMs, 0.0)
    }

    @Test fun incrementalAppendsOnlyUnseenAndAdvancesMark() = runTest {
        songPages = listOf(page(listOf(row("i.1", "One"), row("i.2", "Two"))))
        indexer().run()
        assertEquals(2, store.songs.size)

        songPages = listOf(page(listOf(row("i.1", "One"), row("i.2", "Two"), row("i.3", "Three"))))
        now = 8_000.0
        val out = indexer().run()
        assertEquals(AppleMusicLibraryIndexer.Outcome.Indexed(songs = 3, added = 1, full = false), out)
        assertEquals(listOf("amlib_i.1", "amlib_i.2", "amlib_i.3"), store.songs.map { it.songId })
        assertEquals(5_000.0, store.songs[0].addedAtMs, 0.0) // untouched
        assertEquals(8_000.0, store.songs[2].addedAtMs, 0.0)
        assertEquals(8_000.0, store.lastAddedMs!!, 0.0)
        // idempotent: a third run adds nothing
        assertEquals(0, (indexer().run() as AppleMusicLibraryIndexer.Outcome.Indexed).added)
        assertEquals(3, store.songs.size)
    }

    @Test fun playlistsGetAmlibplIdsAndLibrarySongIdsInOrder() = runTest {
        songPages = listOf(page(listOf(row("i.1", "One"), row("i.2", "Two"))))
        playlistsBody = """{"data":[{"id":"p.A","attributes":{"name":"Road"}},{"id":"p.empty","attributes":{"name":"Empty"}}]}"""
        playlistTracks = mapOf("p.A" to """{"data":[{"id":"i.2","attributes":{}},{"id":"i.1","attributes":{}}]}""")
        indexer().run()
        val p = store.playlists
        assertEquals(listOf("amlibpl_p.A", "amlibpl_p.empty"), p.map { it.id })
        assertEquals(listOf("amlib_i.2", "amlib_i.1"), p[0].songIds)
        assertTrue(p[1].songIds.isEmpty()) // an empty playlist is still the user's playlist
    }

    @Test fun failedSongsReadLeavesStoreUntouched() = runTest {
        store.replaceAll(listOf(AppleMusicLibraryStore.SongEntry("amlib_i.k", "i.k", title = "Keep", addedAtMs = 1.0)), emptyList(), emptyList(), 1.0)
        songsStatus = 500
        val out = indexer().run(AppleMusicLibraryIndexer.Mode.FULL)
        assertEquals(AppleMusicLibraryIndexer.Outcome.Failed(500, "Apple Music API error (500)"), out)
        assertEquals(listOf("amlib_i.k"), store.songs.map { it.songId })
    }

    @Test fun failedPlaylistsReadKeepsExistingPlaylistsOnFullRun() = runTest {
        store.replaceAll(emptyList(), emptyList(), listOf(AppleMusicLibraryStore.PlaylistEntry("amlibpl_old", "Old", emptyList())), null)
        songPages = listOf(page(listOf(row("i.1", "One"))))
        playlistsBody = "garbage"
        indexer().run(AppleMusicLibraryIndexer.Mode.FULL)
        assertEquals(1, store.songs.size)
        assertEquals("Old", store.playlists.single().name)
    }

    @Test fun signedOutDoesNoNetworkAndReportsNeedsUserToken() = runTest {
        assertEquals(AppleMusicLibraryIndexer.Outcome.NeedsUserToken, indexer(user = null).run())
        assertEquals(0, server.requestCount)
    }

    @Test fun albumIdMatchesIosFnv1a() {
        // FNV-1a 64 of "title|artist" lowercased, zero-padded hex; golden computed independently.
        assertEquals("amlib_alb_" + fnv("abbey road|the beatles"), AppleMusicLibraryIndexer.albumId("Abbey Road", "The Beatles"))
        assertEquals("amlib_alb_" + fnv("|"), AppleMusicLibraryIndexer.albumId("", ""))
        assertEquals(AppleMusicLibraryIndexer.albumId("X", "Y"), AppleMusicLibraryIndexer.albumId("x", "y"))
    }

    @Test fun workResultMapping() {
        assertEquals(LibraryWorkResult.SUCCESS, libraryWorkResult(AppleMusicLibraryIndexer.Outcome.NeedsUserToken))
        assertEquals(LibraryWorkResult.RETRY, libraryWorkResult(AppleMusicLibraryIndexer.Outcome.RateLimited(3)))
        assertEquals(LibraryWorkResult.RETRY, libraryWorkResult(AppleMusicLibraryIndexer.Outcome.Failed(null, "io")))
        assertEquals(LibraryWorkResult.RETRY, libraryWorkResult(AppleMusicLibraryIndexer.Outcome.Failed(503, "x")))
        assertEquals(LibraryWorkResult.SUCCESS, libraryWorkResult(AppleMusicLibraryIndexer.Outcome.Failed(404, "x")))
    }

    private fun fnv(s: String): String {
        var h = java.math.BigInteger("cbf29ce484222325", 16)
        val prime = java.math.BigInteger("100000001b3", 16)
        val mod = java.math.BigInteger.ONE.shiftLeft(64)
        for (b in s.toByteArray()) h = h.xor(java.math.BigInteger.valueOf((b.toInt() and 0xff).toLong())).multiply(prime).mod(mod)
        return h.toString(16).padStart(16, '0')
    }

    private companion object { const val PAGE = 2 }
}

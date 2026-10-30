package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.CollectionsFactory
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.SongDuplicateJudge
import java.io.File
import kotlinx.coroutines.runBlocking
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

class PlaylistAppleMusicSyncReconcileTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer

    @Before fun up() { server = MockWebServer().also { it.start() } }
    @After fun down() { server.shutdown() }

    private fun rows(vararg cat: String) = cat.map { AmTrackRow("i.$it", it) }
    private fun edit(p: PlaylistReconcilePlanner.Plan) = p as PlaylistReconcilePlanner.Plan.Edit

    // ---- pure planner ---------------------------------------------------------------------

    @Test fun inSyncIsNoOp() {
        assertEquals(PlaylistReconcilePlanner.Plan.AlreadyInSync, PlaylistReconcilePlanner.plan(rows("a", "b"), listOf("a", "b")))
    }

    @Test fun removalOnlyDeletesJustTheStrays() {
        val p = edit(PlaylistReconcilePlanner.plan(rows("a", "x", "b", "y"), listOf("a", "b")))
        assertEquals(listOf("i.x", "i.y"), p.deleteLibraryIds)
        assertTrue(p.appendCatalogIds.isEmpty())
        assertEquals(0, p.added); assertEquals(2, p.removed)
    }

    @Test fun removalPlusTailAppend() {
        val p = edit(PlaylistReconcilePlanner.plan(rows("a", "x"), listOf("a", "b")))
        assertEquals(listOf("i.x"), p.deleteLibraryIds)
        assertEquals(listOf("b"), p.appendCatalogIds)
        assertEquals(1, p.added); assertEquals(1, p.removed)
    }

    @Test fun reorderRewritesFromFirstDivergence() {
        val p = edit(PlaylistReconcilePlanner.plan(rows("a", "c", "b", "d"), listOf("a", "b", "c", "d")))
        assertEquals(listOf("i.c", "i.b", "i.d"), p.deleteLibraryIds)
        assertEquals(listOf("b", "c", "d"), p.appendCatalogIds)
        assertEquals("a pure reorder is 0/0 membership delta", 0 to 0, p.added to p.removed)
    }

    @Test fun liveDuplicateFallsBackToPrefixRewrite() {
        val p = edit(PlaylistReconcilePlanner.plan(rows("a", "a", "b"), listOf("a", "b")))
        assertEquals(listOf("i.a", "i.b"), p.deleteLibraryIds)
        assertEquals(listOf("b"), p.appendCatalogIds)
    }

    @Test fun rowWithoutIdsFailsClosed() {
        val live = listOf(AmTrackRow("i.1", "a"), AmTrackRow("i.up", null)) // an uploaded file
        assertEquals(PlaylistReconcilePlanner.Plan.Unsafe, PlaylistReconcilePlanner.plan(live, listOf("a")))
        assertEquals(PlaylistReconcilePlanner.Plan.Unsafe, PlaylistReconcilePlanner.plan(listOf(AmTrackRow(null, "a")), listOf("b")))
    }

    @Test fun refusalStatuses() {
        assertTrue(PlaylistReconcilePlanner.isRefusal(404)); assertTrue(PlaylistReconcilePlanner.isRefusal(403)); assertTrue(PlaylistReconcilePlanner.isRefusal(405))
        assertTrue(!PlaylistReconcilePlanner.isRefusal(401)); assertTrue(!PlaylistReconcilePlanner.isRefusal(429))
        assertTrue(!PlaylistReconcilePlanner.isRefusal(500)); assertTrue(!PlaylistReconcilePlanner.isRefusal(null))
    }

    @Test fun trackPageParserKeepsRowOrderAndLibraryIds() {
        val body = """{"data":[{"id":"i.1","attributes":{"playParams":{"catalogId":"c1"}}},{"id":"i.2","attributes":{}},{"id":"i.3","attributes":{"playParams":{"id":"c3"}}}]}"""
        val page = AppleMusicApiModels.parseTrackPage(body)!!
        assertEquals(listOf(AmTrackRow("i.1", "c1"), AmTrackRow("i.2", null), AmTrackRow("i.3", "c3")), page.rows)
        assertEquals(listOf("c1", "c3"), page.catalogIds)
        assertEquals(3, page.rowCount)
    }

    // ---- Web API transport against MockWebServer ------------------------------------------

    private fun transport(): WebApiPlaylistWriteBackTransport {
        val tokens = StaticAppleMusicTokens("dev", "mut")
        return WebApiPlaylistWriteBackTransport(
            AppleMusicApi(OkHttpClient(), tokens, baseUrl = server.url("/").toString().trimEnd('/'), sleeper = {}), tokens,
        )
    }

    private fun live(vararg cat: String) = cat.joinToString(prefix = """{"data":[""", postfix = "]}") {
        """{"id":"i.$it","attributes":{"playParams":{"catalogId":"$it"}}}"""
    }

    private fun serve(trackBody: String, deleteCode: Int = 204, postCode: Int = 204): MutableList<RecordedRequest> {
        val seen = mutableListOf<RecordedRequest>()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen += request
                return when (request.method) {
                    "GET" -> MockResponse().setBody(trackBody)
                    "DELETE" -> MockResponse().setResponseCode(deleteCode)
                    else -> MockResponse().setResponseCode(postCode)
                }
            }
        }
        return seen
    }

    @Test fun transportRemovesThenAppendsInOrder() = runBlocking {
        val seen = serve(live("a", "c", "b"))
        val r = transport().reconcile("p.1", listOf("a", "b", "c"))
        assertEquals(PlaylistReconcileResult.Edited(3, 0, 0), r)
        val writes = seen.filter { it.method != "GET" }
        assertEquals(listOf("DELETE", "POST"), writes.map { it.method })
        assertTrue(writes[0].path!!.contains("ids%5Blibrary-songs%5D=i.c%2Ci.b") || writes[0].path!!.contains("ids[library-songs]=i.c,i.b"))
        assertEquals(listOf("b", "c"), Regex("\"id\":\"(\\w+)\"").findAll(writes[1].body.readUtf8()).map { it.groupValues[1] }.toList())
    }

    @Test fun transportAlreadyInSyncWritesNothing() = runBlocking {
        val seen = serve(live("a", "b"))
        assertEquals(PlaylistReconcileResult.AlreadyInSync, transport().reconcile("p.1", listOf("a", "b")))
        assertTrue(seen.all { it.method == "GET" })
    }

    @Test fun transportEmptyTargetNeverTouchesAnything() = runBlocking {
        val seen = serve(live("a", "b"))
        assertEquals(PlaylistReconcileResult.SkippedEmpty, transport().reconcile("p.1", emptyList()))
        assertTrue("empty != deletion: not even a read", seen.isEmpty())
    }

    @Test fun transportRefusedDeleteIsNotEditableAndNothingAppended() = runBlocking {
        val seen = serve(live("a", "x"), deleteCode = 405)
        assertEquals(PlaylistReconcileResult.NotEditable, transport().reconcile("p.1", listOf("a", "b")))
        assertTrue(seen.none { it.method == "POST" })
    }

    @Test fun transportUploadedRowFailsClosedWithoutWrites() = runBlocking {
        val body = """{"data":[{"id":"i.1","attributes":{"playParams":{"catalogId":"a"}}},{"id":"i.2","attributes":{}}]}"""
        val seen = serve(body)
        assertEquals(PlaylistReconcileResult.NotEditable, transport().reconcile("p.1", listOf("a")))
        assertTrue(seen.none { it.method != "GET" })
    }

    @Test fun transportReadFailureThrowsInsteadOfBlindReplace() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(500)
        }
        val ex = runCatching { runBlocking { transport().reconcile("p.1", listOf("a")) } }.exceptionOrNull()
        assertTrue(ex is WriteBackException)
    }

    // ---- sync step ------------------------------------------------------------------------

    private class Host : AmSyncHost {
        val songs = LinkedHashMap<String, IndexSong>()
        override var playlists: List<Playlist> = emptyList()
        override val pockets: List<Pocket> = emptyList()
        val plSongs = HashMap<String, List<String>>()
        val links = HashMap<String, String>()
        override fun songIdsForPlaylist(id: String) = plSongs[id].orEmpty()
        override fun songIdsForPocket(id: String) = emptyList<String>()
        override fun song(id: String) = songs[id]
        override fun duplicateIdentity(songId: String) =
            songs[songId]?.let { SongDuplicateJudge.Identity(it.name, it.artist, null, it.appleMusicId) }
        override val sourcePlaylists: List<SourcePlaylist> = emptyList()
        override fun songIdByAppleMusicId() = emptyMap<String, String>()
        override fun linkPlaylist(playlistId: String, amPlaylistId: String) {
            links[playlistId] = amPlaylistId
            playlists = playlists.map { if (it.id == playlistId) it.copy(amPlaylistId = amPlaylistId) else it }
        }
        override fun linkPocket(pocketId: String, amPlaylistId: String) {}
        override fun createPlaylist(name: String, songIds: List<String>, source: SourcePlaylist?) =
            CollectionsFactory.makePlaylist(name, 0.0)
        fun playlist(id: String, name: String, ids: List<String>, amId: String? = null) {
            playlists = playlists + CollectionsFactory.makePlaylist(name, 0.0).copy(id = id, amPlaylistId = amId)
            plSongs[id] = ids
            ids.forEach { songs.getOrPut(it) { IndexSong(id = it, artist = "A$it", name = "N$it", appleMusicId = "am-$it") } }
        }
    }

    private class FakeTransport(val result: PlaylistReconcileResult, val failWith: Exception? = null) : PlaylistWriteBackTransport {
        val reconciled = mutableListOf<Pair<String, List<String>>>()
        val resolved = mutableListOf<String>()
        override val isSupported = true
        override suspend fun canWrite() = true
        override suspend fun resolvePlaylistId(name: String, expectedAppleMusicIds: List<String>): String? { resolved += name; return "by-name" }
        override suspend fun addSong(appleMusicId: String, toPlaylistId: String) {}
        override suspend fun reconcile(playlistId: String, orderedAppleMusicIds: List<String>): PlaylistReconcileResult {
            reconciled += playlistId to orderedAppleMusicIds
            failWith?.let { throw it }
            return result
        }
    }

    private fun lambda(pushRows: String) {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                "/push" -> MockResponse().setResponseCode(202).setBody("""{"jobId":"j-push"}""")
                "/pull" -> MockResponse().setResponseCode(202).setBody("""{"jobId":"j-pull"}""")
                "/job/j-push" -> MockResponse().setBody("""{"status":"done","result":{"playlists":[$pushRows],"errors":[]}}""")
                "/job/j-pull" -> MockResponse().setBody("""{"status":"done","result":{"storefront":"us","playlists":[]}}""")
                else -> MockResponse().setResponseCode(404)
            }
        }
    }

    private fun sync(tr: PlaylistWriteBackTransport?) = PlaylistAppleMusicSync(
        client = AMPlaylistSyncClient(
            http = OkHttpClient.Builder().retryOnConnectionFailure(false).build(),
            tokens = StaticAppleMusicTokens("dev", "MUT"), jobs = InMemoryAmJobStore(),
            baseProvider = { server.url("/").toString() }, stallTimeoutMs = 5_000, pollIntervalMs = 1,
        ),
        transport = tr, auditFile = File(tmp.root, "audit.json"), runFile = File(tmp.root, "run.json"),
    )

    @Test fun syncReconcilesLinkedPlaylistAndReports() = runBlocking {
        val h = Host().apply { playlist("pl1", "Mix", listOf("a", "b"), amId = "p.LINK") }
        lambda("""{"name":"Mix","id":"p.LINK","created":false,"added":0,"total":2}""")
        val tr = FakeTransport(PlaylistReconcileResult.Edited(2, 0, 1))
        val s = sync(tr)
        s.syncNow(h, PlaylistAppleMusicSync.Direction.BOTH)
        assertEquals("durable link wins over the by-name resolve", listOf("p.LINK" to listOf("am-a", "am-b")), tr.reconciled)
        assertTrue(tr.resolved.isEmpty())
        val report = s.ui.value.auditTrail.single()
        val c = report.changes.single { it.kind == "reconciled" }
        assertEquals(0 to 1, c.added to c.removed)
        assertEquals("1 reconciled", report.summary)
        assertTrue(s.ui.value.steps.any { it.label == "Reconciling removals & reorders" && it.detail == "1 playlist re-ordered/pruned" })
    }

    @Test fun syncSkipsJustCreatedAndFallsBackToNameWithoutLink() = runBlocking {
        val h = Host().apply {
            playlist("pl1", "New", listOf("a"))
            playlist("pl2", "Old", listOf("b"))
        }
        lambda(
            """{"name":"New","id":"p.N","created":true,"added":1,"total":1},{"name":"Old","id":"p.O","created":false,"added":0,"total":1}""",
        )
        val tr = FakeTransport(PlaylistReconcileResult.AlreadyInSync)
        val s = sync(tr)
        s.syncNow(h, PlaylistAppleMusicSync.Direction.PUSH)
        // push stamped links first, so Old reconciles by its fresh durable link; New (just created) is skipped.
        assertEquals(listOf("p.O"), tr.reconciled.map { it.first })
        assertEquals("Nothing to fix", s.ui.value.steps.last().detail)
        assertNull(s.ui.value.auditTrail.single().changes.firstOrNull { it.kind == "reconciled" })
    }

    @Test fun syncAbsorbsReconcileFailureAndStillCompletes() = runBlocking {
        val h = Host().apply { playlist("pl1", "Mix", listOf("a"), amId = "p.1") }
        lambda("""{"name":"Mix","id":"p.1","created":false,"added":0,"total":1}""")
        val tr = FakeTransport(PlaylistReconcileResult.AlreadyInSync, failWith = WriteBackException.Http(500))
        val s = sync(tr)
        s.syncNow(h, PlaylistAppleMusicSync.Direction.PUSH)
        assertTrue(s.ui.value.currentRunCompleted)
        assertTrue(s.ui.value.auditTrail.single().errors.isEmpty())
        assertEquals(1, tr.reconciled.size)
    }

    @Test fun reportSummaryCountsReconciled() {
        val c = listOf(AmSyncReport.Change("updated", "A"), AmSyncReport.Change("reconciled", "B"), AmSyncReport.Change("reconciled", "C"))
        assertEquals("1 updated · 2 reconciled", PlaylistAppleMusicSync.reportSummaryText(c, emptyList()))
    }

    @Test fun linkedAmPlaylistIdPrefersPlaylistThenPocket() {
        val h = Host().apply { playlist("pl1", "Mix", listOf("a"), amId = "p.9"); playlist("pl2", "Nolink", listOf("a")) }
        assertEquals("p.9", PlaylistAppleMusicSync.linkedAmPlaylistId(AmOutgoingPlaylist("Mix", localPlaylistIds = listOf("pl2", "pl1")), h))
        assertNull(PlaylistAppleMusicSync.linkedAmPlaylistId(AmOutgoingPlaylist("Mix", localPlaylistIds = listOf("pl2")), h))
    }
}

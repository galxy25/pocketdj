package com.levi.pocketdj.data.applemusic

import com.levi.pocketdj.data.catalog.IndexPlaylist
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.catalog.SourcePlaylist
import com.levi.pocketdj.data.collections.CollectionsFactory
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.Pocket
import com.levi.pocketdj.data.collections.SongDuplicateJudge
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlaylistAppleMusicSyncTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private val jobs = InMemoryAmJobStore()

    @Before fun up() { server = MockWebServer().also { it.start() } }
    @After fun down() { server.shutdown() }

    // ---- a fake collections/catalog host -------------------------------------------------

    private class Host : AmSyncHost {
        val songs = LinkedHashMap<String, IndexSong>()
        override var playlists: List<Playlist> = emptyList()
        override var pockets: List<Pocket> = emptyList()
        val plSongs = HashMap<String, List<String>>()
        val pkSongs = HashMap<String, List<String>>()
        override var sourcePlaylists: List<SourcePlaylist> = emptyList()
        val playlistLinks = HashMap<String, String>()
        val pocketLinks = HashMap<String, String>()
        val created = mutableListOf<Triple<String, List<String>, SourcePlaylist?>>()

        override fun songIdsForPlaylist(id: String) = plSongs[id].orEmpty()
        override fun songIdsForPocket(id: String) = pkSongs[id].orEmpty()
        override fun song(id: String) = songs[id]
        override fun duplicateIdentity(songId: String) =
            songs[songId]?.let { SongDuplicateJudge.Identity(it.name, it.artist, null, it.appleMusicId) }
        override fun songIdByAppleMusicId() = songs.values.mapNotNull { s -> s.appleMusicId?.let { it to s.id } }.toMap()
        override fun linkPlaylist(playlistId: String, amPlaylistId: String) { playlistLinks[playlistId] = amPlaylistId }
        override fun linkPocket(pocketId: String, amPlaylistId: String) { pocketLinks[pocketId] = amPlaylistId }
        override fun createPlaylist(name: String, songIds: List<String>, source: SourcePlaylist?): Playlist {
            created += Triple(name, songIds, source)
            return CollectionsFactory.makePlaylist(name, 0.0).also { playlists = playlists + it }
        }

        fun addSong(id: String, am: String? = "am-$id", name: String = "Song $id", artist: String = "Art$id") {
            songs[id] = IndexSong(id = id, artist = artist, name = name, appleMusicId = am)
        }
        fun playlist(id: String, name: String, ids: List<String>, dir: String? = null): Playlist {
            val p = CollectionsFactory.makePlaylist(name, 0.0).copy(id = id, amSyncDirection = dir)
            playlists = playlists + p; plSongs[id] = ids; return p
        }
        fun pocket(id: String, name: String, ids: List<String>, source: String? = null, dir: String? = null): Pocket {
            val p = Pocket(
                id = id, name = name, sourcePlaylistId = source?.let { "src-$id" }, sourceName = source, amSyncDirection = dir,
            )
            pockets = pockets + p; pkSongs[id] = ids; return p
        }
    }

    private fun client() = AMPlaylistSyncClient(
        http = OkHttpClient.Builder().retryOnConnectionFailure(false).build(),
        tokens = StaticAppleMusicTokens("dev", "MUT"),
        jobs = jobs,
        baseProvider = { server.url("/").toString() },
        stallTimeoutMs = 5_000, pollIntervalMs = 1,
    )

    private fun sync(now: () -> Double = { 1_000.0 }) = PlaylistAppleMusicSync(
        client = client(), transport = null,
        auditFile = File(tmp.root, "audit.json"), runFile = File(tmp.root, "run.json"), nowMs = now,
    )

    private fun names(r: AmOutgoingResolution) = r.playlists.map { it.name }

    // ---- resolveOutgoing -----------------------------------------------------------------

    @Test fun resolveOutgoingMerge() {
        val h = Host().apply {
            addSong("a"); addSong("b"); addSong("c")
            playlist("pl1", "Sap", listOf("a", "b"))
            playlist("pl2", "  sap  ", listOf("b", "c")) // normName collides with "Sap"
        }
        val out = PlaylistAppleMusicSync.resolveOutgoingDetailed(h)
        assertEquals(1, out.playlists.size)
        val e = out.playlists.single()
        assertEquals("Sap", e.name)
        assertEquals("ordered union, deduped", listOf("am-a", "am-b", "am-c"), e.trackCatalogIds)
        assertEquals(listOf("am-a", "am-b", "am-c"), e.trackMeta.map { it.id })
        assertEquals("both locals get the link stamp", listOf("pl1", "pl2"), e.localPlaylistIds)
        assertEquals(listOf("Song a", "Song b", "Song c"), e.trackMeta.map { it.n })
        assertEquals(listOf("Arta", "Artb", "Artc"), e.trackMeta.map { it.a })
    }

    @Test fun normNameMatchesServer() {
        assertEquals("my mix", PlaylistAppleMusicSync.normName("  My \n Mix  "))
        assertEquals("sap", PlaylistAppleMusicSync.normName("Sap "))
    }

    @Test fun pushDisabledDropped() {
        val h = Host().apply {
            addSong("a")
            playlist("pl1", "Both", listOf("a"), dir = "both")
            playlist("pl2", "SendOnly", listOf("a"), dir = "push")
            playlist("pl3", "GetOnly", listOf("a"), dir = "pull")
            playlist("pl4", "Off", listOf("a"), dir = "off")
            pocket("pk1", "PocketGetOnly", listOf("a"), source = "Apple Music (Local)", dir = "pull")
        }
        assertEquals(listOf("Both", "SendOnly"), names(PlaylistAppleMusicSync.resolveOutgoingDetailed(h)))
    }

    @Test fun pocketsWithProvenanceIncluded() {
        val h = Host().apply {
            addSong("a"); addSong("b")
            pocket("pk1", "From AM", listOf("a"), source = "Apple Music (Local)")
            pocket("pk2", "From AM private", listOf("b"), source = "Apple Music")
            pocket("pk3", "Hand made", listOf("a"))
            pocket("pk4", "From vinyl", listOf("a"), source = "Vinyl")
        }
        val out = PlaylistAppleMusicSync.resolveOutgoingDetailed(h)
        assertEquals(listOf("From AM", "From AM private"), names(out))
        assertEquals(listOf("pk1"), out.playlists[0].localPocketIds)
        assertTrue(out.playlists[0].localPlaylistIds.isEmpty())
    }

    @Test fun nameArtistDuplicateGateAndSkippedReporting() {
        val h = Host().apply {
            addSong("a", am = "am-1", name = "Same", artist = "Who")
            addSong("b", am = "am-2", name = "Same", artist = "Who") // same recording, second catalog id
            addSong("v1", am = null) // rip-only: no store id
            playlist("pl1", "Dupes", listOf("a", "b"))
            playlist("pl2", "Rips", listOf("v1"))
            playlist("pl3", "Empty", emptyList())
        }
        val out = PlaylistAppleMusicSync.resolveOutgoingDetailed(h)
        assertEquals(listOf("am-1"), out.playlists.single().trackCatalogIds)
        assertEquals(listOf("Rips"), out.skipped.map { it.name })
        assertEquals(1, out.skipped.single().songCount)
        // An on-device resolved id rescues the rips-only playlist.
        val rescued = PlaylistAppleMusicSync.resolveOutgoingDetailed(h, mapOf("v1" to "am-resolved"))
        assertEquals(listOf("Dupes", "Rips"), names(rescued))
        assertTrue(rescued.skipped.isEmpty())
    }

    @Test fun skippedDroppedWhenNameCollidingSiblingHasTracks() {
        val h = Host().apply {
            addSong("a"); addSong("v", am = null)
            playlist("p1", "Mix", listOf("a"))
            pocket("pk", "mix", listOf("v"), source = "Apple Music (Local)")
        }
        val out = PlaylistAppleMusicSync.resolveOutgoingDetailed(h)
        assertEquals(1, out.playlists.size)
        assertTrue(out.skipped.isEmpty())
    }

    @Test fun songsNeedingCatalogIdScopedToDroppedCollections() {
        val h = Host().apply {
            addSong("a"); addSong("v", am = null, name = "Rip", artist = "Band"); addSong("w", am = null, name = "Other", artist = "Band")
            playlist("p1", "Rips", listOf("v"))
            playlist("p2", "Elsewhere", listOf("w"))
        }
        assertTrue(PlaylistAppleMusicSync.songsNeedingCatalogId(h, emptySet()).isEmpty())
        val need = PlaylistAppleMusicSync.songsNeedingCatalogId(h, setOf("rips"))
        assertEquals(listOf("v"), need.map { it.first })
        assertEquals("Rip", need[0].second.title)
        // pendingLookups: hits skipped, fresh misses skipped, stale misses re-asked.
        val now = 100_000_000_000.0
        val known = mapOf(
            "v" to AmCatalogLookup(null, now - 1000),
            "x" to AmCatalogLookup("am-x", 0.0),
            "y" to AmCatalogLookup(null, now - PlaylistAppleMusicSync.MISS_RETRY_AFTER_MS - 1),
        )
        val s = { id: String -> id to WriteBackSong("", id, "a") }
        assertEquals(listOf("y", "z"), PlaylistAppleMusicSync.pendingLookups(listOf(s("v"), s("x"), s("y"), s("z")), known, now).map { it.first })
    }

    // ---- pull side -----------------------------------------------------------------------

    private fun remote(id: String, name: String, vararg tracks: String) =
        AmRemotePlaylist(id = id, name = name, trackCatalogIds = tracks.toList())

    @Test fun newImportsSkipExistingNamesInclPockets() {
        val h = Host().apply {
            playlist("p1", "Roadtrip", emptyList())
            pocket("pk1", "  Chill Vibes ", emptyList())
        }
        val existing = PlaylistAppleMusicSync.existingCollectionNames(h)
        assertEquals(setOf("roadtrip", "chill vibes"), existing)
        val remotes = listOf(
            remote("r1", "roadtrip", "1"), remote("r2", "Chill   Vibes", "1"), remote("r3", "Brand New", "1"),
        )
        assertEquals(listOf("r3"), PlaylistAppleMusicSync.newImports(remotes, existing).map { it.id })
    }

    @Test fun newImportsSkipRemotesLinkedById() {
        val h = Host().apply {
            playlist("p1", "Roadtrip 2026", emptyList())
            playlists = playlists.map { it.copy(amPlaylistId = "r1") } // renamed locally, linked by id
            pockets = listOf(Pocket(id = "pk", name = "X", sourcePlaylistId = "r9"))
        }
        val linked = PlaylistAppleMusicSync.linkedRemoteIds(h)
        assertEquals(setOf("r1", "r9"), linked)
        val out = PlaylistAppleMusicSync.newImports(
            listOf(remote("r1", "Roadtrip", "1"), remote("r9", "Other", "1"), remote("r2", "Fresh", "1")),
            PlaylistAppleMusicSync.existingCollectionNames(h), linked,
        )
        assertEquals(listOf("r2"), out.map { it.id })
    }

    @Test fun collapseSameNameRemotes() {
        val out = PlaylistAppleMusicSync.newImports(
            listOf(
                remote("a", "Comfort Zone", "1"),
                remote("b", "comfort zone ", "1", "2", "3"), // fullest wins
                remote("c", "Other", "1"),
                remote("d", "COMFORT ZONE", "1", "2", "3"), // tie: first wins
            ),
            emptySet(),
        )
        assertEquals(listOf("b", "c"), out.map { it.id })
    }

    // ---- audit / run persistence ---------------------------------------------------------

    @Test fun auditCap20() {
        val s = sync()
        for (i in 1..25) s.appendAudit(AmSyncReport(i.toDouble(), summary = "run $i"))
        val trail = s.ui.value.auditTrail
        assertEquals(20, trail.size)
        assertEquals("newest first", 25.0, trail.first().dateMs, 0.0)
        assertEquals(6.0, trail.last().dateMs, 0.0)
        // Persisted: a fresh instance sees the same 20.
        assertEquals(20, sync().ui.value.auditTrail.size)
    }

    @Test fun auditIsReadMergeWriteAcrossInstances() {
        val a = sync()
        val b = sync() // both loaded the (empty) trail
        a.appendAudit(AmSyncReport(1.0, summary = "from a"))
        b.appendAudit(AmSyncReport(2.0, summary = "from b"))
        assertEquals("b must not clobber a's report with its stale copy", listOf(2.0, 1.0), b.ui.value.auditTrail.map { it.dateMs })
    }

    @Test fun mergeAuditDedupesByDate() {
        val merged = PlaylistAppleMusicSync.mergeAudit(listOf(AmSyncReport(5.0, summary = "old")), AmSyncReport(5.0, summary = "new"))
        assertEquals(1, merged.size)
        assertEquals("new", merged[0].summary)
    }

    @Test fun interruptedHydration() {
        val snap = AmRunSnapshot(
            startedMs = 111.0, updatedMs = 222.0, completed = false,
            steps = listOf(
                AmSyncStep(0, "Preparing playlists", "2 playlists", AmSyncStep.State.DONE),
                AmSyncStep(1, "Pushing to Apple Music", "Appending (3/9)", AmSyncStep.State.RUNNING),
            ),
        )
        File(tmp.root, "run.json").writeText(kotlinx.serialization.json.Json.encodeToString(AmRunSnapshot.serializer(), snap))
        val ui = sync().ui.value
        assertEquals(111.0, ui.currentRunStartedMs!!, 0.0)
        assertFalse(ui.currentRunCompleted)
        assertEquals(listOf(AmSyncStep.State.DONE, AmSyncStep.State.INTERRUPTED), ui.steps.map { it.state })
        assertEquals("Appending (3/9)", ui.steps[1].detail)
        // A COMPLETED snapshot keeps its states as-is.
        val done = snap.copy(completed = true)
        assertEquals(AmSyncStep.State.RUNNING, PlaylistAppleMusicSync.hydrateSteps(done)[1].state)
    }

    @Test fun runSnapshotJsonShapeIsIosCompatible() {
        val txt = """{"startedMs":1.5,"updatedMs":2.5,"completed":false,"steps":[{"id":0,"label":"L","state":"running"},{"id":1,"label":"M","detail":"d","state":"interrupted"}]}"""
        val snap = kotlinx.serialization.json.Json.decodeFromString(AmRunSnapshot.serializer(), txt)
        assertEquals(AmSyncStep.State.RUNNING, snap.steps[0].state)
        assertNull(snap.steps[0].detail)
        val report = kotlinx.serialization.json.Json.decodeFromString(
            AmSyncReport.serializer(),
            """{"dateMs":9,"summary":"s","errors":["e"],"changes":[{"kind":"created","name":"N","added":2,"removed":0}]}""",
        )
        assertEquals("created", report.changes[0].kind)
    }

    // ---- end to end through the client ---------------------------------------------------

    private fun job(body: String, code: Int = 200) = MockResponse().setResponseCode(code).setBody(body)

    @Test fun resumeIfInterruptedReattachesByStoredJob() = runBlocking {
        val h = Host().apply { addSong("a"); playlist("pl1", "Mix", listOf("a")) }
        // The previous process died mid-push: run snapshot not completed + stored job id.
        val snap = AmRunSnapshot(
            1.0, 2.0, completed = false,
            steps = listOf(AmSyncStep(0, "Pushing to Apple Music", null, AmSyncStep.State.RUNNING)),
        )
        File(tmp.root, "run.json").writeText(kotlinx.serialization.json.Json.encodeToString(AmRunSnapshot.serializer(), snap))
        jobs.store("push", AmJobStore.StoredJob("live-job", System.currentTimeMillis() - 1000))
        server.enqueue(job("""{"status":"done","result":{"playlists":[{"name":"Mix","id":"p.1","created":true,"added":1,"total":1}],"errors":[]}}"""))
        server.enqueue(job("""{"jobId":"pull-1"}""", 202))
        server.enqueue(job("""{"status":"done","result":{"storefront":"us","playlists":[]}}"""))

        val s = sync()
        assertFalse(s.ui.value.currentRunCompleted)
        s.resumeIfInterrupted(h)

        val reqs = generateSequence { server.takeRequest(50, TimeUnit.MILLISECONDS) }.toList()
        assertEquals("/job/live-job", reqs[0].path) // re-attached; no second /push submit
        assertTrue(reqs.none { it.path == "/push" })
        assertEquals("p.1", h.playlistLinks["pl1"])
        val ui = s.ui.value
        assertTrue(ui.currentRunCompleted)
        assertFalse(ui.isSyncing)
        assertEquals("1 created", ui.auditTrail.single().summary)
        assertEquals("created", ui.auditTrail.single().changes.single().kind)
        // Nothing to resume once complete.
        val before = server.requestCount
        s.resumeIfInterrupted(h)
        assertEquals(before, server.requestCount)
    }

    @Test fun pullImportsOnlyWhenOptedInAndLinksMirror() = runBlocking {
        val h = Host().apply {
            addSong("a"); addSong("b")
            playlist("pl1", "Existing", emptyList())
            sourcePlaylists = listOf(SourcePlaylist(IndexPlaylist("mirror-1", "Roadtrip", listOf("a")), "Apple Music (Local)"))
        }
        val pullBody = """{"status":"done","result":{"storefront":"us","playlists":[
            {"id":"r1","name":"Roadtrip","trackCatalogIds":["am-a","am-b","am-zzz"]},
            {"id":"r2","name":"existing","trackCatalogIds":["am-a"]}]}}"""

        // OFF (default): nothing imported, reported.
        server.enqueue(job("""{"jobId":"j1"}""", 202)); server.enqueue(job(pullBody))
        val off = sync()
        off.syncNow(h, PlaylistAppleMusicSync.Direction.PULL)
        assertTrue(h.created.isEmpty())
        val c = off.ui.value.auditTrail.single().changes.single()
        assertEquals("not imported", c.kind)
        assertTrue(c.name.startsWith("1 Apple Music playlist"))

        // ON: imported with matched local ids + mirror provenance.
        server.enqueue(job("""{"jobId":"j2"}""", 202)); server.enqueue(job(pullBody))
        val on = sync { 2_000.0 }
        on.importNewPlaylistsEnabled = { true }
        on.syncNow(h, PlaylistAppleMusicSync.Direction.PULL)
        val (name, ids, src) = h.created.single()
        assertEquals("Roadtrip", name)
        assertEquals(listOf("a", "b"), ids)
        assertEquals("mirror-1", src?.playlist?.id)
        val imp = on.ui.value.auditTrail.first().changes.single()
        assertEquals("imported", imp.kind)
        assertEquals("2 of 3 tracks matched locally", imp.detail)
        assertEquals("1 imported", on.ui.value.auditTrail.first().summary)
    }

    @Test fun failedRunIsAuditedAndCompleted() = runBlocking {
        val h = Host().apply { addSong("a"); playlist("pl1", "Mix", listOf("a")) }
        server.enqueue(job("nope", 403))
        val s = sync()
        s.syncNow(h, PlaylistAppleMusicSync.Direction.PUSH)
        val ui = s.ui.value
        assertTrue(ui.currentRunCompleted)
        assertFalse(ui.isSyncing)
        assertEquals(AmSyncStep.State.FAILED, ui.steps.last().state)
        assertTrue(ui.auditTrail.single().summary.startsWith("Failed:"))
        // Persisted run snapshot is completed, so a relaunch will NOT try to resume it.
        assertTrue(sync().ui.value.currentRunCompleted)
    }

    @Test fun summaries() {
        assertEquals("Nothing to push", PlaylistAppleMusicSync.pushSummaryText(0, 0, 0, 0, 0))
        assertEquals(
            "created 1 · updated 2 (+1 song) · 3 already in sync · 1 failed",
            PlaylistAppleMusicSync.pushSummaryText(1, 2, 1, 3, 1),
        )
        assertEquals("Everything in sync", PlaylistAppleMusicSync.reportSummaryText(emptyList(), emptyList()))
        assertEquals("2 errors", PlaylistAppleMusicSync.reportSummaryText(emptyList(), listOf("a", "b")).substringAfter(" · "))
    }

    @Test fun cancelledSyncShowsInterruptedNotSpinner() = runBlocking {
        val h = Host().apply { addSong("a"); playlist("pl1", "Mix", listOf("a")) }
        server.dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: okhttp3.mockwebserver.RecordedRequest) =
                if (request.path == "/push") MockResponse().setResponseCode(202).setBody("""{"jobId":"j1"}""")
                else MockResponse().setBody("""{"status":"running"}""")
        }
        val s = sync()
        val job = kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.IO) { s.syncNow(h, PlaylistAppleMusicSync.Direction.BOTH) }
        val deadline = System.currentTimeMillis() + 5_000
        while (s.ui.value.steps.none { it.state == AmSyncStep.State.RUNNING } && System.currentTimeMillis() < deadline) delay(5)
        assertTrue(s.ui.value.steps.any { it.state == AmSyncStep.State.RUNNING })
        job.cancelAndJoin()
        val ui = s.ui.value
        assertFalse(ui.isSyncing)
        assertFalse(ui.currentRunCompleted)
        assertTrue(ui.steps.none { it.state == AmSyncStep.State.RUNNING })
        assertTrue(ui.steps.any { it.state == AmSyncStep.State.INTERRUPTED })
    }
}

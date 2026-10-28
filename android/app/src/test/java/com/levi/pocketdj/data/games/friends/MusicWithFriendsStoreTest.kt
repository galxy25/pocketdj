package com.levi.pocketdj.data.games.friends

import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.data.games.GameKind
import com.levi.pocketdj.data.games.GameScoreboardStore
import com.levi.pocketdj.playback.RunItem
import java.io.File
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
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

class MusicWithFriendsStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var scoreboard: GameScoreboardStore
    private lateinit var host: FakeHost
    private lateinit var kv: InMemoryMwFKeyValue
    private lateinit var store: MusicWithFriendsStore
    private lateinit var sessionFile: MwFSessionFile
    private val responses = HashMap<String, () -> MockResponse>()
    private val log = ArrayList<String>()
    private var now = 1_000.0

    private class FakeQueue : MwFQueueSink {
        override var runningSourceTag: String? = null
        override var isRunning = false
        val appended = ArrayList<RunItem>(); val played = ArrayList<RunItem>()
        override fun append(item: RunItem) { appended += item }
        override fun play(item: RunItem) { played += item }
    }

    private class FakeHost(val q: FakeQueue = FakeQueue()) : MwFHost {
        var catalog = listOf(IndexSong(id = "sng_1", artist = "Daft Punk", name = "Around the World", appleMusicId = "111", length = 200000))
        val pockets = HashMap<String, MutableList<String>>()
        override fun songs(): List<IndexSong> { songsThread = Thread.currentThread().name; return catalog }
        override fun songExists(songId: String) = catalog.any { it.id == songId }
        override fun songIdForAppleMusicId(appleMusicId: String) = catalog.firstOrNull { it.appleMusicId == appleMusicId }?.id
        override fun profileName() = "Pat"
        override val queue: MwFQueueSink = q
        override fun createPocket(name: String, songIds: List<String>, description: String?): String {
            val id = "pkt_${pockets.size + 1}"; pockets[id] = songIds.toMutableList(); names[id] = name; return id
        }
        val names = HashMap<String, String>()
        override fun pocketExists(pocketId: String) = pockets.containsKey(pocketId)
        override fun addSongToPocket(songId: String, pocketId: String) { pockets[pocketId]?.let { if (songId !in it) it += songId } }
        override fun pocketSongIds(pocketId: String): List<String> = pockets[pocketId].orEmpty()
        var externalMatch: com.levi.pocketdj.data.jukebox.JukeboxExternalMatch = com.levi.pocketdj.data.jukebox.JukeboxExternalMatch.None
        override val external: com.levi.pocketdj.data.jukebox.JukeboxExternalMatch get() = externalMatch
        var songsThread: String? = null
    }

    @Before fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val key = "${request.method} ${request.path}"
                log += key + (request.getHeader("Authorization")?.let { " [$it]" } ?: "")
                return responses[key]?.invoke() ?: MockResponse().setResponseCode(404)
            }
        }
        server.start()
        host = FakeHost()
        kv = InMemoryMwFKeyValue()
        scoreboard = GameScoreboardStore(File(tmp.root, "scores.json"))
        sessionFile = MwFSessionFile(File(tmp.root, "sessions.json"))
        store = build()
    }

    @After fun tearDown() = server.shutdown()

    private fun build() = MusicWithFriendsStore(
        client = MwFClient(OkHttpClient()) { MwFClient.Config(server.url("/").toString(), "SRV", "inst") },
        sessionFile = sessionFile, kv = kv, joinSecret = MwFJoinSecret(kv), scoreboard = scoreboard,
        host = host, clientId = { "cid" }, clock = { now },
    )

    private fun reply(route: String, code: Int = 200, body: String = "{}") {
        responses[route] = { MockResponse().setResponseCode(code).setBody(body) }
    }

    private val sid = "abcd2345"
    private val createBody = """{"sessionId":"$sid","leaderKey":"LK","memberId":"m1","memberKey":"MK","name":"Party","theme":"disco"}"""

    private suspend fun makeLeader() { reply("POST /mwf", body = createBody); assertNull(store.create("Party", "disco", "Pat", MwFSettings())) }

    @Test fun createIncompleteReply() = runBlocking {
        reply("POST /mwf", body = """{"sessionId":"$sid"}""")
        assertEquals("The server's create reply was incomplete.", store.create("n", "t", "Pat", MwFSettings()))
        assertTrue(store.sessions.value.isEmpty())
        assertTrue(store.lastErrors.value.isEmpty())
        assertTrue(store.pollErrors.value.isEmpty())
    }

    @Test fun createSuccessPersistsAndRaisesOpen() = runBlocking {
        makeLeader()
        assertEquals(sid, store.sessions.value.single().id)
        assertTrue(store.sessions.value.single().isLeader)
        assertEquals(sid, store.consumePendingOpenId())
        assertNull(store.consumePendingOpenId())
        assertEquals(1, sessionFile.load().size)
        assertEquals(sid, build().also { it.loadPersisted() }.sessions.value.single().id)
    }

    @Test fun join404OlderServer() = runBlocking {
        reply("GET /health", body = """{"ok":true,"version":2}""")
        val err = store.join(MwFLink.parse("pocketdj://mwf/$sid")!!, "Pat")!!
        assertTrue(err, err.contains("older version"))
        reply("GET /health", body = """{"ok":true,"version":3,"mwf":false}""")
        assertTrue(store.join(MwFLink.parse("pocketdj://mwf/$sid")!!, "Pat")!!.contains("older version"))
        reply("GET /health", body = """{"ok":true,"version":3,"mwf":true}""")
        assertTrue(store.join(MwFLink.parse("pocketdj://mwf/$sid")!!, "Pat")!!.contains("isn't available"))
        assertTrue(store.lastErrors.value.isEmpty())
    }

    @Test fun joinSuccessUsesPublicStateApiBase() = runBlocking {
        reply("GET /mwf/$sid/state.json", body = """{"sessionId":"$sid","theme":"tiki","name":"Luau","apiBase":"${server.url("/")}"}""")
        reply("POST /mwf/$sid/join", body = """{"memberId":"m2","memberKey":"MK2"}""")
        // link is custom-scheme => state.json goes to the canonical host (unreachable here) => best-effort miss
        assertNull(store.join(MwFLink.parse("pocketdj://mwf/$sid")!!, "Pat"))
        val e = store.entry(sid)!!
        assertFalse(e.isLeader)
        assertEquals("https://jukebox.pocket-dj.com/mwf/$sid/", e.url)
        assertEquals(sid, store.pendingOpenId.value)
        // joining again = open only
        assertNull(store.join(MwFLink.parse("pocketdj://mwf/$sid")!!, "Pat"))
        assertEquals(1, store.sessions.value.size)
    }

    @Test fun handleOpenedLinkRaisesOpenInBothBranches() = runBlocking {
        val link = MwFLink.parse("pocketdj://mwf/$sid")!!
        store.handleOpenedLink(link)
        assertEquals(link, store.pendingJoin.value)
        assertEquals(sid, store.pendingOpenId.value)
        makeLeader(); store.clearPendingJoin(); store.consumePendingOpenId()
        store.handleOpenedLink(link)
        assertNull(store.pendingJoin.value)
        assertEquals(sid, store.pendingOpenId.value)
    }

    @Test fun refreshUpdatesStateEntryAndClearsPollError() = runBlocking {
        makeLeader()
        reply("GET /mwf/$sid/state", code = 500)
        store.refresh(sid)
        assertNotNull(store.pollErrors.value[sid])
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid","name":"Renamed","theme":"new","expiresAt":9999.0,"members":[{"memberId":"m1","score":2}]}""")
        val st = store.refresh(sid)!!
        assertNull(store.pollErrors.value[sid])
        assertEquals(st, store.lastState.value[sid])
        val e = store.entry(sid)!!
        assertEquals(Triple("Renamed", "new", 9999.0), Triple(e.name, e.theme, e.expiresAt))
        assertEquals("Renamed", sessionFile.load().single().name)
    }

    @Test fun refresh401Recovers() = runBlocking {
        makeLeader()
        var stateCalls = 0
        responses["GET /mwf/$sid/state"] = {
            if (stateCalls++ == 0) MockResponse().setResponseCode(401)
            else MockResponse().setBody("""{"sessionId":"$sid","ended":false}""")
        }
        reply("POST /mwf/$sid/join", body = """{"memberId":"m9","memberKey":"MK9"}""")
        val st = store.refresh(sid)
        assertNotNull(st)
        assertEquals("MK9", store.entry(sid)!!.memberKey)
        assertEquals("m9", store.entry(sid)!!.memberId)
        assertEquals("LK", store.entry(sid)!!.leaderKey)
        assertNull(store.pollErrors.value[sid])
        // memberKey presented first
        assertTrue(log.contains("POST /mwf/$sid/join [Bearer MK]"))
    }

    @Test fun recoveryFallsBackToSecretOnlyAndGivesUpWithPollError() = runBlocking {
        makeLeader()
        reply("GET /mwf/$sid/state", code = 401)
        var joins = 0
        responses["POST /mwf/$sid/join"] = {
            if (joins++ == 0) MockResponse().setResponseCode(401) else MockResponse().setBody("""{"memberId":"mx","memberKey":"MKX"}""")
        }
        store.refresh(sid) // recovers via secret-only, retry still 401 => poll error
        assertEquals("MKX", store.entry(sid)!!.memberKey)
        assertTrue(log.contains("POST /mwf/$sid/join"))
        assertTrue(store.pollErrors.value[sid]!!.contains("no longer recognizes"))
    }

    @Test fun refresh410Folds() = runBlocking {
        makeLeader()
        reply("GET /mwf/$sid/state", code = 410)
        val st = store.refresh(sid)
        assertEquals(true, st?.ended)
        assertEquals(1, scoreboard.state.value.runs.count { it.game == GameKind.MusicWithFriends.token })
        store.refresh(sid) // second observation must not score again
        assertEquals(1, scoreboard.state.value.runs.size)
    }

    @Test fun scoreOnceWithDetailAndPersistedAcrossRestart() = runBlocking {
        makeLeader()
        val theme = "t".repeat(80)
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid","ended":true,"theme":"$theme","you":{"memberId":"m1"},"members":[{"memberId":"m1","score":4}]}""")
        store.refresh(sid); store.refresh(sid); store.recordFinalScoreIfNeeded(sid)
        val run = scoreboard.state.value.runs.single()
        assertEquals(4, run.score)
        assertEquals(60, run.settingsSummary!!.length)
        assertEquals(mapOf("sessionId" to sid, "theme" to theme), run.detail)
        val again = build().also { it.loadPersisted() }
        again.recordFinalScoreIfNeeded(sid)
        assertEquals(1, scoreboard.state.value.runs.size)
    }

    @Test fun noScoreWhileLiveAndExpiryFallbackScoresZero() = runBlocking {
        makeLeader()
        store.recordFinalScoreIfNeeded(sid)
        assertTrue(scoreboard.state.value.runs.isEmpty())
        // entry with a past expiry and no observed state => scored via expiry fallback
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid","expiresAt":500.0}""")
        store.refresh(sid)
        assertTrue(scoreboard.state.value.runs.isEmpty()) // refresh alone only scores on `ended`
        store.recordFinalScoreIfNeeded(sid)
        assertEquals(0, scoreboard.state.value.runs.single().score)
    }

    @Test fun errorsKeyedPerSession() = runBlocking {
        makeLeader()
        reply("POST /mwf", body = createBody.replace(sid, "wxyz2345"))
        store.create("B", "t", "Pat", MwFSettings())
        reply("POST /mwf/$sid/suggestions/s1/decision", code = 500)
        reply("POST /mwf/$sid/suggestions/s1/plusone", code = 500)
        store.reject(sid, MwFSuggestion(id = "s1"))
        assertNotNull(store.lastErrors.value[sid])
        assertNull(store.lastErrors.value["wxyz2345"])
        reply("GET /mwf/wxyz2345/state", code = 500)
        store.refresh("wxyz2345")
        assertNull(store.pollErrors.value[sid])
        assertNotNull(store.pollErrors.value["wxyz2345"])
        assertNull(store.lastErrors.value["wxyz2345"])
    }

    @Test fun suggestThrowsAndDoesNotWriteSharedErrors() = runBlocking {
        makeLeader()
        reply("POST /mwf/$sid/suggest", code = 409, body = """{"error":"Not your turn"}""")
        try { store.suggest(sid, "T", "A"); org.junit.Assert.fail() } catch (e: MwFException) { assertEquals(409, e.code) }
        assertTrue(store.lastErrors.value.isEmpty())
    }

    @Test fun approveMatchesCatalogFirstAndQueues() = runBlocking {
        makeLeader()
        store.setQueueAccepted(true)
        reply("POST /mwf/$sid/suggestions/s1/decision")
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid"}""")
        var decisionBody = ""
        val inner = server.dispatcher
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.path!!.endsWith("/decision")) decisionBody = request.body.readUtf8()
                return inner.dispatch(request)
            }
        }
        store.approve(sid, MwFSuggestion(id = "s1", title = "Around the World", artist = "Daft Punk"))
        assertTrue(decisionBody, decisionBody.contains("\"action\":\"accepted\"") && decisionBody.contains("\"songId\":\"sng_1\"") && decisionBody.contains("\"appleMusicId\":\"111\""))
        assertEquals("sng_1", host.q.played.single().songId) // idle queue => starts one
    }

    @Test fun approveUnmatchedStillDecidesWithTitleArtistOnly() = runBlocking {
        makeLeader()
        reply("POST /mwf/$sid/suggestions/s1/decision")
        reply("GET /mwf/$sid/state")
        store.approve(sid, MwFSuggestion(id = "s1", title = "Nope", artist = "Nobody"))
        assertTrue(log.any { it.startsWith("POST /mwf/$sid/suggestions/s1/decision") })
        assertTrue(host.q.played.isEmpty() && host.q.appended.isEmpty())
    }

    @Test fun neverQueueIntoPuzzle() {
        val m = MwFMatch(songId = "sng_1", title = "t")
        host.q.isRunning = true
        host.q.runningSourceTag = "puzzle_abc"
        store.queueMatchIfPlayable(m)
        assertTrue(host.q.appended.isEmpty() && host.q.played.isEmpty())
        host.q.runningSourceTag = "some-setlist"
        store.queueMatchIfPlayable(m)
        assertEquals(1, host.q.appended.size)
        host.q.isRunning = false
        store.queueMatchIfPlayable(m)
        assertEquals(1, host.q.played.size)
        store.queueMatchIfPlayable(MwFMatch(appleMusicId = "999")) // no catalog id => not playable
        assertEquals(1, host.q.played.size + host.q.appended.size - 1)
    }

    @Test fun endSessionFoldsLocallyEvenWhenUnreachable() = runBlocking {
        makeLeader()
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid","members":[{"memberId":"m1","score":1}]}""")
        store.refresh(sid)
        reply("POST /mwf/$sid/end", code = 500)
        store.endSession(sid)
        assertNotNull(store.lastErrors.value[sid])
        assertEquals(true, store.lastState.value[sid]?.ended)
        assertEquals(1, scoreboard.state.value.runs.single().score)
    }

    @Test fun memberCannotRunLeaderVerbs() = runBlocking {
        reply("POST /mwf/$sid/join", body = """{"memberId":"m2","memberKey":"MK2"}""")
        reply("GET /mwf/$sid/state.json", body = "{}")
        store.join(MwFLink.parse("pocketdj://mwf/$sid")!!, "Pat")
        store.endSession(sid); store.reject(sid, MwFSuggestion(id = "s")); store.updateSettings(sid, MwFSettings(turnSeconds = 30))
        assertTrue(log.none { it.contains("/end") || it.contains("/decision") || it.contains("/config") })
    }

    @Test fun updateSettingsPatchesCachedState() = runBlocking {
        makeLeader()
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid"}""")
        store.refresh(sid)
        reply("POST /mwf/$sid/config", body = """{"settings":{"turnSeconds":300}}""")
        store.updateSettings(sid, MwFSettings(turnSeconds = 300))
        assertEquals(300, store.lastState.value[sid]!!.settings!!.turnSeconds)
    }

    @Test fun leaveRecordsScoreIfDueAndForgets() = runBlocking {
        makeLeader()
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid","ended":true}""")
        store.refresh(sid)
        store.leave(sid)
        assertTrue(store.sessions.value.isEmpty())
        assertTrue(sessionFile.load().isEmpty())
        assertNull(store.lastState.value[sid])
        assertEquals(1, scoreboard.state.value.runs.size)
    }

    @Test fun downloadIdempotent() = runBlocking {
        makeLeader()
        fun state(vararg ids: String) = MwFState(sessionId = sid, name = "Party", theme = "disco",
            collection = ids.map { MwFCollectionEntry(songId = if (it.startsWith("sng")) it else null, appleMusicId = if (it.startsWith("sng")) null else it, title = it) })
        val first = store.downloadCollection(sid, state("sng_1", "111", "zzz"))!!
        assertEquals(1, first.added)      // sng_1 and AM 111 resolve to the same song
        assertEquals(1, first.unresolved)
        assertEquals("MwF — Party", host.names[first.pocketId])
        assertEquals(first.pocketId, store.entry(sid)!!.pocketId)
        host.catalog = host.catalog + IndexSong(id = "sng_2", artist = "a", name = "b")
        val second = store.downloadCollection(sid, state("sng_1", "sng_2"))!!
        assertEquals(first.pocketId, second.pocketId)
        assertEquals(1, host.pockets.size)
        assertEquals(listOf("sng_1", "sng_2"), host.pockets[first.pocketId])
        assertNull(store.downloadCollection(sid, MwFState(sessionId = sid)))
    }

    @Test fun approveMatchesOffCallerThreadAndSurvivesExternalMatcherThrowing() = runBlocking(kotlinx.coroutines.CoroutineName("caller")) {
        makeLeader()
        host.externalMatch = com.levi.pocketdj.data.jukebox.JukeboxExternalMatch { _, _ -> throw java.io.IOException("boom") }
        reply("POST /mwf/$sid/suggestions/s1/decision")
        reply("GET /mwf/$sid/state")
        val caller = Thread.currentThread().name
        store.approve(sid, MwFSuggestion(id = "s1", title = "Nope", artist = "Nobody"))
        assertTrue(log.any { it.startsWith("POST /mwf/$sid/suggestions/s1/decision") })
        assertNotNull(host.songsThread)
        assertTrue("matcher ran on caller thread $caller", host.songsThread != caller)
    }

    @Test fun recoveryReusesRememberedDisplayName() = runBlocking {
        reply("POST /mwf", body = createBody)
        assertNull(store.create("Party", "disco", "Sam", MwFSettings()))
        assertEquals("Sam", kv.getString(MusicWithFriendsStore.DISPLAY_NAME_KEY))
        reply("GET /mwf/$sid/state", code = 401)
        var joinBody = ""
        val inner = server.dispatcher
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method == "POST" && request.path!!.endsWith("/join")) joinBody = request.body.readUtf8()
                return inner.dispatch(request)
            }
        }
        reply("POST /mwf/$sid/join", body = """{"memberId":"m9","memberKey":"MK9"}""")
        store.refresh(sid)
        assertTrue(joinBody, joinBody.contains("Sam"))
        assertFalse(joinBody, joinBody.contains("Player"))
    }

    @Test fun redownloadReportsOnlyNewSongsAndEmptyCollectionMakesNoPocket() = runBlocking {
        makeLeader()
        fun state(vararg ids: String) = MwFState(sessionId = sid, name = "Party", theme = "disco",
            collection = ids.map { MwFCollectionEntry(songId = null, appleMusicId = it, title = it) })
        assertNull(store.downloadCollection(sid, state("zzz")))
        assertTrue(host.pockets.isEmpty())
        val first = store.downloadCollection(sid, state("111"))!!
        assertEquals(1, first.added)
        val again = store.downloadCollection(sid, state("111"))!!
        assertEquals(0, again.added)
    }

    @Test fun eraseAllClearsEverything() = runBlocking {
        makeLeader()
        store.setQueueAccepted(true)
        store.handleOpenedLink(MwFLink.parse("pocketdj://mwf/wxyz2345")!!)
        reply("GET /mwf/$sid/state", body = """{"sessionId":"$sid","ended":true}""")
        store.refresh(sid)
        store.eraseAll()
        assertTrue(store.sessions.value.isEmpty() && store.lastState.value.isEmpty())
        assertNull(store.pendingOpenId.value); assertNull(store.pendingJoin.value)
        assertFalse(store.queueAccepted.value)
        assertTrue(sessionFile.load().isEmpty())
        assertNull(kv.getString(MusicWithFriendsStore.SCORED_KEY))
        val fresh = build().also { it.loadPersisted() }
        assertTrue(fresh.sessions.value.isEmpty())
    }
}

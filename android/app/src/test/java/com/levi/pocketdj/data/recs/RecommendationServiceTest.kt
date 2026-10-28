package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.data.collections.Playlist
import com.levi.pocketdj.data.collections.PlaylistNode
import com.levi.pocketdj.data.collections.Pocket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class RecommendationServiceTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var scope: CoroutineScope

    /** Per-test route table: path prefix -> responder. Default 200 `{"ok":true}`. */
    private val responders = ArrayList<Pair<(RecordedRequest) -> Boolean, (RecordedRequest) -> MockResponse>>()
    private val requests = java.util.Collections.synchronizedList(ArrayList<RecordedRequest>())

    @Before fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        server = MockWebServer().apply {
            dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests += request
                    for ((m, r) in responders) if (m(request)) return r(request)
                    return MockResponse().setBody("""{"ok":true,"totals":{"plays":1}}""")
                }
            }
            start()
        }
    }

    @After fun tearDown() { scope.cancel(); server.shutdown() }

    private fun on(prefix: String, method: String? = null, r: (RecordedRequest) -> MockResponse) {
        responders.add(0, ({ q: RecordedRequest -> q.path!!.startsWith(prefix) && (method == null || q.method == method) }) to r)
    }

    private fun events() = requests.filter { it.method == "POST" && it.path == "/events" }
    private fun body(r: RecordedRequest): JsonObject = PdjJson.lenient.parseToJsonElement(r.body.clone().readUtf8()).jsonObject

    private class Knobs {
        @Volatile var enabled = true
        @Volatile var shareCounts = true
        @Volatile var now = 1_800_000_000_000L
        @Volatile var plays: List<RecPlayEventWire> = emptyList()
        @Volatile var favs: List<RecFavoriteWire> = emptyList()
        @Volatile var collections: List<RecFlatCollection> = emptyList()
        @Volatile var recsOffIds: Set<String> = emptySet()
    }

    private fun svc(
        k: Knobs = Knobs(),
        dir: File = tmp.root,
        profile: String = "profile-A",
        autoDelay: Long = 600_000L,
    ): Pair<RecommendationService, Knobs> {
        val client = RecEngineClient(OkHttpClient(), base = { server.url("/").toString() }, enrollSecret = { "ENROLL" }, deviceId = { "dev-1" })
        val s = RecommendationService(
            client = client, scope = scope,
            enabled = { k.enabled }, shareLifetimePlayCounts = { k.shareCounts },
            profileId = { profile }, deviceId = { "dev-1" },
            keyFile = File(dir, "pocketdj-rec-key.json"), stateFile = File(dir, "pocketdj-rec-sync.json"),
            pendingDeleteFile = File(dir, "pocketdj-rec-pending-delete.json"),
            playsProvider = { k.plays }, favoritesProvider = { k.favs },
            collectionsProvider = { k.collections },
            recommendationsEnabledFor = { it !in k.recsOffIds },
            clock = { k.now }, autoFlushDelayMs = autoDelay,
        )
        return s to k
    }

    private fun play(i: Int, at: Double) = RecPlayEventWire("p$i", "song$i", at, "browser")

    // ---- gate ------------------------------------------------------------------------------

    @Test fun disabled_everyNetworkMethod_makesZeroRequests() = runBlocking {
        val (s, k) = svc()
        k.enabled = false
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        s.refreshForYou(force = true)
        assertEquals(emptyList<ForYouCloudZoneRow>(), s.cloudZoneRanking())
        assertEquals(emptyList<RecCollectionSuggestionWire>(), s.rawCollectionSuggestions("s"))
        assertEquals(emptyList<RecCollectionSuggestionWire>(), s.cachedCollectionSuggestions("s"))
        assertEquals(emptyList<String>(), s.similarSongs(listOf("a")))
        s.enqueueAudioAnalysis(listOf("x"))
        s.flushSoon()
        assertNull(s.sharedCredentials())
        // No tombstone => the retry is silent too, and nothing minted a key.
        s.retryPendingCloudDelete()
        Thread.sleep(150)
        assertEquals(0, server.requestCount)
        assertFalse(File(tmp.root, "pocketdj-rec-key.json").exists())
        assertEquals(emptyList<String>(), s.syncState.audioPendingUpload)
    }

    // ---- key + scoped id ---------------------------------------------------------------------

    @Test fun scopedProfileId_isHmacSha256_knownVector() {
        // RFC-style vector: HMAC_SHA256(key="key", "The quick brown fox jumps over the lazy dog")
        assertEquals(
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
            RecommendationService.scopedProfileId("The quick brown fox jumps over the lazy dog", "key"),
        )
    }

    @Test fun firstFlush_mintsKey_persistsIt_andSendsScopedId() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        val doc = PdjJson.lenient.parseToJsonElement(File(tmp.root, "pocketdj-rec-key.json").readText()).jsonObject
        val key = (doc["key"] as JsonPrimitive).content
        assertTrue(Regex("[0-9a-f]{64}").matches(key))
        assertEquals(1, doc["schemaVersion"]!!.jsonPrimitive_int())
        val r = events().single()
        assertEquals("Bearer $key", r.getHeader("Authorization"))
        assertEquals(RecommendationService.scopedProfileId("profile-A", key), r.getHeader("X-PocketDJ-Profile"))
        assertNotEquals("profile-A", r.getHeader("X-PocketDJ-Profile"))
        assertEquals("ENROLL", r.getHeader("X-PocketDJ-Enroll"))
        // A second service over the same files reuses the key (cross-device sync presents the same one).
        val (s2, _) = svc(Knobs())
        assertEquals(key, s2.sharedCredentials()!!.key)
    }

    private fun kotlinx.serialization.json.JsonElement.jsonPrimitive_int() = (this as JsonPrimitive).int

    @Test fun reloadKeyFromDisk_rebind_resetsCursors_andDeletesOrphan() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        val losing = s.sharedCredentials()!!.key
        assertTrue(s.syncState.uploadedPlays.isNotEmpty())
        File(tmp.root, "pocketdj-rec-key.json").writeText("""{"schemaVersion":1,"key":"winner-key"}""")
        s.reloadKeyFromDisk()
        assertEquals(0.0, s.syncState.lastPlayAtMs, 0.0)
        assertTrue(s.syncState.uploadedPlays.isEmpty())
        assertTrue(s.syncState.didMigrateScopedProfile)
        waitFor { requests.any { it.method == "DELETE" } }
        val del = requests.first { it.method == "DELETE" }
        assertEquals("Bearer $losing", del.getHeader("Authorization"))
        assertEquals(RecommendationService.scopedProfileId("profile-A", losing), del.getHeader("X-PocketDJ-Profile"))
        assertEquals("winner-key", s.sharedCredentials()!!.key)
    }

    // ---- cursors, acks, window ---------------------------------------------------------------

    @Test fun flush_advancesCursorsToMaxSent_remembersAcks_andQuietFlushSendsNothing() = runBlocking {
        val (s, k) = svc()
        val t = k.now.toDouble()
        k.plays = listOf(play(2, t - 1000), play(1, t - 5000), play(3, t - 10))
        k.favs = listOf(RecFavoriteWire("song1", true, t - 7))
        s.flushNow()
        val sent = body(events().single())
        assertEquals(listOf("p1", "p2", "p3"), sent["plays"]!!.jsonArray.map { it.jsonObject["id"]!!.let { i -> (i as JsonPrimitive).content } })
        assertEquals(t - 10, s.syncState.lastPlayAtMs, 0.0)
        assertEquals(t - 7, s.syncState.lastFavoriteAtMs, 0.0)
        assertEquals(3, s.syncState.uploadedPlays.size)
        assertNotNull(s.lastSyncedAtMs.value)
        assertNull(s.syncError.value)
        s.flushNow()
        assertEquals("quiet flush must be zero requests", 1, events().size)
    }

    @Test fun peerEventBelowCursor_insideWindow_uploads_butOlderThanWindow_doesNot() = runBlocking {
        val (s, k) = svc()
        val t = k.now.toDouble()
        k.plays = listOf(play(1, t))
        s.flushNow()
        val day = 86_400_000.0
        k.plays = k.plays + listOf(play(2, t - 10 * day), play(3, t - 40 * day))
        s.flushNow()
        val second = body(events()[1])
        assertEquals(listOf("p2"), second["plays"]!!.jsonArray.map { (it.jsonObject["id"] as JsonPrimitive).content })
        assertEquals("cursor must not move backwards", t, s.syncState.lastPlayAtMs, 0.0)
    }

    @Test fun remember_evictionKeepsNewest_evenWhenPeerAcksAreAppendedOld() {
        val existing = listOf("1000|a", "2000|b", "3000|c")
        val added = listOf("500|peer1", "600|peer2") // freshly merged OLD peer events at the tail
        val kept = RecommendationService.remember(existing, added, floor = 0.0, cap = 3)
        assertEquals(listOf("1000|a", "2000|b", "3000|c"), kept)
    }

    @Test fun remember_prunesBelowFloor_andIsStableOnTies() {
        val kept = RecommendationService.remember(listOf("100|a", "9000|z"), listOf("9000|b"), floor = 5000.0, cap = 10)
        assertEquals(listOf("9000|z", "9000|b"), kept)
        val capped = RecommendationService.remember(emptyList(), listOf("5|b", "5|a", "6|c"), floor = 0.0, cap = 2)
        assertEquals(listOf("5|b", "6|c"), capped) // oldest by (atMs, string) evicted: "5|a"
    }

    @Test fun ack_format_and_ackAtMs_roundTrip() {
        assertEquals("1234|abc", RecommendationService.ack(1234.4, "abc"))
        assertEquals(1234.0, RecommendationService.ackAtMs("1234|abc"), 0.0)
        assertEquals(0.0, RecommendationService.ackAtMs("garbage"), 0.0)
        assertEquals(0.0, RecommendationService.windowFloor(10.0), 0.0)
    }

    @Test fun batches_capAt500PerStream_cursorAdvancesPerBatch() = runBlocking {
        val (s, k) = svc()
        val t = k.now.toDouble()
        k.plays = (1..1200).map { play(it, t - 2000 + it) }
        s.flushNow()
        val sizes = events().map { body(it)["plays"]!!.jsonArray.size }
        assertEquals(listOf(500, 500, 200), sizes)
        assertEquals(1200, s.syncState.uploadedPlays.size)
        assertEquals(t - 2000 + 1200, s.syncState.lastPlayAtMs, 0.0)
        // The (empty) membership snapshot rides only the first batch.
        assertTrue(body(events()[0]).containsKey("collectionsSnapshot"))
        assertFalse(body(events()[1]).containsKey("collectionsSnapshot"))
    }

    @Test fun failedUpload_doesNotAdvanceCursors_andRetrySendsAgain() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        on("/events") { MockResponse().setResponseCode(503) }
        s.flushNow()
        assertEquals(0.0, s.syncState.lastPlayAtMs, 0.0)
        assertTrue(s.syncState.uploadedPlays.isEmpty())
        assertEquals(RecommendationService.COULDNT_REACH, s.syncError.value)
        assertNull(s.lastSyncedAtMs.value)
        responders.clear()
        s.flushNow()
        assertEquals(2, events().size)
        assertNull(s.syncError.value)
        assertEquals(1, s.syncState.uploadedPlays.size)
    }

    @Test fun forbidden_setsDistinctMessages_andNeverAdvances() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        on("/events") { MockResponse().setResponseCode(403).setBody("""{"error":"key-mismatch"}""") }
        s.flushNow()
        assertEquals(RecommendationService.KEY_MISMATCH_MESSAGE, s.syncError.value)
        responders.clear()
        on("/events") { MockResponse().setResponseCode(403).setBody("""{"error":"enrollment-required"}""") }
        s.flushNow()
        assertEquals(RecommendationService.ENROLLMENT_REQUIRED_MESSAGE, s.syncError.value)
        assertEquals(0.0, s.syncState.lastPlayAtMs, 0.0)
    }

    @Test fun flushEpochBump_abandonsInFlightFlush_withoutAdvancingCursors() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        on("/events") { MockResponse().setBody("""{"ok":true}""").setHeadersDelay(600, TimeUnit.MILLISECONDS) }
        val job = scope.launch { s.flushNow() }
        waitFor { requests.any { it.path == "/events" } }
        val before = s.epoch
        s.enabledDidChange() // a toggle landing mid-drain
        assertEquals(before + 1, s.epoch)
        job.join()
        assertEquals(0.0, s.syncState.lastPlayAtMs, 0.0)
        assertTrue(s.syncState.uploadedPlays.isEmpty())
        assertNull(s.lastSyncedAtMs.value)
        assertNull(s.syncError.value)
        assertFalse("abandoned flush must not persist acks", File(tmp.root, "pocketdj-rec-sync.json").readText().contains("uploadedPlays\":[\""))
    }

    // ---- snapshot caps -----------------------------------------------------------------------

    @Test fun snapshotCaps_500Collections_5kEach_100kTotal() = runBlocking {
        val (s, k) = svc()
        k.collections = (1..600).map { c -> RecFlatCollection("pkt_$c", "pocket", "C$c", (1..6000).map { "s$it" }) }
        s.flushNow()
        val snap = body(events().single())["collectionsSnapshot"]!!.jsonObject
        val cols = snap["collections"]!!.jsonArray
        assertEquals(500, cols.size)
        val sizes = cols.map { it.jsonObject["songIds"]!!.jsonArray.size }
        assertTrue(sizes.all { it <= 5000 })
        assertEquals(100_000, sizes.sum())
        assertEquals(20, sizes.count { it == 5000 })
    }

    @Test fun snapshotOverByteCap_isDropped_hashNotAdvanced_andNoRequest() = runBlocking {
        val (s, k) = svc()
        val longId = "x".repeat(60)
        k.collections = (1..20).map { c -> RecFlatCollection("pkt_$c", "pocket", "C$c", (1..5000).map { "$longId$it" }) }
        s.flushNow() // snapshot-only and oversize => nothing deliverable
        assertEquals(0, server.requestCount)
        assertNull(s.syncState.lastCollectionsHash)
    }

    @Test fun http413_dropsBulkPayloads_butEventsStillDeliver_andHashStaysUnadvanced() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        k.collections = listOf(RecFlatCollection("pkt_1", "pocket", "P", listOf("a")))
        val n = AtomicInteger()
        on("/events") { if (n.getAndIncrement() == 0) MockResponse().setResponseCode(413) else MockResponse().setBody("{}") }
        s.flushNow()
        val ev = events()
        assertEquals(2, ev.size)
        assertTrue(body(ev[0]).containsKey("collectionsSnapshot"))
        assertFalse(body(ev[1]).containsKey("collectionsSnapshot"))
        assertEquals(1, s.syncState.uploadedPlays.size)
        assertNull("a smaller membership must re-attempt later", s.syncState.lastCollectionsHash)
    }

    @Test fun snapshotHash_isStableAcrossCalls_andGatesReUpload() = runBlocking {
        val (s, k) = svc()
        k.collections = listOf(RecFlatCollection("pkt_1", "pocket", "P", listOf("a", "b")))
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        assertNotNull(s.syncState.lastCollectionsHash)
        k.now += 5000 // atMs changes every call; must not defeat the gate
        k.plays = k.plays + play(2, k.now.toDouble())
        s.flushNow()
        assertTrue(body(events()[0]).containsKey("collectionsSnapshot"))
        assertFalse(body(events()[1]).containsKey("collectionsSnapshot"))
        k.collections = listOf(RecFlatCollection("pkt_1", "pocket", "P", listOf("a", "b", "c")))
        s.flushNow()
        assertEquals(3, events().size)
        assertTrue(body(events()[2]).containsKey("collectionsSnapshot"))
    }

    // ---- play counts ---------------------------------------------------------------------------

    @Test fun playCounts_hashGated_andHonoursOptOut() = runBlocking {
        val (s, k) = svc()
        s.playCountsProvider = { mapOf("a" to 3, "b" to 0, "c" to 9) }
        s.lastPlayedProvider = { mapOf("a" to 86_400_000.0 * 100 + 5, "z" to 1.0) }
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        val pc = body(events()[0])["playCounts"]!!.jsonObject
        assertEquals(setOf("a", "c"), pc["counts"]!!.jsonObject.keys)
        assertEquals(setOf("a"), pc["lastPlayedDays"]!!.jsonObject.keys)
        assertEquals(100, pc["lastPlayedDays"]!!.jsonObject["a"]!!.jsonPrimitive_int())
        k.plays = k.plays + play(2, k.now.toDouble() + 1)
        s.flushNow()
        assertFalse("unchanged counts must not re-upload 20k rows", body(events()[1]).containsKey("playCounts"))
        s.playCountsProvider = { mapOf("a" to 4) }
        k.plays = k.plays + play(3, k.now.toDouble() + 2)
        s.flushNow()
        assertTrue(body(events()[2]).containsKey("playCounts"))
    }

    @Test fun playCounts_optOut_neverSent() = runBlocking {
        val (s, k) = svc()
        k.shareCounts = false
        s.playCountsProvider = { mapOf("a" to 3) }
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        assertFalse(body(events().single()).containsKey("playCounts"))
    }

    // ---- cloud zone + TTL --------------------------------------------------------------------

    private val songsBody = """{"songs":[{"songId":"b","name":"B","reasons":["","Same genre"]},{"songId":"a","reasons":[]},{"bad":1}]}"""

    @Test fun cloudZoneRanking_serverOrder_firstNonEmptyReasonAsWhy() = runBlocking {
        val (s, _) = svc()
        on("/recs/songs") { MockResponse().setBody(songsBody) }
        val rows = s.cloudZoneRanking()
        assertEquals(listOf(ForYouCloudZoneRow("b", "Same genre"), ForYouCloudZoneRow("a", null)), rows)
        val r = requests.first { it.path!!.startsWith("/recs/songs") }
        assertEquals("/recs/songs?limit=200", r.path)
        assertNull(r.getHeader("X-PocketDJ-Enroll"))
    }

    @Test fun forYouCloudZoneProvider_wiredOnlyWhenEnabled_andReturnsServerOrder() = runBlocking {
        val (s, k) = svc()
        on("/recs/songs") { MockResponse().setBody(songsBody) }
        val provider = com.levi.pocketdj.screens.foryou.ForYouInputsFactory.cloudZoneProvider(s, force = true)
        assertNotNull(provider)
        assertEquals(listOf("b", "a"), provider!!.invoke().map { it.songId })
        k.enabled = false
        assertNull(com.levi.pocketdj.screens.foryou.ForYouInputsFactory.cloudZoneProvider(s, force = true))
    }

    @Test fun cloudZoneRanking_returnsEmptyOnAnyFailure() = runBlocking {
        val (s, _) = svc()
        on("/recs/songs") { MockResponse().setResponseCode(500) }
        assertEquals(emptyList<ForYouCloudZoneRow>(), s.cloudZoneRanking())
        responders.clear()
        on("/recs/songs") { MockResponse().setResponseCode(403).setBody("""{"error":"key-mismatch"}""") }
        assertEquals(emptyList<ForYouCloudZoneRow>(), s.cloudZoneRanking())
        assertEquals(RecommendationService.KEY_MISMATCH_MESSAGE, s.syncError.value)
        responders.clear()
        on("/recs/songs") { MockResponse().setBody("garbage") }
        assertEquals(emptyList<ForYouCloudZoneRow>(), s.cloudZoneRanking())
    }

    @Test fun forYou_ttl15Min_unlessForce() = runBlocking {
        val (s, k) = svc()
        on("/recs/songs") { MockResponse().setBody(songsBody) }
        fun gets() = requests.count { it.path!!.startsWith("/recs/songs") }
        s.refreshForYou(force = false)
        s.refreshForYou(force = false)
        assertEquals(1, gets())
        k.now += 14 * 60_000
        s.refreshForYou(force = false)
        assertEquals(1, gets())
        s.refreshForYou(force = true)
        assertEquals(2, gets())
        k.now += 16 * 60_000
        s.refreshForYou(force = false)
        assertEquals(3, gets())
    }

    // ---- collection suggestions ----------------------------------------------------------------

    private val sugBody = """{"songId":"s","suggestions":[{"id":"pkt_1","kind":"pocket","name":"One","reasons":["fits"]},{"id":"pls_2","name":"Two"}]}"""

    @Test fun suggestions_cachedPerSong_dropRecsOffAppliedOnRead_noRefetch() = runBlocking {
        val (s, k) = svc()
        on("/recs/collections") { MockResponse().setBody(sugBody) }
        fun gets() = requests.count { it.path!!.startsWith("/recs/collections") }
        val first = s.collectionSuggestions("s")
        assertEquals(listOf("pkt_1" to "pocket", "pls_2" to "playlist"), first.map { it.id to it.kind })
        assertEquals("fits", first[0].reasons.single())
        assertEquals("Two", first[1].name)
        k.recsOffIds = setOf("pkt_1")
        assertEquals(listOf("pls_2"), s.rawCollectionSuggestions("s").map { it.id })
        assertEquals(1, gets())
    }

    @Test fun suggestionsCache_isLru20_andTtl15Min() = runBlocking {
        val (s, k) = svc()
        on("/recs/collections") { MockResponse().setBody(sugBody) }
        fun gets() = requests.count { it.path!!.startsWith("/recs/collections") }
        for (i in 1..21) s.rawCollectionSuggestions("song$i")
        assertEquals(21, gets())
        s.rawCollectionSuggestions("song21"); s.rawCollectionSuggestions("song2")
        assertEquals("newest 20 stay cached", 21, gets())
        s.rawCollectionSuggestions("song1") // evicted first
        assertEquals(22, gets())
        k.now += 16 * 60_000
        s.rawCollectionSuggestions("song21")
        assertEquals(23, gets())
    }

    @Test fun suggestions_failure_isEmpty_neverThrows() = runBlocking {
        val (s, _) = svc()
        on("/recs/collections") { MockResponse().setResponseCode(500) }
        assertEquals(emptyList<RecCollectionSuggestionWire>(), s.rawCollectionSuggestions("s"))
    }

    @Test fun cachedCollectionSuggestions_missStartsOneFetch_thenBumpsRevision() = runBlocking {
        val (s, _) = svc()
        on("/recs/collections") { MockResponse().setBody(sugBody) }
        assertEquals(emptyList<RecCollectionSuggestionWire>(), s.cachedCollectionSuggestions("s"))
        assertEquals(emptyList<RecCollectionSuggestionWire>(), s.cachedCollectionSuggestions("s")) // in flight: no 2nd fetch
        waitFor { s.collectionSuggestionsRevision.value == 1 }
        assertEquals(2, s.cachedCollectionSuggestions("s").size)
        assertEquals(1, requests.count { it.path!!.startsWith("/recs/collections") })
    }

    @Test fun similarSongs_cachedBySortedIds_lru8_failureEmpty() = runBlocking {
        val (s, _) = svc()
        on("/recs/similar") { MockResponse().setBody(songsBody) }
        fun gets() = requests.count { it.path!!.startsWith("/recs/similar") }
        assertEquals(listOf("b", "a"), s.similarSongs(listOf("y", "x")))
        s.similarSongs(listOf("x", "y"))
        assertEquals(1, gets())
        assertTrue(requests.last().path!!.contains("collectionIds=y%2Cx"))
        s.similarSongs(listOf("a", "b", "c", "d", "e"))
        assertTrue(requests.last().path!!.contains("collectionIds=a%2Cb%2Cc"))
        responders.clear(); on("/recs/similar") { MockResponse().setResponseCode(404) }
        assertEquals(emptyList<String>(), s.similarSongs(listOf("q")))
    }

    // ---- delete / tombstone / migration ----------------------------------------------------------

    @Test fun deleteCloudData_noKeyNoHistory_isZeroNetworkZeroMint() = runBlocking {
        val (s, _) = svc()
        assertTrue(s.deleteCloudData())
        assertEquals(0, server.requestCount)
        assertFalse(File(tmp.root, "pocketdj-rec-key.json").exists())
    }

    @Test fun deleteCloudData_afterUpload_deletesWithEnroll_resetsLocal_andCascades() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        val key = s.sharedCredentials()!!.key
        var cascaded: Pair<String, String>? = null
        s.onDeleteCloudData = { kk, pp -> cascaded = kk to pp }
        assertTrue(s.deleteCloudData())
        val del = requests.last { it.method == "DELETE" }
        assertEquals("/state", del.path)
        assertEquals("ENROLL", del.getHeader("X-PocketDJ-Enroll"))
        assertEquals("Bearer $key", del.getHeader("Authorization"))
        val scoped = RecommendationService.scopedProfileId("profile-A", key)
        assertEquals(scoped, del.getHeader("X-PocketDJ-Profile"))
        assertEquals(key to scoped, cascaded)
        assertNull(s.syncState.lastSyncedAtMs)
        assertTrue(s.syncState.uploadedPlays.isEmpty())
        assertTrue(s.syncState.didMigrateScopedProfile)
    }

    @Test fun deleteCloudData_refused_reportsAndKeepsLocal() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        on("/state", "DELETE") { MockResponse().setResponseCode(403).setBody("""{"error":"enrollment-required"}""") }
        assertFalse(s.deleteCloudData())
        assertEquals(RecommendationService.DELETE_REFUSED_MESSAGE, s.syncError.value)
        assertNotNull(s.syncState.lastSyncedAtMs)
        responders.clear()
        on("/state", "DELETE") { MockResponse().setResponseCode(503) }
        assertFalse(s.deleteCloudData())
        assertEquals("Couldn't delete the cloud data — try again.", s.syncError.value)
    }

    @Test fun reEnableAfterDelete_mintsAFreshKey() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        val old = s.sharedCredentials()!!.key
        assertTrue(s.deleteCloudData())
        s.clearLocal(cloudDeleted = true)
        assertFalse(File(tmp.root, "pocketdj-rec-key.json").exists())
        assertFalse(s.hasPendingCloudDelete)
        k.plays = listOf(play(2, k.now.toDouble() + 10))
        s.flushNow()
        val fresh = s.sharedCredentials()!!.key
        assertNotEquals(old, fresh)
        assertEquals("Bearer $fresh", events().last().getHeader("Authorization"))
    }

    @Test fun clearLocal_cloudDeleteFailed_parksCredentialInTombstone_thenRetryFinishesIt() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        val key = s.sharedCredentials()!!.key
        val scoped = RecommendationService.scopedProfileId("profile-A", key)
        s.clearLocal(cloudDeleted = false)
        assertTrue(s.hasPendingCloudDelete)
        assertFalse("key file removed in BOTH branches", File(tmp.root, "pocketdj-rec-key.json").exists())
        k.enabled = false // the retry is the one carved exception to toggle-off => zero network
        val before = requests.size
        s.retryPendingCloudDelete()
        val del = requests.drop(before).single()
        assertEquals("DELETE", del.method)
        assertEquals("Bearer $key", del.getHeader("Authorization"))
        assertEquals(scoped, del.getHeader("X-PocketDJ-Profile"))
        assertFalse(s.hasPendingCloudDelete)
    }

    @Test fun pendingDelete_transientFailureCountsAttempts_terminal403GivesUp() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        s.clearLocal(cloudDeleted = false)
        val f = File(tmp.root, "pocketdj-rec-pending-delete.json")
        on("/state", "DELETE") { MockResponse().setResponseCode(503) }
        s.retryPendingCloudDelete()
        s.retryPendingCloudDelete()
        assertEquals(2, PdjJson.lenient.parseToJsonElement(f.readText()).jsonObject["attempts"]!!.jsonPrimitive_int())
        responders.clear()
        on("/state", "DELETE") { MockResponse().setResponseCode(403).setBody("{}") }
        s.retryPendingCloudDelete()
        assertFalse("a 403 is terminal immediately", f.exists())
        assertEquals(RecommendationService.PENDING_DELETE_GAVE_UP, s.syncError.value)
    }

    @Test fun pendingDelete_givesUpAfterTwentyAttempts_withoutAnyRequest() = runBlocking {
        val (s, _) = svc()
        File(tmp.root, "pocketdj-rec-pending-delete.json").writeText(
            """{"schemaVersion":1,"key":"k","profileId":"p","requestedAtMs":1800000000000.0,"attempts":20}""",
        )
        s.retryPendingCloudDelete()
        assertEquals(0, server.requestCount)
        assertFalse(s.hasPendingCloudDelete)
    }

    @Test fun migration_offBroadcastId_deletesRawIdObject_thenResetsCursors_andReuploadsEverything() = runBlocking {
        val (s0, k0) = svc()
        k0.plays = listOf(play(1, k0.now.toDouble()))
        s0.flushNow()
        val key = s0.sharedCredentials()!!.key
        // Simulate a pre-scoped-id install: enrolled under the RAW id, flag not yet set.
        File(tmp.root, "pocketdj-rec-sync.json").writeText(
            """{"schemaVersion":1,"lastPlayAtMs":${k0.now.toDouble()},"lastSyncedAtMs":1.0,"uploadedPlays":["${k0.now}|p1"]}""",
        )
        requests.clear()
        val (s, k) = svc(k0)
        s.flushNow()
        val del = requests[0]
        assertEquals("DELETE", del.method)
        assertEquals("profile-A", del.getHeader("X-PocketDJ-Profile")) // the RAW id
        assertEquals("Bearer $key", del.getHeader("Authorization"))
        val post = requests[1]
        assertEquals(RecommendationService.scopedProfileId("profile-A", key), post.getHeader("X-PocketDJ-Profile"))
        assertEquals("history re-uploads under the scoped id", 1, body(post)["plays"]!!.jsonArray.size)
        assertTrue(s.syncState.didMigrateScopedProfile)
        assertNotNull(k)
    }

    @Test fun migration_transientFailure_abandonsFlush_andRetriesNextTime() = runBlocking {
        val (s0, k0) = svc()
        k0.plays = listOf(play(1, k0.now.toDouble()))
        s0.sharedCredentials()
        File(tmp.root, "pocketdj-rec-sync.json").writeText("""{"schemaVersion":1,"lastSyncedAtMs":1.0}""")
        val (s, _) = svc(k0)
        on("/state", "DELETE") { MockResponse().setResponseCode(503) }
        s.flushNow()
        assertEquals(0, events().size)
        assertFalse(s.syncState.didMigrateScopedProfile)
        responders.clear()
        s.flushNow()
        assertEquals(1, events().size)
        assertTrue(s.syncState.didMigrateScopedProfile)
    }

    @Test fun neverUploaded_install_skipsMigration_noDelete() = runBlocking {
        val (s, k) = svc()
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        assertTrue(requests.none { it.method == "DELETE" })
    }

    // ---- audio shortlist --------------------------------------------------------------------------

    @Test fun audioShortlist_ridesFirstBatch_thenMovesToQueued_andDedupes() = runBlocking {
        val (s, k) = svc()
        s.enqueueAudioAnalysis(listOf("a1", "a2"))
        assertEquals(setOf("a1", "a2"), s.audioPendingIds)
        s.enqueueAudioAnalysis(listOf("a2", "a3"))
        assertEquals(listOf("a1", "a2", "a3"), s.syncState.audioPendingUpload)
        k.plays = (1..600).map { play(it, k.now.toDouble() - 1000 + it) }
        s.flushNow()
        val ev = events()
        assertEquals(setOf("a1", "a2", "a3"), body(ev[0])["audioQueue"]!!.jsonObject["songIds"]!!.jsonArray.map { (it as JsonPrimitive).content }.toSet())
        assertFalse(body(ev[1]).containsKey("audioQueue"))
        assertTrue(s.syncState.audioPendingUpload.isEmpty())
        assertEquals(listOf("a1", "a2", "a3"), s.syncState.audioQueued)
        s.enqueueAudioAnalysis(listOf("a1")) // the server already holds it
        assertTrue(s.syncState.audioPendingUpload.isEmpty())
    }

    // ---- lifecycle + docs --------------------------------------------------------------------------

    @Test fun enabledDidChange_off_cancelsLoop_clearsMemory_butKeepsKeyAndCursors() = runBlocking {
        val (s, k) = svc()
        on("/recs/songs") { MockResponse().setBody(songsBody) }
        k.plays = listOf(play(1, k.now.toDouble()))
        s.flushNow()
        s.refreshForYou(force = true)
        assertTrue(s.forYou.value.isNotEmpty())
        s.startAutoFlush()
        s.startAutoFlush() // idempotent: ONE loop
        assertTrue(s.isAutoFlushArmed)
        k.enabled = false
        s.enabledDidChange()
        assertFalse(s.isAutoFlushArmed)
        assertTrue(s.forYou.value.isEmpty())
        assertTrue(File(tmp.root, "pocketdj-rec-key.json").exists())
        assertEquals(1, s.syncState.uploadedPlays.size)
        k.enabled = true
        s.enabledDidChange()
        assertTrue(s.isAutoFlushArmed)
    }

    @Test fun syncStateDoc_lenientDecode_partialAndUnknownKeys_degradeNeverReset() = runBlocking {
        File(tmp.root, "pocketdj-rec-sync.json").writeText(
            """{"lastPlayAtMs":12.5,"uploadedPlays":["1|a"],"futureKey":{"x":1},"didMigrateScopedProfile":null,"lastSyncedAtMs":99}""",
        )
        val (s, _) = svc()
        assertEquals(12.5, s.syncState.lastPlayAtMs, 0.0)
        assertEquals(listOf("1|a"), s.syncState.uploadedPlays)
        assertFalse(s.syncState.didMigrateScopedProfile)
        assertEquals(0.0, s.syncState.lastFeedbackAtMs, 0.0)
        assertEquals(99L, s.lastSyncedAtMs.value)
    }

    @Test fun feedbackAndPuzzleProviders_areUploaded_andCursored() = runBlocking {
        val (s, k) = svc()
        val t = k.now.toDouble()
        s.feedbackProvider = { listOf(RecFeedbackWire("f1", t - 5, "s1", "rejected", "tile", "zone")) }
        s.puzzleEventsProvider = { listOf(RecPuzzleEventWire("z1", t - 3, action = "file")) }
        s.flushNow()
        val b = body(events().single())
        assertEquals("rejected", (b["feedback"]!!.jsonArray[0].jsonObject["verdict"] as JsonPrimitive).content)
        assertEquals("file", (b["puzzle"]!!.jsonArray[0].jsonObject["action"] as JsonPrimitive).content)
        assertEquals(t - 5, s.syncState.lastFeedbackAtMs, 0.0)
        assertEquals(t - 3, s.syncState.lastPuzzleAtMs, 0.0)
        s.flushNow()
        assertEquals(1, events().size)
    }

    // ---- flattener ---------------------------------------------------------------------------------

    @Test fun flattener_expandsAlbumsAndChildPockets_cycleSafe_deduped() {
        val pockets = listOf(
            Pocket(id = "pkt_a", name = "A", songIds = listOf("s1", "s2"), albumIds = listOf("alb"), childPocketIds = listOf("pkt_b")),
            Pocket(id = "pkt_b", name = "B", songIds = listOf("s2", "s9"), childPocketIds = listOf("pkt_a")),
        )
        val pl = Playlist(
            id = "pls_1", name = "L",
            sequences = listOf(
                PlaylistNode("n1", PlaylistNode.Kind.SONG, songId = "s5"),
                PlaylistNode(
                    "n2", PlaylistNode.Kind.SEQUENCE, name = "ch",
                    children = listOf(
                        PlaylistNode("n3", PlaylistNode.Kind.ALBUM, albumId = "alb"),
                        PlaylistNode("n4", PlaylistNode.Kind.POCKET, pocketId = "pkt_b"),
                        PlaylistNode("n5", PlaylistNode.Kind.TEXT, text = "note"),
                    ),
                ),
            ),
        )
        val flat = RecCollectionFlattener.flatten(
            pockets, listOf(pl), sourcePlaylists = listOf(Triple("src", "Src", listOf("x", "x", "y"))),
            albumTracks = mapOf("alb" to listOf("t1", "s1", "t2")),
        )
        assertEquals(listOf("pocket", "pocket", "playlist", "source"), flat.map { it.kind })
        assertEquals(listOf("s1", "s2", "t1", "t2", "s9"), flat[0].songIds)
        assertEquals(listOf("s2", "s9", "s1", "t1", "t2"), flat[1].songIds)
        assertEquals(listOf("s5", "t1", "s1", "t2", "s2", "s9"), flat[2].songIds)
        assertEquals(listOf("x", "y"), flat[3].songIds)
        assertEquals(setOf("alb"), RecCollectionFlattener.referencedAlbumIds(pockets, listOf(pl)))
    }

    private fun waitFor(timeoutMs: Long = 5000, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!cond()) {
            if (System.currentTimeMillis() > end) throw AssertionError("condition not met in ${timeoutMs}ms")
            Thread.sleep(10)
        }
    }
}

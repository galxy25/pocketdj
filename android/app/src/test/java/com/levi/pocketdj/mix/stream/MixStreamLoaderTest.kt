package com.levi.pocketdj.mix.stream

import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.data.burns.Rig
import com.levi.pocketdj.data.burns.BurnFileNames
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.data.rips.RipStems
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class MixStreamLoaderTest {
    private val origin = Origin()
    private val server = MockWebServer()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val rig = Rig()
    private val clockMs = AtomicLong(1_000_000)
    private val net = SettableNetworkMonitor(true)
    private val entries = HashMap<String, RipManifestEntry>()
    private var hasServer = true
    private val presignFails = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private lateinit var loader: MixStreamLoader
    private lateinit var cacheDir: File
    private val finalized = CopyOnWriteArrayList<String>()
    private val failedIds = CopyOnWriteArrayList<String>()

    private val fakeRips = object : MixStreamRips {
        override fun hasServer() = hasServer
        override fun entry(songId: String) = entries[songId]
        override suspend fun presignedUrl(songId: String, ttlSeconds: Int): String? =
            if (songId in presignFails) null else server.url("/side/$songId.mp3").toString()
        override fun urlForKey(key: String) = server.url("/" + key.removePrefix("/")).toString()
        override fun stemUrls(songId: String) = entries[songId]?.stemUrls(server.url("/").toString())
    }

    @Before fun setUp() {
        server.dispatcher = origin
        server.start()
        cacheDir = File(rig.dir, "cache/mixstream")
        val store = rig.store()
        store.onAnyBurnFinalized = { id, _ -> finalized += id }
        burns = store
        loader = MixStreamLoader(
            rips = fakeRips, adopter = BurnStoreAdopter(store), directory = cacheDir, network = net,
            scope = scope, clock = { clockMs.incrementAndGet() },
        )
        loader.onFailed = { failedIds += it }
    }

    private lateinit var burns: com.levi.pocketdj.data.burns.BurnStore

    @After fun tearDown() {
        loader.pinnedIds = null
        loader.cancel(loader.streams.keys.toList())
        scope.cancel()
        runCatching { server.shutdown() }
        rig.dir.deleteRecursively()
    }

    /** A digital song: manifest entry for both the loader and the burn store, served at /side/<id>.mp3. */
    private fun digital(id: String, size: Int = 30_000): ByteArray {
        val e = RipManifestEntry(key = "rips/$id.mp3", source = "digital", bpm = 120.0)
        entries[id] = e; rig.rips.entries[id] = e
        return bytesOf(size, id.hashCode()).also { origin.bodies["/side/$id.mp3"] = it }
    }

    private fun analog(id: String, albumId: String, startMs: Long, cutKey: String?): RipManifestEntry {
        val e = RipManifestEntry(key = "rips/$albumId.mp3", source = "analog", startMs = startMs, cutKey = cutKey)
        entries[id] = e; rig.rips.entries[id] = e
        return e
    }

    private fun stems(id: String): Map<String, ByteArray> {
        val e = RipManifestEntry(
            key = "rips/$id.mp3", source = "digital",
            stems = RipStems("stems/$id/vocals.mp3", "stems/$id/drums.mp3", "stems/$id/bass.mp3", "stems/$id/other.mp3"),
        )
        entries[id] = e; rig.rips.entries[id] = e
        return BurnFileNames.STEM_NAMES.associateWith { n -> bytesOf(12_000, n.hashCode()).also { origin.bodies["/stems/$id/$n.mp3"] = it } }
    }

    // ---- canStream ----------------------------------------------------------------------------

    @Test fun canStreamGates() {
        digital("a")
        assertTrue(loader.canStream("a"))
        assertFalse("not in manifest", loader.canStream("ghost"))
        net.available = false
        assertFalse("offline", loader.canStream("a"))
        net.available = true
        hasServer = false
        assertFalse("no rip server", loader.canStream("a"))
        hasServer = true
        assertTrue(loader.isRipped("a"))
        assertFalse(loader.isRipped("ghost"))
    }

    @Test fun perSongFailureCooldownThenServerDownCooldown() {
        digital("a"); digital("b")
        origin.status["/side/a.mp3"] = 500
        assertNotNull(loader.open("a", "A", "x"))
        waitUntil(what = "a failed") { failedIds.contains("a") }
        assertNull(loader.stream("a")) // record dropped so a later open starts clean
        // HTTP failure trips the server-down cooldown (everything refused) ...
        assertFalse(loader.canStream("b"))
        clockMs.addAndGet(60_001)
        // ... which lifts after 60 s, while the per-song cooldown on "a" holds for 120 s.
        assertTrue(loader.canStream("b"))
        assertFalse(loader.canStream("a"))
        clockMs.addAndGet(60_000)
        assertTrue(loader.canStream("a"))
    }

    @Test fun autoCooldownScheduleBacksOffThenFallsToDefaultAndResetsOnSuccess() {
        digital("a")
        // The injected clock ticks on every read, so assert with a margin either side of each bound.
        fun failOnce() {
            val s = loader.open("a", "A", "x", forAuto = true)
            assertNotNull(s)
            loader.failStreamForTesting("a")
        }
        fun blockedAt(ms: Long) { clockMs.addAndGet(ms); assertFalse(loader.canStream("a", forAuto = true)) }
        fun openAfter(ms: Long) { clockMs.addAndGet(ms); assertTrue(loader.canStream("a", forAuto = true)) }
        // 1st failure: 2 s for Auto, manual still 120 s (and manual open refuses).
        failOnce()
        blockedAt(1_500)
        openAfter(1_000)
        assertFalse("manual keeps 120 s", loader.canStream("a"))
        assertNull(loader.open("a", "A", "x"))
        // 2nd failure: 2 s.
        failOnce()
        blockedAt(1_500)
        openAfter(1_000)
        // 3rd failure: 3 s.
        failOnce()
        blockedAt(2_500)
        openAfter(1_000)
        // 4th consecutive failure: back to the 120 s default, even for Auto.
        failOnce()
        blockedAt(60_000)
        openAfter(61_000)
        // A completed stream resets the schedule: next failure is 2 s again.
        val f = java.io.File.createTempFile("okok", ".mp3")
        assertNotNull(loader.open("a", "A", "x", forAuto = true))
        loader.injectStreamForTesting("a", f, 10, 10)
        loader.completeStreamForTesting("a")
        failOnce()
        blockedAt(1_500)
        openAfter(1_000)
    }

    @Test fun realHttp500ThenAutoProbeRetriesAfterTwoSecondsDespiteServerDown() {
        digital("a"); digital("b")
        origin.status["/side/a.mp3"] = 500
        assertNotNull(loader.open("a", "A", "x", forAuto = true))
        waitUntil(what = "a failed") { failedIds.contains("a") }
        // The 500 tripped server-down (60 s): a song that never failed stays refused ...
        assertFalse(loader.canStream("b", forAuto = true))
        assertFalse("inside the 2 s cooldown", loader.canStream("a", forAuto = true))
        clockMs.addAndGet(2_500)
        // ... but the failed song may PROBE once its short Auto-DJ cooldown elapsed.
        assertTrue("Auto-DJ re-opens within ~3 s", loader.canStream("a", forAuto = true))
        assertFalse("manual gate unchanged", loader.canStream("a"))
        origin.status.remove("/side/a.mp3")
        val s = loader.open("a", "A", "x", forAuto = true)!!
        waitUntil(what = "complete") { s.isComplete }
        assertTrue("a good response clears server-down", loader.canStream("b"))
    }

    @Test fun staleFailureCountResetsAfterTheWindow() {
        digital("a")
        fun failOnce() { assertNotNull(loader.open("a", "A", "x", forAuto = true)); loader.failStreamForTesting("a") }
        repeat(4) { failOnce(); clockMs.addAndGet(200_000) }   // 4th would be 120 s ...
        clockMs.addAndGet(MixStreamLoader.FAILURE_COUNT_WINDOW_MS)
        failOnce()                                               // ... but the count is stale: back to 1
        clockMs.addAndGet(2_500)
        assertTrue(loader.canStream("a", forAuto = true))
    }

    @Test fun streamableInPrincipleIgnoresTransientGates() {
        digital("a")
        loader.open("a", "A", "x"); loader.failStreamForTesting("a")
        assertFalse(loader.canStream("a"))
        loader.tripServerDownForTesting()
        assertTrue(loader.streamableInPrinciple("a"))
        assertFalse(loader.streamableInPrinciple("ghost"))
        net.available = false
        assertFalse(loader.streamableInPrinciple("a"))
    }

    @Test fun autoCooldownScheduleValues() {
        assertEquals(2_000L, loader.autoFailureCooldownMs(1))
        assertEquals(2_000L, loader.autoFailureCooldownMs(2))
        assertEquals(3_000L, loader.autoFailureCooldownMs(3))
        assertEquals(loader.failureCooldownMs, loader.autoFailureCooldownMs(4))
        assertEquals(loader.failureCooldownMs, loader.autoFailureCooldownMs(0))
    }

    @Test fun liveStreamCanStreamEvenWhileOffline() {
        digital("a"); origin.throttle["/side/a.mp3"] = 500
        val s = loader.open("a", "A", "x")!!
        net.available = false
        assertTrue(loader.canStream("a"))
        assertTrue(loader.isStreaming("a"))
        assertSame(s, loader.open("a", "A", "x")) // joins, no second transfer
        loader.failStreamForTesting("a")
        assertFalse(loader.canStream("a"))
    }

    private fun assertSame(a: Any?, b: Any?) = org.junit.Assert.assertSame(a, b)

    // ---- digital stream: growth, order, adoption -------------------------------------------------

    @Test fun digitalStreamGrowsInOrderThenAdoptsAsReadyBurn() {
        val body = digital("a", 40_000)
        origin.throttle["/side/a.mp3"] = 8_192
        val seen = CopyOnWriteArrayList<Triple<Boolean, Long, Boolean>>() // resolved, bytes, complete
        val s = loader.open("a", "Song A", "Artist")!!
        loader.onProgress = { id -> if (id == "a") seen += Triple(s.resolved, s.bytesReceived, s.isComplete) }
        waitUntil(what = "complete") { s.isComplete }
        waitUntil(what = "last progress") { seen.lastOrNull()?.third == true }
        assertTrue(s.adopted)
        assertTrue(finalizedHas("a"))
        assertEquals(BurnState.READY, burns.items.value.getValue("a").state)
        assertArrayEquals(body, s.finalFile!!.readBytes())
        assertFalse("moved out of the cache", s.file.exists())
        assertNull(s.startMs); assertFalse(s.isCut)
        assertEquals(40_000L, s.expectedBytes)
        // strictly ordered: bytes never go backwards, `complete` only on the LAST event
        assertEquals(seen.map { it.second }, seen.map { it.second }.sorted())
        assertTrue(seen.dropLast(1).none { it.third })
        assertTrue("a frontier that grows", seen.map { it.second }.toSet().size >= 2)
        assertTrue(seen.all { it.first || it.second == 0L })
        // reopening a finished stream whose file is still there returns it as-is
        assertSame(s, loader.open("a", "Song A", "Artist"))
    }

    private fun finalizedHas(id: String): Boolean { waitUntil(what = "onAnyBurnFinalized") { finalized.contains(id) }; return true }

    @Test fun onBytesDeltasSumToTheBody() {
        digital("a", 700_000)
        val sum = AtomicLong()
        loader.onBytes = { _, d -> sum.addAndGet(d) }
        val s = loader.open("a", "A", "x")!!
        waitUntil(what = "complete") { s.isComplete }
        assertEquals(700_000L, sum.get())
    }

    // ---- analog: cut first, side fallback ---------------------------------------------------------

    @Test fun analogCutStreamsFromZeroAndIsNeverAdopted() {
        analog("s1", "alb", 5_000, "cuts/s1.mp3")
        val body = bytesOf(9_000); origin.bodies["/cuts/s1.mp3"] = body
        val s = loader.open("s1", "S1", "x")!!
        waitUntil(what = "complete") { s.isComplete }
        assertTrue(s.isCut); assertNull(s.startMs)
        assertFalse(s.adopted)
        assertEquals(s.file, s.finalFile)
        assertArrayEquals(body, s.file.readBytes())
        assertNull(burns.items.value["s1"])
        assertTrue(finalized.isEmpty())
        assertTrue(origin.ranges("/side/s1.mp3").isEmpty())
    }

    private fun cutFallback(code: Int) {
        val id = "s$code"
        analog(id, "alb$code", 5_000, "cuts/$id.mp3")
        origin.status["/cuts/$id.mp3"] = code
        val side = bytesOf(20_000, code); origin.bodies["/side/$id.mp3"] = side
        val s = loader.open(id, id, "x")!!
        waitUntil(what = "complete after $code") { s.isComplete }
        assertFalse(s.isCut)
        assertEquals(5_000L, s.startMs)
        assertTrue(s.adopted)
        assertArrayEquals(side, s.finalFile!!.readBytes())
        assertEquals(BurnState.READY, burns.items.value.getValue(id).state)
    }

    @Test fun cut403FallsBackToTheSideWithStartMs() = cutFallback(403)
    @Test fun cut404FallsBackToTheSideWithStartMs() = cutFallback(404)

    @Test fun cutAndSideBothUnavailableFails() {
        analog("s1", "alb", 5_000, "cuts/s1.mp3")
        origin.status["/cuts/s1.mp3"] = 404
        presignFails += "s1"
        val s = loader.open("s1", "S1", "x")!!
        waitUntil(what = "failed") { failedIds.contains("s1") }
        assertTrue(s.failed)
        assertFalse(loader.canStream("s1"))
    }

    // ---- Range retry --------------------------------------------------------------------------------

    @Test fun droppedConnectionResumesWithRangeAndCompletes() {
        val body = digital("a", 300_000)
        origin.dropFirst += "/side/a.mp3"
        val s = loader.open("a", "A", "x")!!
        waitUntil(what = "complete") { s.isComplete }
        val r = origin.ranges("/side/a.mp3")
        assertEquals("-", r.first())
        assertTrue("resumed with a Range at the received offset: $r", r[1].startsWith("bytes=") && r[1] != "bytes=0-")
        assertArrayEquals(body, s.finalFile!!.readBytes())
        assertFalse(s.failed)
    }

    @Test fun retriesExhaustedFailsAndTripsServerDown() {
        digital("a", 300_000)
        origin.alwaysDrop += "/side/a.mp3"
        val s = loader.open("a", "A", "x")!!
        waitUntil(what = "failed") { failedIds.contains("a") }
        assertTrue(s.failed)
        assertEquals(1 + loader.maxRetries, origin.ranges("/side/a.mp3").size)
        digital("b")
        assertFalse("server-down cooldown", loader.canStream("b"))
    }

    // ---- makeRoom -------------------------------------------------------------------------------------

    @Test fun fourthConcurrentStreamCancelsTheOldestUnpinned() {
        for (id in listOf("a", "b", "c", "d")) { digital(id, 50_000); origin.throttle["/side/$id.mp3"] = 100 }
        loader.pinnedIds = { setOf("a") }
        assertNotNull(loader.open("a", "A", "x"))
        assertNotNull(loader.open("b", "B", "x"))
        assertNotNull(loader.open("c", "C", "x"))
        assertNotNull(loader.open("d", "D", "x"))
        // "a" is oldest but pinned: "b" (next oldest) is the victim
        assertNotNull(loader.stream("a")); assertNull(loader.stream("b"))
        assertNotNull(loader.stream("c")); assertNotNull(loader.stream("d"))
        waitUntil(what = "evict callback") { failedIds.contains("b") }
        assertEquals(listOf("b"), failedIds.toList())
    }

    @Test fun allPinnedMeansNothingIsCancelled() {
        for (id in listOf("a", "b", "c", "d")) { digital(id); origin.throttle["/side/$id.mp3"] = 100 }
        loader.pinnedIds = { setOf("a", "b", "c") }
        listOf("a", "b", "c", "d").forEach { assertNotNull(loader.open(it, it, "x")) }
        assertEquals(setOf("a", "b", "c", "d"), loader.streams.keys)
        assertTrue(failedIds.isEmpty())
    }

    @Test fun cancelSkipsPinnedSongs() {
        for (id in listOf("a", "b")) { digital(id); origin.throttle["/side/$id.mp3"] = 100; loader.open(id, id, "x") }
        loader.pinnedIds = { setOf("a") }
        loader.cancel(listOf("a", "b"))
        assertNotNull(loader.stream("a")); assertNull(loader.stream("b"))
    }

    @Test fun slowAdoptionDoesNotHoldTheLoaderLock() {
        val body = digital("a", 20_000)
        val gate = java.util.concurrent.CountDownLatch(1)
        val entered = java.util.concurrent.CountDownLatch(1)
        val real = BurnStoreAdopter(burns)
        val slow = object : StreamAdopter {
            override fun adoptFile(songId: String, title: String, artist: String, from: File): File? {
                entered.countDown(); gate.await(10, java.util.concurrent.TimeUnit.SECONDS)
                return real.adoptFile(songId, title, artist, from)
            }
            override fun adoptStems(songId: String, files: Map<String, File>) = real.adoptStems(songId, files)
        }
        val l = MixStreamLoader(rips = fakeRips, adopter = slow, directory = File(rig.dir, "cache/slow"), network = net, scope = scope)
        val s = l.open("a", "A", "x")!!
        assertTrue("adoption started", entered.await(10, java.util.concurrent.TimeUnit.SECONDS))
        // Adoption is parked: every query must still answer immediately (they take the same lock).
        val t0 = System.nanoTime()
        l.canStream("a"); l.stream("a"); l.isStreaming("a"); l.streams; l.open("a", "A", "x")
        assertTrue("queries blocked on adoption", (System.nanoTime() - t0) / 1_000_000 < 1_000)
        assertFalse(s.isComplete)
        gate.countDown()
        waitUntil(what = "complete") { s.isComplete }
        assertTrue(s.adopted)
        assertArrayEquals(body, s.finalFile!!.readBytes())
    }

    // ---- launch sweep ---------------------------------------------------------------------------------

    @Test fun constructionSweepsPartialsFromAPreviousLaunch() {
        val junk = File(cacheDir, "old-partial.mp3").apply { writeBytes(ByteArray(10)) }
        assertTrue(junk.exists())
        MixStreamLoader(rips = fakeRips, adopter = BurnStoreAdopter(burns), directory = cacheDir, scope = scope)
        waitUntil(what = "sweep") { !junk.exists() }
        assertTrue(cacheDir.isDirectory)
    }

    // ---- stems ----------------------------------------------------------------------------------------

    @Test fun stemKeyRoundTrips() {
        val k = MixStreamLoader.stemKey("song:with:colons", "vocals")
        assertEquals("stem:song:with:colons:vocals", k)
        assertEquals("song:with:colons", MixStreamLoader.stemSongId(k))
        assertNull(MixStreamLoader.stemSongId("song:with:colons"))
    }

    @Test fun stemSetCompletesOnlyWhenAllFourPartsDoAndIsAdopted() {
        val parts = stems("a")
        val events = CopyOnWriteArrayList<String>()
        loader.onStemProgress = { events += it }
        val songEvents = CopyOnWriteArrayList<String>()
        loader.onProgress = { songEvents += it }
        origin.throttle["/stems/a/other.mp3"] = 2_000   // the slow part
        val set = loader.openStems("a")!!
        waitUntil(what = "three parts") { set.parts.values.count { it.isComplete } == 3 }
        assertFalse(set.isComplete); assertFalse(set.adopted)
        waitUntil(what = "set") { set.isComplete && set.adopted }
        for ((n, bytes) in parts) assertArrayEquals(bytes, set.parts.getValue(n).finalFile!!.readBytes())
        assertTrue(set.parts.values.all { it.adopted })
        assertTrue(events.isNotEmpty() && events.all { it == "a" })
        assertTrue("part events never reach the song lane", songEvents.isEmpty())
        assertEquals(setOf("vocals", "drums", "bass", "other"), burns.localStemFiles("a")!!.keys)
    }

    @Test fun aFailedPartFailsTheSetAndCoolsItDown() {
        stems("a")
        origin.status["/stems/a/bass.mp3"] = 500
        val notified = CopyOnWriteArrayList<String>()
        loader.onStemProgress = { notified += it }
        val songFailed = CopyOnWriteArrayList<String>(); loader.onFailed = { songFailed += it }
        origin.throttle["/stems/a/vocals.mp3"] = 100
        val set = loader.openStems("a")!!
        waitUntil(what = "set failed") { set.failed }
        assertNull(loader.stemSet("a"))
        assertTrue(notified.contains("a"))
        assertFalse(loader.canStreamStems("a"))
        assertTrue("stem failures never reach the song lane", songFailed.isEmpty())
        // stem failure does NOT trip the song server-down cooldown
        digital("b")
        assertTrue(loader.canStream("b"))
        clockMs.addAndGet(120_001)
        assertTrue(loader.canStreamStems("a"))
    }

    @Test fun cancelStemsWithTwoOwnersOnlyDropsAClaim() {
        stems("a")
        BurnFileNames.STEM_NAMES.forEach { origin.throttle["/stems/a/$it.mp3"] = 100 }
        val set = loader.openStems("a", MixStreamLoader.MIX_STEM_OWNER)!!
        assertSame(set, loader.openStems("a", MixStreamLoader.NOW_PLAYING_STEM_OWNER))
        val files = set.parts.values.map { it.file }
        loader.cancelStems("a", MixStreamLoader.MIX_STEM_OWNER)
        assertSame(set, loader.stemSet("a"))
        assertTrue(files.all { it.exists() })
        loader.cancelStems("a", MixStreamLoader.NOW_PLAYING_STEM_OWNER)
        assertNull(loader.stemSet("a"))
        assertTrue(files.none { it.exists() })
        assertTrue(loader.streams.keys.none { it.startsWith("stem:") })
    }

    @Test fun completedSetSurvivesCancelStems() {
        stems("a")
        val set = loader.openStems("a")!!
        waitUntil(what = "adopted") { set.adopted }
        loader.cancelStems("a")
        assertNotNull(loader.stemSet("a"))
        assertTrue(set.parts.values.all { it.finalFile!!.exists() })
    }

    @Test fun stemListenersFanOutAndCanBeRemoved() {
        stems("a")
        val got = CopyOnWriteArrayList<String>()
        val token = loader.addStemListener { got += it }
        val set = loader.openStems("a", MixStreamLoader.NOW_PLAYING_STEM_OWNER)!!
        waitUntil(what = "adopted") { set.adopted }
        assertTrue(got.isNotEmpty())
        loader.removeStemListener(token)
        val n = got.size
        loader.onStemProgress?.invoke("a")
        assertEquals(n, got.size)
    }

    @Test fun stemsNeedNetworkAndAStemmedManifestEntry() {
        digital("plain")
        assertFalse(loader.canStreamStems("plain"))
        assertNull(loader.openStems("plain"))
        stems("a")
        net.available = false
        assertFalse(loader.canStreamStems("a"))
    }
}

package com.levi.pocketdj.data.recs

import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Fake transport: scripted per call, records every URL and the peak number of requests in flight. */
private class FakeTransport(
    @Volatile override var canSync: Boolean = true,
    private val holdMs: Long = 0,
    private val script: (call: Int, url: String) -> Any, // String body | Throwable
) : ReleaseFeedTransport {
    val urls = ConcurrentLinkedQueue<String>()
    val calls = AtomicInteger(0)
    private val inFlight = AtomicInteger(0)
    @Volatile var peak = 0

    override suspend fun fetch(url: String): String {
        val n = calls.incrementAndGet()
        urls += url
        val now = inFlight.incrementAndGet()
        synchronized(this) { if (now > peak) peak = now }
        try {
            if (holdMs > 0) delay(holdMs)
            when (val r = script(n, url)) {
                is Throwable -> throw r
                else -> return r as String
            }
        } finally {
            inFlight.decrementAndGet()
        }
    }
}

class ReleaseFeedServiceTest {
    private val day = 86_400_000.0
    private val now = 1_800_000_000_000.0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val tmp = kotlin.io.path.createTempDirectory("relfeed").toFile()
    private val file = File(tmp, ReleaseFeedService.FILE_NAME)

    @After fun cleanup() { scope.cancel(); tmp.deleteRecursively() }

    private fun service(t: ReleaseFeedTransport?, f: File? = file) =
        ReleaseFeedService(t, f, scope, timeScale = 0.0, clock = { now }, random = { 0.0 })

    private fun idsOf(url: String): List<Int> =
        url.substringAfter("ids=").substringBefore("&").split(",").map { it.toInt() }

    /** A body answering every requested id with a release 3 days old. */
    private fun answerAll(url: String): String {
        val rows = idsOf(url).joinToString(",") { id ->
            """{"id":"$id","attributes":{"name":"Artist $id"},"views":{"latest-release":{"data":[{"id":"r$id","attributes":{"name":"Rel $id","releaseDate":"2027-01-12","trackCount":3}}]},"similar-artists":{"data":[{"id":"${id + 1}"}]}}}"""
        }
        return """{"data":[$rows]}"""
    }

    /**
     * Wait for the feed to go quiet: a play arms a (zero-debounce) background drain, so an explicit
     * drain() here would race it. Quiet = not fetching, and no new request for two consecutive looks.
     */
    private suspend fun settle(svc: ReleaseFeedService, t: FakeTransport) {
        withTimeout(10_000) {
            var last = -1
            var stable = 0
            while (stable < 3) {
                delay(30)
                val n = t.calls.get()
                if (!svc.isFetchingNow && n == last) stable++ else stable = 0
                last = n
            }
        }
    }

    private suspend fun until(what: String, cond: () -> Boolean) {
        withTimeout(5_000) { while (!cond()) delay(5) }
    }

    // ---- request shape ----------------------------------------------------------------------

    @Test fun requestShapeBatchesOfFiftyWithBothViews() = runBlocking {
        val t = FakeTransport { _, url -> answerAll(url) }
        val svc = service(t)
        svc.seedForTesting((1..120).map { ArtistReleaseEntry(it, "Artist $it", now) })
        svc.recheckKnownArtists() // all 120 queued at once -> one drain, so the batch sizes are deterministic
        settle(svc, t)
        assertEquals(3, t.calls.get())
        val sizes = t.urls.map { idsOf(it).size }.sorted()
        assertEquals(listOf(20, 50, 50), sizes)
        for (u in t.urls) {
            assertTrue(u, u.startsWith("https://api.music.apple.com/v1/catalog/us/artists?ids="))
            assertTrue(u, u.endsWith("&views=latest-release,similar-artists"))
        }
        assertEquals((1..120).toSet(), t.urls.flatMap { idsOf(it) }.toSet())
        assertEquals(120, svc.cachedArtistCount)
    }

    @Test fun requestUrlFormat() {
        assertEquals(
            "https://api.music.apple.com/v1/catalog/us/artists?ids=1,2,3&views=latest-release,similar-artists",
            ReleaseFeedService.requestUrl(listOf(1, 2, 3)),
        )
    }

    // ---- retry policy -----------------------------------------------------------------------

    @Test fun onlyTooManyRequestsAndServerErrorsRetry() = runBlocking {
        for ((err, expectedCalls) in listOf(
            ReleaseFeedTransportError.Http(400) to 1,
            ReleaseFeedTransportError.Http(401) to 1,
            ReleaseFeedTransportError.Http(403) to 1,
            ReleaseFeedTransportError.Http(404) to 1,
            ReleaseFeedTransportError.Unavailable() to 1,
            ReleaseFeedTransportError.Http(429) to 5,
            ReleaseFeedTransportError.Http(503) to 5,
        )) {
            val t = FakeTransport { _, _ -> err }
            val svc = service(t, null)
            svc.noteArtistPlayed(1, "A", now)
            settle(svc, t)
            assertEquals("${err.message}", expectedCalls, t.calls.get())
        }
    }

    @Test fun retriesThenSucceedsAndIoErrorsAreTransient() = runBlocking {
        val t = FakeTransport { n, url ->
            when (n) {
                1 -> ReleaseFeedTransportError.Http(429)
                2 -> IOException("offline")
                3 -> ReleaseFeedTransportError.Http(502)
                else -> answerAll(url)
            }
        }
        val svc = service(t, null)
        svc.noteArtistPlayed(10, "Ten", now)
        settle(svc, t)
        assertEquals(4, t.calls.get())
        assertEquals("Rel 10", svc.entry(10)?.releaseName)
        assertEquals(0, svc.pendingCount)
    }

    @Test fun unparseableBodyFailsWithoutRetry() = runBlocking {
        val t = FakeTransport { _, _ -> """{"errors":[{"status":"500"}]}""" }
        val svc = service(t, null)
        svc.noteArtistPlayed(1, "A", now)
        settle(svc, t)
        assertEquals(1, t.calls.get())
        // No `data` = no good answer: nothing may be stamped, the id goes back on the queue.
        assertNull(svc.entry(1))
        assertEquals(1, svc.pendingCount)
    }

    // ---- failure handling -------------------------------------------------------------------

    @Test fun failedBatchRequeuesStampsNothingAndDoesNotReArm() = runBlocking {
        val t = FakeTransport { _, _ -> ReleaseFeedTransportError.Http(400) }
        val svc = service(t, null)
        for (id in 1..3) svc.noteArtistPlayed(id, "A$id", now)
        until("first drain") { t.calls.get() >= 1 && !svc.isFetchingNow }
        val after = t.calls.get()
        delay(150) // a re-armed drain (debounce is 0 with timeScale 0) would fire again here
        assertEquals("a failed pass must not re-arm itself (it would spin against an outage)", after, t.calls.get())
        assertEquals(0, svc.cachedArtistCount)
        assertEquals(3, svc.pendingCount)
        assertTrue(svc.emptyReason() is ReleaseEmptyReason.Unreachable)
        // The next play rides the queued ids.
        svc.noteArtistPlayed(4, "A4", now)
        until("second drain") { t.calls.get() > after && !svc.isFetchingNow }
        assertEquals(setOf(1, 2, 3, 4), t.urls.last().let { idsOf(it) }.toSet())
    }

    @Test fun successStampsArtistsAppleReturnedNothingFor() = runBlocking {
        val t = FakeTransport { _, url ->
            // Answer only the first id; the rest "have no releases" and are simply absent.
            val first = idsOf(url).first()
            """{"data":[{"id":"$first","attributes":{"name":"Only"},"views":{"latest-release":{"data":[{"id":"x","attributes":{"name":"N","releaseDate":"2027-01-10"}}]}}}]}"""
        }
        val svc = service(t, null)
        svc.noteArtistPlayed(1, "One", now)
        svc.noteArtistPlayed(2, "Two", now)
        settle(svc, t)
        assertEquals(now, svc.entry(2)!!.checkedAtMs, 0.0)
        assertEquals("Two", svc.entry(2)!!.artistName) // fallback name from the queue
        assertNull(svc.entry(2)!!.releaseId)
        assertEquals(0, svc.pendingCount)
        // …so Two is not re-requested on the very next play.
        val before = t.calls.get()
        svc.noteArtistPlayed(2, "Two", now + 1)
        delay(50)
        assertEquals(before, t.calls.get())
    }

    @Test fun sparseAnswerNeverErasesAKnownSimilarList() = runBlocking {
        val t = FakeTransport { _, _ ->
            """{"data":[{"id":"1","attributes":{"name":"A"},"views":{"similar-artists":{"data":[]}}}]}"""
        }
        val svc = service(t, null)
        svc.seedForTesting(listOf(ArtistReleaseEntry(1, "A", 0.0, similarArtistIds = listOf(8, 9), similarCheckedAtMs = 5.0)))
        svc.recheckKnownArtists()
        settle(svc, t)
        assertEquals(listOf(8, 9), svc.entry(1)!!.similarArtistIds)
        assertEquals(5.0, svc.entry(1)!!.similarCheckedAtMs!!, 0.0)
        assertEquals(now, svc.entry(1)!!.checkedAtMs, 0.0)
    }

    // ---- concurrency ------------------------------------------------------------------------

    @Test fun concurrencyIsTwoOnACleanPass() = runBlocking {
        val t = FakeTransport(holdMs = 25) { _, url -> answerAll(url) }
        val svc = service(t, null)
        svc.seedForTesting((1..450).map { ArtistReleaseEntry(it, "A$it", now) })
        svc.recheckKnownArtists() // all 450 queued at once, one debounced drain
        until("drained") { t.calls.get() == 9 && !svc.isFetchingNow }
        assertEquals(9, t.calls.get())
        assertEquals(2, t.peak)
    }

    @Test fun drainReentrancyGuardKeepsTwoInFlightUnderA429StormWithPlaysArriving() = runBlocking {
        val t = FakeTransport(holdMs = 8) { _, _ -> ReleaseFeedTransportError.Http(429) }
        val svc = service(t, null)
        for (id in 1..120) svc.noteArtistPlayed(id, "A$id", now) // 3 batches, each retrying 5x
        val storm = scope.launch {
            // Plays keep landing while the drain is sleeping through its backoff: each one used to arm a
            // second drain beside the first (measured 12 in flight on the unguarded code).
            for (i in 1000..1400) {
                svc.noteArtistPlayed(i, "P$i", now)
                if (i % 7 == 0) delay(1)
            }
        }
        until("storm drains") { storm.isCompleted && t.calls.get() > 0 }
        delay(300)
        until("quiescent") { !svc.isFetchingNow }
        assertTrue("peak in flight was ${t.peak}", t.peak <= ReleaseFeedPolicy.MAX_CONCURRENT_REQUESTS)
        assertTrue(t.calls.get() >= 5)
        // Nothing was lost: every id is still queued for the next play.
        assertTrue(svc.pendingCount >= 120)
        assertEquals(0, svc.cachedArtistCount)
    }

    // ---- lazy trigger -----------------------------------------------------------------------

    @Test fun playGatesOnCanSyncAndTtl() = runBlocking {
        val t = FakeTransport(canSync = false) { _, url -> answerAll(url) }
        val svc = service(t, null)
        svc.noteArtistPlayed(1, "A", now)
        delay(60)
        assertEquals("unauthorised: nothing queued, nothing fetched", 0, t.calls.get())
        assertEquals(0, svc.pendingCount)

        t.canSync = true
        svc.noteArtistPlayed(1, "A", now)
        until("fetched") { t.calls.get() == 1 && !svc.isFetchingNow }
        // Fresh entry (checked "now"): a second play inside the TTL queues nothing.
        svc.noteArtistPlayed(1, "A", now + 1 * day)
        delay(60)
        assertEquals(1, t.calls.get())
        // Past the (cold, 14 d) TTL it is due again.
        svc.noteArtistPlayed(1, "A", now + 15 * day)
        until("refetched") { t.calls.get() == 2 && !svc.isFetchingNow }
    }

    @Test fun heavyArtistIsDueSoonerThanAColdOne() = runBlocking {
        val t = FakeTransport { _, url -> answerAll(url) }
        val svc = service(t, null)
        svc.playsForArtist = { id -> if (id == 1) 2860 else 0 }
        svc.noteArtistPlayed(1, "Heavy", now)
        svc.noteArtistPlayed(2, "Cold", now)
        settle(svc, t)
        val before = t.calls.get()
        svc.noteArtistPlayed(1, "Heavy", now + 3 * day)
        svc.noteArtistPlayed(2, "Cold", now + 3 * day)
        until("heavy refetch") { t.calls.get() > before && !svc.isFetchingNow }
        assertEquals(listOf(1), idsOf(t.urls.last()))
    }

    @Test fun recheckRequeuesEveryCachedArtistIgnoringTtl() = runBlocking {
        val t = FakeTransport { _, url -> answerAll(url) }
        val svc = service(t, null)
        assertFalse("empty cache: nothing to re-ask", svc.canRecheck)
        svc.seedForTesting((1..3).map { ArtistReleaseEntry(it, "A$it", now) }) // all perfectly fresh
        assertTrue(svc.canRecheck)
        svc.recheckKnownArtists()
        until("recheck drained") { t.calls.get() == 1 && !svc.isFetchingNow }
        assertEquals(setOf(1, 2, 3), idsOf(t.urls.first()).toSet())
        assertEquals("Rel 2", svc.entry(2)?.releaseName)
    }

    @Test fun recheckIsDisabledWhenAppleMusicIsOff() {
        val svc = service(FakeTransport(canSync = false) { _, _ -> "" }, null)
        svc.seedForTesting(listOf(ArtistReleaseEntry(1, "A", now)))
        assertFalse(svc.canRecheck)
        svc.recheckKnownArtists()
        assertEquals(0, svc.pendingCount)
    }

    // ---- the one-shot seed ------------------------------------------------------------------

    @Test fun seedRunsOnceAndIsPersistedBeforeTheFetch() = runBlocking {
        val t = FakeTransport(holdMs = 20) { _, url -> answerAll(url) }
        val svc = service(t)
        assertTrue(svc.needsSeed)
        assertTrue(svc.seedFromRecentListening(listOf(1 to "A", 2 to "B"), now))
        assertEquals(ReleaseEmptyReason.Checking, svc.emptyReason())
        // Stamped + on disk already, while the fetch is still in flight.
        assertEquals(now, ReleaseFeedDocumentCodec.decode(file.readText())!!.seededAtMs!!, 0.0)
        assertFalse("never twice", svc.seedFromRecentListening(listOf(3 to "C"), now))
        until("seed drained") { svc.cachedArtistCount == 2 && !svc.isFetchingNow }
        until("seeding flag cleared") { svc.emptyReason() != ReleaseEmptyReason.Checking }
        assertEquals(1, t.calls.get())
        assertEquals(setOf(1, 2), idsOf(t.urls.first()).toSet())
        // A relaunch must not re-seed even if the cache were empty.
        val relaunched = service(t)
        assertEquals(now, relaunched.seededAt!!, 0.0)
        assertFalse(relaunched.needsSeed)
    }

    @Test fun failedSeedStaysSeededAndRidesTheRetryPath() = runBlocking {
        val t = FakeTransport { _, _ -> ReleaseFeedTransportError.Http(401) }
        val svc = service(t)
        assertTrue(svc.seedFromRecentListening(listOf(1 to "A"), now))
        until("seed attempt") { t.calls.get() == 1 && !svc.isFetchingNow && svc.emptyReason() != ReleaseEmptyReason.Checking }
        assertFalse("a failed seed does not re-seed", svc.seedFromRecentListening(listOf(1 to "A"), now))
        assertEquals(1, svc.pendingCount) // queued for the next play
        assertTrue(svc.emptyReason() is ReleaseEmptyReason.Unreachable)
    }

    @Test fun seedIsNotStampedWhileUnauthorised() {
        val t = FakeTransport(canSync = false) { _, url -> answerAll(url) }
        val svc = service(t)
        assertFalse(svc.seedFromRecentListening(listOf(1 to "A"), now))
        assertNull("free to seed the moment Apple Music is turned on", svc.seededAt)
        assertTrue(svc.needsSeed)
        t.canSync = true
        assertTrue(svc.seedFromRecentListening(listOf(1 to "A"), now))
    }

    @Test fun seedDoesNotRequeueArtistsAlreadyCachedAndNeedsEmptyCache() {
        val svc = service(FakeTransport { _, url -> answerAll(url) }, null)
        svc.seedForTesting(listOf(ArtistReleaseEntry(1, "A", now)))
        assertFalse("a populated cache never seeds", svc.seedFromRecentListening(listOf(2 to "B"), now))
    }

    // ---- emptyReason ------------------------------------------------------------------------

    @Test fun emptyReasonDistinguishesTheFiveStates() = runBlocking {
        val off = service(FakeTransport(canSync = false) { _, _ -> "" }, null)
        assertEquals(ReleaseEmptyReason.NotAuthorized, off.emptyReason())
        assertEquals(ReleaseEmptyReason.NotAuthorized, service(null, null).emptyReason())

        val ok = FakeTransport { _, url -> answerAll(url) }
        val svc = service(ok, null)
        assertEquals(ReleaseEmptyReason.NotCheckedYet, svc.emptyReason())
        svc.noteArtistPlayed(1, "A", now)
        until("fetched") { ok.calls.get() == 1 && !svc.isFetchingNow }
        // checked, and the one release (2027-01-12) is far outside the window relative to... the clock `now`
        svc.seedForTesting(listOf(ArtistReleaseEntry(1, "A", now, releaseId = "r", releaseAtMs = now - 90 * day)))
        assertEquals(ReleaseEmptyReason.NothingNew, svc.emptyReason())
        assertTrue(svc.feed(now).isEmpty())

        val bad = FakeTransport { _, _ -> ReleaseFeedTransportError.Http(400) }
        val failing = service(bad, null)
        failing.noteArtistPlayed(1, "A", now)
        until("failed") { bad.calls.get() == 1 && !failing.isFetchingNow }
        val r = failing.emptyReason()
        assertTrue(r is ReleaseEmptyReason.Unreachable)
        assertEquals("Couldn’t reach Apple Music", r.tileNote)
    }

    // ---- reading + ownership ----------------------------------------------------------------

    private fun entry(id: Int, release: String?, at: Double?, name: String = "Rel $id") =
        ArtistReleaseEntry(id, "Artist $id", now, release, name, at)

    @Test fun feedClassifiesSortsAndDropsUnopenableRows() {
        val svc = service(null, null)
        svc.seedForTesting(
            listOf(
                entry(1, "r1", now - 10 * day),
                entry(2, "r2", now - 1 * day),
                entry(3, "r3", now + 20 * day),
                entry(4, "r4", now + 5 * day),
                entry(5, "r5", now - 45 * day), // outside the window
                entry(6, null, now - 1 * day), // no store id: cannot be opened or matched
                entry(7, "r7", null), // no usable date
            ),
        )
        assertEquals("newest release date first, pre-orders included", listOf(3, 4, 2, 1), svc.feed(now).map { it.id })
        assertEquals(listOf(2, 1), svc.outNow(now).map { it.id })
        assertEquals("soonest first", listOf(4, 3), svc.comingSoon(now).map { it.id })
        assertEquals(4, svc.newReleases(now).size)
        // Read-time aging: the same cache a week later has promoted the pre-order.
        assertEquals(listOf(4), svc.outNow(now + 6 * day).map { it.id }.filter { it == 4 })
    }

    @Test fun ownershipAndVersionProbesSuppressOnRead() {
        val svc = service(null, null)
        svc.seedForTesting(listOf(entry(1, "r1", now - day), entry(2, "r2", now - day, "Deluxe Thing"), entry(3, "r3", now - day)))
        assertEquals(3, svc.feed(now).size) // unset probes = nothing owned
        val seen = ArrayList<ReleaseIdentity>()
        svc.ownsRelease = { id -> seen += id; id.storeId == "r1" }
        svc.ownsReleaseVersion = { artistId, _, title -> artistId == 2 && title == "Deluxe Thing" }
        assertEquals(listOf(3), svc.feed(now).map { it.id })
        // The probe gets EVERY identity the release carries.
        val id3 = seen.last { it.storeId == "r3" }
        assertEquals(ReleaseIdentity("r3", 3, "Artist 3", "Rel 3"), id3)
        // Newly owned: drops out on the next read with no refetch.
        svc.ownsRelease = { true }
        assertTrue(svc.feed(now).isEmpty())
    }

    @Test fun similarArtistIdsReadOnlyTheCache() {
        val svc = service(null, null)
        svc.seedForTesting(
            listOf(
                ArtistReleaseEntry(1, "A", now, similarArtistIds = listOf(5, 6, 1)),
                ArtistReleaseEntry(2, "B", now, similarArtistIds = listOf(6, 7)),
            ),
        )
        assertEquals(listOf(5, 6, 7), svc.similarArtistIds(listOf(1, 2, 99)))
    }

    // ---- durability -------------------------------------------------------------------------

    @Test fun cachePersistsAcrossRelaunchAndCorruptFileIsHarmless() = runBlocking {
        val t = FakeTransport { _, url -> answerAll(url) }
        val svc = service(t)
        svc.noteArtistPlayed(42, "Persist", now)
        until("fetched") { t.calls.get() == 1 && !svc.isFetchingNow }
        val back = service(null)
        assertEquals("Rel 42", back.entry(42)?.releaseName)
        assertNotNull(back.entry(42)?.similarArtistIds)
        file.writeText("{{{ not json")
        assertEquals(0, service(null).cachedArtistCount)
    }

    @Test fun uiFixtureHasTwoOutNowAndOnePreorder() {
        val rows = ReleaseFeedService.uiFixtureEntries(now)
        val svc = service(null, null)
        svc.seedForTesting(rows)
        assertEquals(2, svc.outNow(now).size)
        assertEquals(1, svc.comingSoon(now).size)
    }
}

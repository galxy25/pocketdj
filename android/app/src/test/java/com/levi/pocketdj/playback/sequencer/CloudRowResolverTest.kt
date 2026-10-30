package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.rips.RipJob
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.session.RipOnDemandResolver
import com.levi.pocketdj.playback.session.RipOnDemandSession
import com.levi.pocketdj.playback.session.RipResolution
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class CloudRowResolverTest {
    private val manifest = mutableMapOf<String, RipManifestEntry>()

    private fun registry(configured: Boolean = true) = RowResolverRegistry(
        initial = listOf(ManifestRowResolver { manifest[it] }, CloudRowResolver()),
        manifestHit = { manifest.containsKey(it) },
        ripServerConfigured = { configured },
    )

    // ---- the ladder rung ------------------------------------------------------------------------

    @Test
    fun noManifestRip_withAServer_isRipOnDemand_atTheRipOnDemandRung() = runTest {
        val src = registry().resolve(QueueItem(id = "sng_new"), PlaybackMode.CLOUD)
        assertEquals(RipOnDemandSource("sng_new"), src)
        assertEquals("rip", src.backend)
        assertEquals(Rung.RIP_ON_DEMAND, CloudRowResolver().rung)
    }

    @Test
    fun theVariantResolveId_isWhatGetsRipped() = runTest {
        val src = registry().resolve(QueueItem(id = "sng_a", resolveId = "sng_a_clean"), PlaybackMode.CLOUD)
        assertEquals(RipOnDemandSource("sng_a_clean"), src)
    }

    @Test
    fun aManifestHit_wins_andStreams() = runTest {
        manifest["sng_x"] = RipManifestEntry(key = "sng_x.mp3")
        assertTrue(registry().resolve(QueueItem(id = "sng_x"), PlaybackMode.CLOUD) is StreamSource)
    }

    @Test
    fun noServer_isMetadataOnly_andDeviceModeNeverRips() = runTest {
        val none = registry(configured = false).resolve(QueueItem(id = "sng_new"), PlaybackMode.CLOUD)
        assertEquals(UnplayableSource.Reason.METADATA_ONLY, (none as UnplayableSource).reason)
        val device = registry().resolve(QueueItem(id = "sng_new"), PlaybackMode.DEVICE)
        assertEquals(UnplayableSource.Reason.NOT_ON_DEVICE, (device as UnplayableSource).reason)
    }

    @Test
    fun studioIds_areNeverSentToRip() = runTest {
        for (id in listOf("smp_1", "lp_2", "ptn_3", "tk_4")) {
            val src = registry().resolve(QueueItem(id = id), PlaybackMode.CLOUD)
            assertTrue("$id", src is UnplayableSource)
        }
        assertNull(CloudRowResolver().resolve(QueueItem(id = "smp_1"), ResolveContext(PlaybackMode.CLOUD, true, false)))
    }

    // ---- pdj-resolve uri ---------------------------------------------------------------------------

    @Test
    fun uri_roundTrips_includingAwkwardIds() {
        for (id in listOf("sng_abc", "am 123/x", "sng_é_clean", "a+b")) {
            val uri = RipOnDemandSource.uriFor(id)
            assertTrue(uri, uri.startsWith("pdj-resolve://song/"))
            assertFalse(uri.removePrefix("pdj-resolve://song/").contains("/"))
            assertEquals(id, RipOnDemandSource.songIdFrom(uri))
        }
        assertNull(RipOnDemandSource.songIdFrom("https://rips/x.mp3"))
        assertNull(RipOnDemandSource.songIdFrom("pdj-resolve://song/"))
    }

    // ---- the POST /rip orchestration ------------------------------------------------------------------

    private fun resolver(
        job: RipJob,
        durable: String = "https://rips/x.mp3",
        queued: MutableList<String> = mutableListOf(),
        log: MutableList<String> = mutableListOf(),
        awaited: MutableList<RipJob> = mutableListOf(),
    ) = RipOnDemandResolver(
        requestRip = { job },
        awaitDurable = { j, _ -> awaited += j; durable },
        liveUrl = { "http://srv$it?token=t" },
        onQueued = { queued += it },
        log = { log += it },
    )

    @Test
    fun durableUrl_isSigned_whenThePresignerMintsOne_bothReadyAndAwaited() = runTest {
        val signedFor = mutableListOf<String>()
        fun signing(job: RipJob) = RipOnDemandResolver(
            requestRip = { job },
            awaitDurable = { _, _ -> "https://rips/done.mp3" },
            liveUrl = { it },
            signDurable = { id, _ -> signedFor += id; "https://rips/$id.mp3?X-Amz-Signature=s" },
        )
        assertEquals(
            RipResolution.Durable("https://rips/sng_a.mp3?X-Amz-Signature=s"),
            signing(RipJob(phase = "ready", url = "https://rips/ready.mp3")).resolve("sng_a"),
        )
        assertEquals(
            RipResolution.Durable("https://rips/sng_b.mp3?X-Amz-Signature=s"),
            signing(RipJob(phase = "queued", jobId = "j")).resolve("sng_b"),
        )
        assertEquals(listOf("sng_a", "sng_b"), signedFor)
    }

    @Test
    fun durableUrl_fallsBackToTheJobUrl_whenSigningIsUnavailableOrFails() = runTest {
        val none = RipOnDemandResolver(
            requestRip = { RipJob(phase = "ready", url = "https://rips/ready.mp3") },
            awaitDurable = { _, _ -> "u" }, liveUrl = { it }, signDurable = { _, _ -> null },
        )
        assertEquals(RipResolution.Durable("https://rips/ready.mp3"), none.resolve("sng_a"))
        val boom = RipOnDemandResolver(
            requestRip = { RipJob(phase = "ready", url = "https://rips/ready.mp3") },
            awaitDurable = { _, _ -> "u" }, liveUrl = { it }, signDurable = { _, _ -> throw IOException("presign 500") },
        )
        assertEquals(RipResolution.Durable("https://rips/ready.mp3"), boom.resolve("sng_a"))
    }

    @Test
    fun alreadyReady_isDurable_withoutQueueingOrPolling() = runTest {
        val queued = mutableListOf<String>()
        val awaited = mutableListOf<RipJob>()
        val r = resolver(RipJob(phase = "ready", url = "https://rips/ready.mp3"), queued = queued, awaited = awaited).resolve("sng_a")
        assertEquals(RipResolution.Durable("https://rips/ready.mp3"), r)
        assertTrue(queued.isEmpty())
        assertTrue(awaited.isEmpty())
    }

    @Test
    fun liveStream_wins_overWaitingForTheMp3_andIsTrackedForTheRipWindow() = runTest {
        val queued = mutableListOf<String>()
        val awaited = mutableListOf<RipJob>()
        val r = resolver(
            RipJob(phase = "ripping", jobId = "j1", streamUrl = "/hls/sng_a/index.m3u8"),
            queued = queued, awaited = awaited,
        ).resolve("sng_a")
        assertEquals(RipResolution.Live("http://srv/hls/sng_a/index.m3u8?token=t", "j1"), r)
        assertEquals(listOf("sng_a"), queued)
        assertTrue("a live result does not poll", awaited.isEmpty())
    }

    @Test
    fun queuedWithoutLive_awaitsTheDurableMp3() = runTest {
        val queued = mutableListOf<String>()
        val awaited = mutableListOf<RipJob>()
        val job = RipJob(phase = "queued", jobId = "j2")
        val r = resolver(job, durable = "https://rips/done.mp3", queued = queued, awaited = awaited).resolve("sng_b")
        assertEquals(RipResolution.Durable("https://rips/done.mp3"), r)
        assertEquals(listOf("sng_b"), queued)
        assertEquals(listOf(job), awaited)
    }

    @Test
    fun errorPhase_andNoJob_failTheRow() = runTest {
        for (job in listOf(RipJob(phase = "error", error = "no such song"), RipJob(phase = "queued"))) {
            try {
                resolver(job).resolve("sng_c")
                fail("expected IOException for $job")
            } catch (e: IOException) {
                assertTrue(e.message!!.isNotBlank())
            }
        }
    }

    @Test
    fun logsTheRipreqGrammar() = runTest {
        val log = mutableListOf<String>()
        resolver(RipJob(phase = "queued", jobId = "j", streamUrl = "/hls/x/index.m3u8"), log = log).resolve("sng_d")
        assertEquals(listOf("rip-post begin song=sng_d", "rip-post end song=sng_d phase=queued live=1"), log)
    }

    // ---- one in-flight resolution per song, cancelled on skip -------------------------------------------

    @Test
    fun session_sharesOneResolutionPerSong_betweenWatcherAndDataSource() = runTest {
        var posts = 0
        val gate = CompletableDeferred<RipJob>()
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(
                requestRip = { posts++; gate.await() },
                awaitDurable = { _, _ -> "u" },
                liveUrl = { it },
            ),
        )
        val a = session.begin("sng_a")
        val b = session.begin("sng_a")
        runCurrent()
        assertEquals(1, posts)
        assertTrue(a === b)
        gate.complete(RipJob(phase = "ready", url = "https://rips/a.mp3"))
        runCurrent()
        assertEquals(RipResolution.Durable("https://rips/a.mp3"), a.await())
    }

    @Test
    fun session_loaderThreadOnlyJoins_neverStartsOrCancelsOthers() = runTest {
        var posts = 0
        val gate = CompletableDeferred<RipJob>()
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(requestRip = { posts++; gate.await() }, awaitDurable = { _, _ -> "u" }, liveUrl = { it }),
        )
        val b = session.begin("sng_b")
        runCurrent()
        assertNull("a stale loader for a skipped row finds nothing to join", session.join("sng_a"))
        try { session.blockingDurable("sng_a"); fail() } catch (_: IOException) {}
        assertEquals(1, posts)
        assertTrue("the current row's resolution survives", b.isActive)
        assertTrue(session.join("sng_b") === b)
        assertTrue(session.isResolving())
    }

    @Test
    fun session_failedResolution_retryReportsTheRealCause() = runTest {
        val session = RipOnDemandSession(
            kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.test.StandardTestDispatcher(testScheduler)),
            RipOnDemandResolver(requestRip = { throw IOException("connection refused") }, awaitDurable = { _, _ -> "u" }, liveUrl = { it }),
        )
        session.begin("sng_a")
        runCurrent()
        // Media3 retries the load after the first failure: the retry must not say "not in flight".
        try { session.blockingDurable("sng_a"); fail() } catch (e: IOException) {
            assertTrue(e.message!!, e.message!!.contains("connection refused"))
        }
    }

    @Test
    fun session_beginningAnotherSong_cancelsTheSkippedOne() = runTest {
        val gate = CompletableDeferred<RipJob>()
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(requestRip = { gate.await() }, awaitDurable = { _, _ -> "u" }, liveUrl = { it }),
        )
        val skipped = session.begin("sng_a")
        runCurrent()
        session.begin("sng_b")
        runCurrent()
        assertTrue("the skipped row's wait is cancelled", skipped.isCancelled)
    }

    @Test
    fun session_cancelAll_andAFailedResolutionIsRetryable() = runTest {
        var fail = true
        // A failed resolution must not take the test's background scope down with it (prod: appScope is supervised).
        val session = RipOnDemandSession(
            kotlinx.coroutines.CoroutineScope(
                kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.test.StandardTestDispatcher(testScheduler),
            ),
            RipOnDemandResolver(
                requestRip = { if (fail) throw IOException("down") else RipJob(phase = "ready", url = "https://rips/a.mp3") },
                awaitDurable = { _, _ -> "u" },
                liveUrl = { it },
            ),
        )
        val first = session.begin("sng_a")
        runCurrent()
        assertTrue(first.isCancelled || first.isCompleted)
        fail = false
        val second = session.begin("sng_a") // the failure was forgotten: a retry-in-place re-POSTs
        runCurrent()
        assertEquals(RipResolution.Durable("https://rips/a.mp3"), second.await())
        session.cancel()
        val third = session.begin("sng_a")
        runCurrent()
        assertFalse("cancel() dropped the finished entry", third === second)
    }

    // ---- ANS-PB-5: Q17 cap, Q21 one POST per row ---------------------------------------------------------

    @Test
    fun cap_fromItemLength_thenCatalog_thenTenMinutes_plusSlack() {
        assertEquals(215_000L + 60_000L, com.levi.pocketdj.playback.session.RipWaitCap.capMs(215_000, 999_000))
        assertEquals(180_000L + 60_000L, com.levi.pocketdj.playback.session.RipWaitCap.capMs(null, 180_000))
        assertEquals(180_000L + 60_000L, com.levi.pocketdj.playback.session.RipWaitCap.capMs(0, 180_000))
        assertEquals(600_000L + 60_000L, com.levi.pocketdj.playback.session.RipWaitCap.capMs(null, null))
    }

    @Test
    fun cap_reachesAwaitDurable() = runTest {
        var seen = -1L
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(
                requestRip = { RipJob(phase = "queued", jobId = "j") },
                awaitDurable = { _, cap -> seen = cap; "https://rips/x.mp3" },
                liveUrl = { it },
            ),
            log = { },
        )
        session.begin("sng_a", capMs = 275_000)
        runCurrent()
        assertEquals(275_000L, seen)
    }

    @Test
    fun twoLoadsSameRow_onePost() = runTest {
        var posts = 0
        val gate = CompletableDeferred<RipJob>()
        val trace = mutableListOf<String>()
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(requestRip = { posts++; gate.await() }, awaitDurable = { _, _ -> "u" }, liveUrl = { it }),
            log = { trace += it },
        )
        val load = session.begin("sng_a", via = "load", gen = 7)
        val again = session.begin("sng_a", via = "load", gen = 7) // a second load of the same row while in flight
        runCurrent()
        assertTrue(load === again)
        assertEquals(1, posts)
        assertEquals(2, trace.size)
        assertTrue(trace[0], trace[0].contains("via=load gen=7 joined=0"))
        assertTrue(trace[1], trace[1].contains("joined=1"))
    }

    @Test
    fun retryInPlace_rePosts() = runTest {
        var posts = 0
        val gate = CompletableDeferred<RipJob>()
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(requestRip = { posts++; gate.await() }, awaitDurable = { _, _ -> "u" }, liveUrl = { it }),
            log = { },
        )
        val first = session.begin("sng_a", via = "load", gen = 1)
        runCurrent()
        val retry = session.begin("sng_a", via = "retry", gen = 2, reResolve = true)
        runCurrent()
        assertEquals(2, posts)
        assertTrue(first.isCancelled)
        assertFalse(first === retry)
    }

    @Test
    fun completedDurable_isJoinedByAFreshPlay_butReResolveRePosts() = runTest {
        var posts = 0
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(
                requestRip = { posts++; RipJob(phase = "ready", url = "https://rips/a.mp3") },
                awaitDurable = { _, _ -> "u" }, liveUrl = { it },
            ),
            log = { },
        )
        val first = session.begin("sng_a").also { runCurrent(); it.await() }
        // ⏮ restart / cascade-halt restart of a row whose durable url is known: no second POST.
        assertTrue(session.begin("sng_a") === first)
        runCurrent()
        assertEquals(1, posts)
        // Retry-in-place wants a fresh url: re-POSTs.
        session.begin("sng_a", reResolve = true)
        runCurrent()
        assertEquals(2, posts)
    }

    @Test
    fun completedLive_isNotJoinedByAFreshPlay() = runTest {
        var posts = 0
        val session = RipOnDemandSession(
            backgroundScope,
            RipOnDemandResolver(
                requestRip = { posts++; RipJob(phase = "ripping", jobId = "j", streamUrl = "/hls/a/index.m3u8") },
                awaitDurable = { _, _ -> "u" }, liveUrl = { it },
            ),
            log = { },
        )
        session.begin("sng_a").also { runCurrent(); it.await() }
        session.begin("sng_a")
        runCurrent()
        assertEquals(2, posts)
    }
}

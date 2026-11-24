package com.levi.pocketdj.mix.download

import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of iOS `CollectionMixDownloaderTests` for the 1bad0e9d / dd1f190c crate-stall fixes. */
@OptIn(ExperimentalCoroutinesApi::class)
class CollectionMixDownloaderLaneTest {

    private class FakeBurns : MixDownloadBurns {
        val disk = LinkedHashSet<String>()
        val burned = ArrayList<String>()
        val statuses = HashMap<String, MixBurnStatus>()
        var lands: (String) -> Boolean = { true }
        var finalized: ((String) -> Unit)? = null
        override fun isOnDisk(songId: String) = songId in disk
        override val userBurnActive get() = false
        override suspend fun burn(songId: String, title: String, artist: String) {
            burned += songId
            if (lands(songId)) { disk += songId; statuses[songId] = MixBurnStatus(BurnState.READY, null, 1_000_000L) }
            else statuses[songId] = MixBurnStatus(BurnState.ERROR, "presign 401", 0)
        }
        override fun status(songId: String) = statuses[songId]
        override fun requestStop() {}
        override fun cancelTransfers(songIds: Collection<String>) {}
        override fun watchFinalized(cb: ((String) -> Unit)?) { finalized = cb }
        override fun watchBytes(cb: ((String, Long) -> Unit)?) {}
    }

    private class FakeRips : MixDownloadRips {
        val ripped = HashSet<String>()
        /** Every rip request, with the virtual time it was made. */
        val requests = ArrayList<Pair<Long, List<String>>>()
        var clock: () -> Long = { 0 }
        var outcome: () -> RipBatchOutcome = { RipBatchOutcome() }
        var throwOnRequest = false
        override var hasServer = true
        override var isAuthRejected = false
        override var authHoldoff = false
        override fun isRipped(songId: String) = songId in ripped
        override fun durationMs(songId: String): Long? = null
        override val manifestCount get() = ripped.size
        override suspend fun ripCollection(songIds: List<String>) {}
        override suspend fun requestRips(songIds: List<String>): RipBatchOutcome {
            requests += clock() to songIds
            if (throwOnRequest) throw java.io.IOException("boom")
            return outcome()
        }
        override suspend fun cancelCollection(songIds: List<String>) {}
        override suspend fun refreshManifest() {}
    }

    private class FakeHost : AutoMixHost {
        override var autoMixing = false
        override var autoEndedExhausted = false
        override var isRunning = false
        override var deckGestureGeneration = 0
        override var autoSourceLabel: String? = null
        override var autoUpcomingSongIds: List<String> = emptyList()
        val streaming = HashSet<String>()
        val inserts = ArrayList<AutoMixItem>()
        val starts = ArrayList<List<AutoMixItem>>()
        override fun autoQueueInsert(item: AutoMixItem, placement: AutoPlacement) { inserts += item }
        override fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?) { starts += items }
        override fun isStreaming(songId: String) = songId in streaming
        override fun cancelStreams(songIds: List<String>) {}
        override fun setStreamHooks(onBytes: ((String, Long) -> Unit)?, onFailed: ((String) -> Unit)?) {}
    }

    private class Rig(scope: TestScope) {
        val burns = FakeBurns()
        val rips = FakeRips().also { it.clock = { scope.currentTime } }
        val host = FakeHost()
        val members = HashMap<MixSource, List<String>>()
        val d = CollectionMixDownloader(CoroutineScope(UnconfinedTestDispatcher(scope.testScheduler)), burns, rips, host)
        init {
            d.resolveRipIds = { members[it].orEmpty() }
            d.resolveLoadables = { src ->
                members[src].orEmpty().filter { it in burns.disk || it in rips.ripped }
                    .map { MixLoadable(songId = it, title = "T$it", artist = "A$it", lengthMs = 200_000) }
            }
            d.resolveSourceName = { "crate:${it.id}" }
        }
    }

    private val crate = MixSource.Playlist("c")
    private val other = MixSource.Playlist("o")
    private val tick = 4500L

    private fun TestScope.rig(ids: List<String>, ripped: Set<String> = emptySet(), onDisk: Set<String> = emptySet()) =
        Rig(this).also { it.members[crate] = ids; it.rips.ripped += ripped; it.burns.disk += onDisk }

    // ---- pure copy + backoff ---------------------------------------------------------------------

    @Test fun refusalClassifiesAuthVersusServerFaults() {
        assertEquals(LaneIssue.TokenRejected, LaneIssue.ofRefusal(401))
        assertEquals(LaneIssue.TokenRejected, LaneIssue.ofRefusal(403))
        assertEquals(LaneIssue.RipServerRefused(502), LaneIssue.ofRefusal(502))
        assertEquals(LaneIssue.RipServerRefused(LaneIssue.TRANSPORT_FAILURE), LaneIssue.ofRefusal(-1))
        assertTrue(RipBatchOutcome(401).unauthorized)
        assertFalse(RipBatchOutcome(500).unauthorized)
        assertFalse(RipBatchOutcome().refused)
    }

    @Test fun rippingLabelIsHonestForEveryIssue() {
        assertEquals("· 4 ripping", LaneIssue.rippingLabel(4, null))
        assertNull(LaneIssue.rippingLabel(0, null))
        assertEquals("· 4 can’t rip — import server rejected this device’s token", LaneIssue.rippingLabel(4, LaneIssue.TokenRejected))
        assertEquals("· import server rejected this device’s token", LaneIssue.rippingLabel(0, LaneIssue.TokenRejected))
        assertNull(LaneIssue.rippingLabel(0, LaneIssue.NoServer))
        assertEquals("· 4 need an import server to rip", LaneIssue.rippingLabel(4, LaneIssue.NoServer))
        assertEquals("· 4 waiting — import server error 503, retrying", LaneIssue.rippingLabel(4, LaneIssue.RipServerRefused(503)))
        assertEquals("· 4 waiting — can’t reach the import server, retrying", LaneIssue.rippingLabel(4, LaneIssue.RipServerRefused(-1)))
        assertEquals("· 4 ripping (stalled — re-requested)", LaneIssue.rippingLabel(4, LaneIssue.RipsStalled))
        assertEquals("Only 404 of 418 songs available on this device — catalog still loading", LaneIssue.shortfallCaption(418, 404, true))
        assertEquals(
            "14 of 418 crate songs aren’t in this device’s catalog — a source may be missing or disabled",
            LaneIssue.shortfallCaption(418, 404, false),
        )
        assertTrue(LaneIssue.TokenRejected.offersNowPlayingFallback)
        assertTrue(LaneIssue.NoServer.offersNowPlayingFallback)
        assertFalse(LaneIssue.RipsStalled.offersNowPlayingFallback)
        assertFalse(LaneIssue.RipServerRefused(500).offersNowPlayingFallback)
    }

    @Test fun retryBackoffDoublesAndCaps() {
        val seq = (1..9).map { LaneIssue.ripRetryDelayTicks(it, base = 2, cap = 67) }
        assertEquals(listOf(2, 4, 8, 16, 32, 64, 67, 67, 67), seq)
        assertEquals(2, LaneIssue.ripRetryDelayTicks(0, 2, 67)) // attempt clamps up to 1
        assertEquals(67, LaneIssue.ripRetryDelayTicks(1000, 2, 67)) // no shift overflow
    }

    // ---- rip lane --------------------------------------------------------------------------------

    @Test fun noServerIsReportedAndTheManifestStillPolled() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        r.rips.hasServer = false
        r.d.begin(crate)
        advanceTimeBy(tick + 1)
        assertEquals(LaneIssue.NoServer, r.d.laneIssue)
        assertTrue("no request without a server", r.rips.requests.isEmpty())
        // another device ripped it: the lane notices and the issue clears once a server exists
        r.rips.ripped += "z"
        advanceTimeBy(tick * 2)
        assertTrue("z" in r.burns.burned)
        r.d.cancel()
        assertNull(r.d.laneIssue)
    }

    @Test fun refusedBatchBacksOffExponentiallyAndSaysWhy() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        r.rips.outcome = { RipBatchOutcome(401) }
        r.d.begin(crate)
        runCurrent()
        assertEquals(1, r.rips.requests.size)
        assertEquals(LaneIssue.TokenRejected, r.d.laneIssue)
        advanceTimeBy(tick * 60)
        // attempts at ticks 0, 2, 6, 14, 30, 62 - gaps 2, 4, 8, 16, 32 (never every tick)
        val ticks = r.rips.requests.map { (it.first / tick).toInt() }
        assertEquals(listOf(0, 2, 6, 14, 30), ticks)
        assertEquals(LaneIssue.TokenRejected, r.d.laneIssue)
        r.d.cancel()
    }

    @Test fun nonAuthRefusalIsAServerRefusalAndRecoveryClearsIt() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        var calls = 0
        r.rips.outcome = { if (++calls < 3) RipBatchOutcome(503) else RipBatchOutcome() }
        r.d.begin(crate)
        runCurrent()
        assertEquals(LaneIssue.RipServerRefused(503), r.d.laneIssue)
        advanceTimeBy(tick * 8)
        assertEquals(3, r.rips.requests.size)
        assertNull("accepted batch clears the issue", r.d.laneIssue)
        r.d.cancel()
    }

    @Test fun aThrownRequestIsATransportFailureNotACrash() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        r.rips.throwOnRequest = true
        r.d.begin(crate)
        runCurrent()
        assertEquals(LaneIssue.RipServerRefused(LaneIssue.TRANSPORT_FAILURE), r.d.laneIssue)
        assertTrue(r.d.state.value.isActive)
        r.d.cancel()
    }

    @Test fun stallWatchdogFlagsAndReRequestsThenAFlipClearsIt() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        r.d.ripStallTicks = 3
        r.d.begin(crate)
        runCurrent()
        assertEquals(1, r.rips.requests.size)
        assertNull(r.d.laneIssue)
        advanceTimeBy(tick * 3 + 1)
        assertEquals(LaneIssue.RipsStalled, r.d.laneIssue)
        advanceTimeBy(tick * 1)
        assertEquals("stall re-requests the still-pending ids", 2, r.rips.requests.size)
        assertEquals(listOf("z"), r.rips.requests.last().second)
        assertEquals("a re-request stays stalled until a song lands", LaneIssue.RipsStalled, r.d.laneIssue)
        r.rips.ripped += "z"
        advanceTimeBy(tick * 2)
        assertNull(r.d.laneIssue)
        assertEquals(2, r.d.downloadedCount)
        r.d.cancel()
    }

    @Test fun rejectedTokenIsReadLiveAndOutranksTheObservedIssue() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        r.d.begin(crate)
        runCurrent()
        assertNull(r.d.laneIssue)
        r.rips.isAuthRejected = true
        r.rips.authHoldoff = true
        advanceTimeBy(tick + 1)
        assertEquals(LaneIssue.TokenRejected, r.d.laneIssue)
        // a held lane never POSTs (a 401 is guaranteed)
        val during = r.rips.requests.size
        advanceTimeBy(tick * 5)
        assertEquals(during, r.rips.requests.size)
        // token re-typed: clears at once
        r.rips.isAuthRejected = false
        r.rips.authHoldoff = false
        advanceTimeBy(tick * 3)
        assertNull(r.d.laneIssue)
        r.d.cancel()
    }

    // ---- burn lane under a rejected token ---------------------------------------------------------

    @Test fun burnLaneParksUnderAuthHoldWithSongsStillQueuedThenResumes() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.rips.authHoldoff = true
        r.d.begin(crate)
        advanceTimeBy(5_000)
        assertTrue("parked: nothing burned", r.burns.burned.isEmpty())
        assertEquals(listOf("a", "b"), r.d.burnQueueForTesting)
        assertTrue(r.d.isActive)
        r.rips.authHoldoff = false
        advanceTimeBy(5_000)
        assertEquals(listOf("a", "b"), r.burns.burned)
        assertEquals(2, r.d.downloadedCount)
    }

    @Test fun burnLaneParkIsBoundedAndKeepsTheQueue() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.rips.authHoldoff = true
        r.d.authParkMaxMs = 10_000
        r.d.begin(crate)
        advanceTimeBy(60_000)
        assertTrue(r.burns.burned.isEmpty())
        assertEquals("songs stay queued after the lane gives up", listOf("a", "b"), r.d.burnQueueForTesting)
        r.d.cancel()
    }

    @Test fun aMissUnderARejectedTokenKeepsTheSongQueuedAtTheFront() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.rips.isAuthRejected = true // rejected, but the probe window let one burn through
        // that probe's 401 re-arms the holdoff (LIB-1 `noteAuthStatus`), so the lane parks right after it
        r.burns.lands = { r.rips.authHoldoff = true; false }
        r.d.begin(crate)
        runCurrent()
        assertEquals(listOf("a"), r.burns.burned)
        assertEquals("the credential failed, not the song: it stays queued first", "a", r.d.burnQueueForTesting.first())
        r.d.cancel()
    }

    // ---- overlap-corrected counts + catalog re-resolve --------------------------------------------

    @Test fun overlappingCratesCountSharedSongsOnceSoNoFalseShortfall() = runTest {
        val r = Rig(this)
        r.members[crate] = listOf("a", "b", "c")
        r.members[other] = listOf("c", "d", "e")
        r.rips.ripped += setOf("a", "b", "c", "d", "e")
        r.d.declaredMemberCount = { 3 } // raw sum 6, union 5, overlap 1 -> 5 declared
        r.d.begin(listOf(crate, other))
        assertEquals(5, r.d.totalCount)
        assertNull("fully resolved overlapping crates are not a partial catalog", r.d.catalogShortfall)
        r.d.cancel()
    }

    @Test fun trueShortfallSurvivesTheOverlapCorrection() = runTest {
        val r = Rig(this)
        r.members[crate] = listOf("a", "b", "c")
        r.members[other] = listOf("c", "d", "e")
        r.rips.ripped += setOf("a", "b", "c", "d", "e")
        r.d.declaredMemberCount = { if (it == crate) 4 else 3 } // one member of `crate` never resolved
        r.d.catalogIsLoading = { true }
        r.d.begin(listOf(crate, other))
        assertEquals(CatalogShortfall(6, 5), r.d.catalogShortfall)
        assertTrue(r.d.catalogStillLoading)
        r.d.cancel()
        assertFalse(r.d.catalogStillLoading)
    }

    @Test fun stillLoadingOnlyWhileTheCatalogIsLoading() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.d.declaredMemberCount = { 5 }
        var loading = true
        r.d.catalogIsLoading = { loading }
        r.d.begin(crate)
        assertTrue(r.d.catalogStillLoading)
        loading = false
        r.d.catalogDidChange() // nothing new resolved, but the catalog finished: copy flips
        assertEquals(CatalogShortfall(5, 2), r.d.catalogShortfall)
        assertFalse(r.d.catalogStillLoading)
        r.d.cancel()
    }

    @Test fun lateCatalogMembersJoinTheRunningLanes() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.d.declaredMemberCount = { 4 }
        r.burns.lands = { it != "never" }
        r.rips.hasServer = true
        r.d.authParkMaxMs = 1
        r.rips.authHoldoff = true // park the burn lane so the run stays active and observable
        r.d.begin(crate)
        assertEquals(CatalogShortfall(4, 2), r.d.catalogShortfall)
        // the catalog assigns: c (ripped) and d (not ripped) resolve late
        r.members[crate] = listOf("a", "b", "c", "d")
        r.rips.ripped += "c"
        r.rips.authHoldoff = false
        r.d.catalogDidChange()
        assertEquals(4, r.d.totalCount)
        assertNull("shortfall cleared once every declared member resolved", r.d.catalogShortfall)
        assertTrue("c queued for the burn lane or burned", "c" in r.d.burnQueueForTesting || "c" in r.burns.burned || "c" in r.d.downloadedIds)
        assertEquals("d joins the RUNNING rip lane", setOf("d"), r.d.ripPendingForTesting)
        runCurrent()
        assertTrue(r.rips.requests.any { it.second == listOf("d") })
        r.d.cancel()
    }

    @Test fun lateMembersAlreadyOnDiskAreCountedDownloaded() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("b"), onDisk = setOf("c"))
        r.rips.authHoldoff = true
        r.d.begin(crate)
        r.members[crate] = listOf("a", "b", "c")
        r.d.catalogDidChange()
        assertEquals(3, r.d.totalCount)
        assertTrue("c" in r.d.downloadedIds)
        r.d.cancel()
    }

    @Test fun aFinishedRunIsNeverRevivedByACatalogEventUnlessOurMixStillRuns() = runTest {
        val r = rig(listOf("a"), onDisk = setOf("a"))
        r.d.declaredMemberCount = { 2 }
        r.d.begin(crate)
        assertFalse(r.d.isActive)
        r.members[crate] = listOf("a", "b")
        r.rips.ripped += "b"
        r.host.autoEndedExhausted = true
        r.d.noteAutoStarted(setOf("a"), 15.0, 3.0, "crate:playlist:c")
        r.d.catalogDidChange() // no mix running: nothing to feed, and never revive an exhausted mix
        assertFalse(r.d.isActive)
        assertTrue(r.host.starts.isEmpty())
        // now OUR mix runs: late member b feeds it
        r.host.autoMixing = true
        r.host.autoSourceLabel = "crate:playlist:c"
        r.d.catalogDidChange()
        assertTrue(r.d.isActive || r.host.inserts.any { it.loadable.songId == "b" })
        assertTrue(r.host.inserts.any { it.loadable.songId == "b" })
        r.d.cancel()
    }

    // ---- one audio owner ---------------------------------------------------------------------------

    @Test fun aLandingNeverStartsAMixOverAnotherAudioOwner() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.rips.authHoldoff = true // hold the burn lane: landings are scripted
        r.host.autoEndedExhausted = true
        r.d.otherAudioActive = { true }
        r.d.begin(crate)
        r.d.noteAutoStarted(emptySet(), 15.0, 3.0, "L")
        r.d.simulateLandingForTesting("a")
        assertTrue("Now Playing owns the audio", r.host.starts.isEmpty())
        assertFalse("the zero-start arm died with the refusal", r.d.autoStartPendingForTesting)
        r.d.cancel()
    }

    @Test fun withNoOtherOwnerTheSameLandingStartsTheMix() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.rips.authHoldoff = true
        r.host.autoEndedExhausted = true
        r.d.otherAudioActive = { false }
        r.d.begin(crate)
        r.d.noteAutoStarted(emptySet(), 15.0, 3.0, "L")
        r.d.simulateLandingForTesting("a")
        assertEquals(1, r.host.starts.size)
        r.d.cancel()
    }

    @Test fun catalogEventsOnlyFeedAndNeverReviveAnExhaustedMix() = runTest {
        val r = rig(listOf("a"), ripped = setOf("a"))
        r.rips.authHoldoff = true
        r.d.begin(crate)
        r.host.autoEndedExhausted = true
        r.d.noteAutoStarted(setOf("zz"), 15.0, 3.0, "L")
        r.members[crate] = listOf("a", "b")
        r.rips.ripped += "b"
        r.d.catalogDidChange()
        assertTrue("allowRestart=false: an exhausted mix is not revived by a catalog assign", r.host.starts.isEmpty())
        r.d.cancel()
    }

    // ---- regression: healthy paths unchanged ---------------------------------------------------------

    @Test fun healthyRunHasNoLaneIssueAndFinishesClean() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a", "b"))
        r.d.begin(crate)
        runCurrent()
        assertNull(r.d.laneIssue)
        assertEquals(2, r.d.downloadedCount)
        assertFalse(r.d.isActive)
        assertEquals(0, r.rips.requests.size)
    }
}

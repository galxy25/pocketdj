package com.levi.pocketdj.mix.download

import com.levi.pocketdj.data.burns.BurnState
import com.levi.pocketdj.mix.model.AutoMixItem
import com.levi.pocketdj.mix.model.MixLoadable
import com.levi.pocketdj.mix.model.MixSource
import kotlinx.coroutines.CompletableDeferred
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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class CollectionMixDownloaderTest {

    private class FakeBurns : MixDownloadBurns {
        val disk = LinkedHashSet<String>()
        val burned = ArrayList<String>()
        val statuses = HashMap<String, MixBurnStatus>()
        var gate: CompletableDeferred<Unit>? = null
        /** id -> does the in-process burn produce a file? */
        var lands: (String) -> Boolean = { true }
        var bytesPer = 1_000_000L
        var userBurn = false
        var stops = 0
        val cancelled = ArrayList<String>()
        var finalized: ((String) -> Unit)? = null
        var onBytes: ((String, Long) -> Unit)? = null
        override fun isOnDisk(songId: String) = songId in disk
        override val userBurnActive get() = userBurn
        override suspend fun burn(songId: String, title: String, artist: String) {
            gate?.await()
            burned += songId
            if (lands(songId)) { disk += songId; statuses[songId] = MixBurnStatus(BurnState.READY, null, bytesPer) }
            else statuses[songId] = MixBurnStatus(BurnState.ERROR, "presign timeout", 0)
        }
        override fun status(songId: String) = statuses[songId]
        override fun requestStop() { stops++ }
        override fun cancelTransfers(songIds: Collection<String>) { cancelled += songIds }
        override fun watchFinalized(cb: ((String) -> Unit)?) { finalized = cb }
        override fun watchBytes(cb: ((String, Long) -> Unit)?) { onBytes = cb }
    }

    private class FakeRips : MixDownloadRips {
        val ripped = HashSet<String>()
        val durations = HashMap<String, Long>()
        val ripCalls = ArrayList<List<String>>()
        val cancelCalls = ArrayList<List<String>>()
        var refreshes = 0
        var onRefresh: (Int) -> Unit = {}
        override var hasServer = true
        var serverAfterPrepare: Boolean? = null
        var prepares = 0
        override suspend fun prepare() { prepares++; serverAfterPrepare?.let { hasServer = it } }
        override fun isRipped(songId: String) = songId in ripped
        override fun durationMs(songId: String) = durations[songId]
        override val manifestCount get() = ripped.size
        override suspend fun ripCollection(songIds: List<String>) { ripCalls += songIds }
        override suspend fun cancelCollection(songIds: List<String>) { cancelCalls += songIds }
        override suspend fun refreshManifest() { refreshes++; onRefresh(refreshes) }
    }

    private class FakeHost : AutoMixHost {
        override var autoMixing = false
        override var autoEndedExhausted = false
        override var isRunning = false
        override var deckGestureGeneration = 0
        override var autoSourceLabel: String? = null
        override var autoUpcomingSongIds: List<String> = emptyList()
        val streaming = HashSet<String>()
        val inserts = ArrayList<Pair<AutoMixItem, AutoPlacement>>()
        class Start(val items: List<AutoMixItem>, val shuffled: Boolean, val lead: Double, val fade: Double, val label: String?)
        val starts = ArrayList<Start>()
        val cancelledStreams = ArrayList<String>()
        var onBytes: ((String, Long) -> Unit)? = null
        var onFailed: ((String) -> Unit)? = null
        override fun autoQueueInsert(item: AutoMixItem, placement: AutoPlacement) { inserts += item to placement }
        override fun startAutoMix(items: List<AutoMixItem>, shuffled: Boolean, lead: Double, fade: Double, label: String?) {
            starts += Start(items, shuffled, lead, fade, label)
        }
        override fun isStreaming(songId: String) = songId in streaming
        override fun cancelStreams(songIds: List<String>) { cancelledStreams += songIds }
        override fun setStreamHooks(onBytes: ((String, Long) -> Unit)?, onFailed: ((String) -> Unit)?) {
            this.onBytes = onBytes; this.onFailed = onFailed
        }
    }

    private class Rig(scope: TestScope) {
        val burns = FakeBurns()
        val rips = FakeRips()
        val host = FakeHost()
        var clock = 1000.0
        val members = HashMap<MixSource, List<String>>()
        val d = CollectionMixDownloader(
            CoroutineScope(UnconfinedTestDispatcher(scope.testScheduler)), burns, rips, host,
        ).also { it.now = { clock } }
        init {
            d.resolveRipIds = { members[it].orEmpty() }
            // loadable = on disk OR ripped (streaming mode)
            d.resolveLoadables = { src ->
                members[src].orEmpty().filter { it in burns.disk || it in rips.ripped }.map {
                    MixLoadable(songId = it, title = "T$it", artist = "A$it", lengthMs = 200_000)
                }
            }
            d.resolveSourceName = { "crate:${it.id}" }
        }
    }

    private val crate = MixSource.Playlist("c")
    private val other = MixSource.Playlist("o")

    private fun TestScope.rig(ids: List<String>, onDisk: Set<String> = emptySet(), ripped: Set<String> = ids.toSet()) =
        Rig(this).also {
            it.members[crate] = ids
            it.burns.disk += onDisk
            it.rips.ripped += ripped
        }

    @Test fun seedPartitionsOnDiskBurnLaneAndRipLane() = runTest {
        val r = rig(listOf("a", "b", "c", "d", "e"), onDisk = setOf("a"), ripped = setOf("a", "b", "c"))
        r.burns.gate = CompletableDeferred() // park the burn lane so the partition is observable
        r.d.begin(crate)
        assertTrue(r.d.isActive)
        assertEquals(5, r.d.totalCount)
        assertEquals(1, r.d.downloadedCount)
        assertEquals(2, r.d.rippingCount)
        assertEquals(setOf("a"), r.d.downloadedIds)
        // b is in flight (removed from the queue); c waits
        assertEquals(listOf("c"), r.d.burnQueueForTesting)
        assertEquals(listOf(listOf("d", "e")), r.rips.ripCalls)
        r.d.cancel()
    }

    @Test fun nothingToDoLeavesInactive() = runTest {
        val r = rig(listOf("a", "b"), onDisk = setOf("a", "b"))
        r.d.begin(crate)
        assertFalse(r.d.isActive)
        assertEquals(2, r.d.totalCount); assertEquals(2, r.d.downloadedCount)
        val e = rig(emptyList())
        e.d.begin(crate)
        assertFalse(e.d.isActive)
        assertEquals(0, e.d.totalCount)
    }

    @Test fun sameSourcesWhileActiveIsNoopDifferentSourceReseeds() = runTest {
        val r = rig(listOf("a", "b", "c", "d"), ripped = setOf("a", "b"))
        r.members[other] = listOf("x", "y")
        r.rips.ripped += "x"
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        assertEquals(1, r.rips.ripCalls.size)
        r.d.begin(listOf(crate)) // same set: nothing happens
        assertEquals(1, r.rips.ripCalls.size)
        assertEquals(0, r.burns.stops)
        r.d.begin(other)
        assertEquals(1, r.burns.stops) // old run cancelled
        assertEquals(listOf(listOf("c", "d")), r.rips.cancelCalls) // rip-pending ids cancelled server-side
        assertEquals(listOf(other), r.d.sources)
        assertEquals(2, r.d.totalCount)
        assertEquals(listOf("y"), r.rips.ripCalls.last())
        r.d.cancel()
    }

    @Test fun multiCrateUnionIsTrackedOnce() = runTest {
        val r = rig(listOf("a", "b"))
        r.members[other] = listOf("b", "c")
        r.rips.ripped += "c"
        r.burns.gate = CompletableDeferred()
        r.d.begin(listOf(crate, other))
        assertEquals(3, r.d.totalCount)
        r.d.cancel()
    }

    @Test fun burnLaneLandsEverythingInOrderAndFinishes() = runTest {
        val r = rig(listOf("a", "b", "c"))
        r.d.begin(crate)
        runCurrent()
        assertEquals(listOf("a", "b", "c"), r.burns.burned)
        assertEquals(3, r.d.downloadedCount)
        assertFalse(r.d.isActive) // finishRun
        assertNull(r.d.etaSeconds)
        assertEquals(0, r.d.rippingCount)
        assertNull(r.burns.finalized) // hooks removed
        assertNull(r.host.onBytes)
    }

    @Test fun burnLaneFollowsUpcomingPlayOrderAndSkipsStreamingSongs() = runTest {
        val r = rig(listOf("a", "b", "c", "d"))
        r.burns.gate = CompletableDeferred()
        r.host.autoUpcomingSongIds = listOf("x", "d", "b")
        r.host.streaming += "d"
        r.d.begin(crate)
        // d is upcoming first but a deck is streaming it: b was taken first (now in flight, off the queue)
        assertEquals(listOf("a", "c", "d"), r.d.burnQueueForTesting)
        r.host.streaming.clear()
        assertEquals("d", r.d.nextBurnIdForTesting)
        r.host.autoUpcomingSongIds = emptyList()
        assertEquals(r.d.burnQueueForTesting.first(), r.d.nextBurnIdForTesting) // collection order
        r.d.cancel()
    }

    @Test fun aStreamingSongIsNeverBurnedTwiceAndLandsViaAdoption() = runTest {
        val r = rig(listOf("a", "b"))
        r.host.streaming += "a"
        r.d.begin(crate)
        runCurrent()
        assertEquals(listOf("b"), r.burns.burned) // a is skipped: its stream IS the download
        assertEquals(1, r.d.downloadedCount)
        // adoption lands a (burn-finalized hook)
        r.burns.disk += "a"; r.host.streaming.clear()
        r.burns.finalized!!.invoke("a")
        assertEquals(2, r.d.downloadedCount)
        assertEquals(listOf("b"), r.burns.burned)
        assertFalse(r.d.isActive)
    }

    @Test fun failedStreamIsHandedBackToTheLane() = runTest {
        val r = rig(listOf("a", "b"))
        r.host.streaming += "a"
        r.d.begin(crate)
        runCurrent()
        r.host.streaming.clear()
        r.host.onFailed!!.invoke("a")
        advanceTimeBy(1000)
        assertEquals(listOf("b", "a"), r.burns.burned)
        assertEquals(2, r.d.downloadedCount)
    }

    @Test fun manifestFlipDuringRipPollMovesIntoBurnLane() = runTest {
        val r = rig(listOf("a", "b", "c"), ripped = setOf("a"))
        r.rips.onRefresh = { n -> if (n == 2) r.rips.ripped += "b"; if (n == 4) r.rips.ripped += "c" }
        r.d.begin(crate)
        runCurrent()
        assertEquals(listOf("a"), r.burns.burned)
        assertEquals(2, r.d.rippingCount) // b, c still ripping
        advanceTimeBy(4500L * 2 + 1)
        assertEquals(2, r.rips.refreshes)
        assertEquals(1, r.d.rippingCount)
        assertTrue("b" in r.burns.burned)
        advanceTimeBy(4500L * 2 + 1000)
        assertEquals(listOf("a", "b", "c"), r.burns.burned)
        assertEquals(3, r.d.downloadedCount)
        assertFalse(r.d.isActive)
    }

    @Test fun ripLaneRefreshesServerFlagBeforeReadingIt() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        r.rips.serverAfterPrepare = false
        r.d.begin(crate)
        advanceTimeBy(100)
        assertEquals(1, r.rips.prepares)
        assertEquals(false, r.rips.hasServer)
        r.d.cancel()
    }

    @Test fun ripPollStopsAtMaxTicks() = runTest {
        val r = rig(listOf("a", "z"), ripped = setOf("a"))
        r.d.ripPollMaxTicks = 3
        r.d.begin(crate)
        advanceTimeBy(4500L * 10)
        assertEquals(3, r.rips.refreshes)
        r.d.cancel()
    }

    @Test fun etaIsNullUntilFirstSampleThenFollowsThroughputWindow() = runTest {
        val r = rig(listOf("a", "b", "c"))
        r.rips.durations["a"] = 100_000; r.rips.durations["b"] = 100_000; r.rips.durations["c"] = 100_000
        r.d.songLengthSeconds = { id -> if (id == "c") 50.0 else null } // catalog beats manifest
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        assertNull(r.d.etaSeconds)
        // remaining playback = 100 + 100 + 50 = 250 s -> 250 * 32768 B. Observe 819200 B over the 1 s floor.
        r.d.addThroughputSampleForTesting(819_200)
        val expected = 250 * 32_768.0 / 819_200.0
        assertEquals(expected, r.d.etaSeconds!!, 1e-9)
        // 10 s later the same bytes average over 10 s
        r.clock += 10
        r.d.addThroughputSampleForTesting(0)
        assertEquals(250 * 32_768.0 / (819_200.0 / 10), r.d.etaSeconds!!, 1e-6)
        // 31 s after the sample the window is empty again -> null
        r.clock += 21
        r.d.addThroughputSampleForTesting(0)
        // only the zero-byte sample at t=1031 remains: 0 B/s -> bps floor of 1
        assertEquals(250 * 32_768.0, r.d.etaSeconds!!, 1e-6)
        r.d.cancel()
    }

    @Test fun etaExcludesRippingAndUsesFallbackLength() = runTest {
        val r = rig(listOf("a", "b"), ripped = setOf("a")) // b needs a rip
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.d.addThroughputSampleForTesting(32_768) // 1 s floor -> 32768 B/s = 1 playback s per s
        assertEquals(1, r.d.rippingCount)
        assertEquals(180.0, r.d.etaSeconds!!, 1e-9) // only a, fallback 180 s
        r.d.cancel()
    }

    @Test fun landingProgressAndStreamBytesFeedTheWindow() = runTest {
        val r = rig(listOf("a", "b", "c"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.host.onBytes!!.invoke("a", 500_000) // streamed bytes count
        assertNotNull(r.d.etaSeconds)
        r.host.onBytes!!.invoke("zzz", 500_000) // untracked ignored
        r.burns.onBytes!!.invoke("b", 0) // non-positive ignored
        r.d.simulateLandingForTesting("a", bytes = 100)
        assertEquals(1, r.d.downloadedCount)
        r.d.simulateLandingForTesting("a") // double landing
        r.d.simulateLandingForTesting("nope")
        assertEquals(1, r.d.downloadedCount)
        assertEquals(setOf("a"), r.d.downloadedIds)
        r.d.cancel()
    }

    @Test fun catalogShortfallPublishedWhenDeclaredExceedsResolved() = runTest {
        val r = rig(listOf("a", "b"))
        r.d.declaredMemberCount = { 5 }
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        assertEquals(CatalogShortfall(5, 2), r.d.catalogShortfall)
        r.d.cancel()
        assertNull(r.d.catalogShortfall)
        r.d.declaredMemberCount = { 2 }
        r.d.begin(crate)
        assertNull(r.d.catalogShortfall)
        r.d.cancel()
    }

    // ---- progressive eligibility ----------------------------------------------------------------

    private fun runningAuto(r: Rig, label: String, shuffled: Boolean = false, initial: Set<String> = setOf("a")) {
        r.host.autoMixing = true
        r.host.autoSourceLabel = label
        r.d.noteAutoStarted(initial, lead = 12.0, fade = 4.0, label = label, shuffled = shuffled)
    }

    @Test fun landingAppendsToRunningMixWhenLabelOwned() = runTest {
        val r = rig(listOf("a", "b", "c"), onDisk = setOf("a"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        runningAuto(r, "mine")
        r.d.simulateLandingForTesting("b")
        // loadables for the crate now = a (disk), b (disk), c (ripped, streamable) -> b and c appended; a is initial
        assertEquals(listOf("b", "c"), r.host.inserts.map { it.first.loadable.songId })
        assertTrue(r.host.inserts.all { it.second == AutoPlacement.END })
        assertEquals("crate:playlist:c", r.host.inserts[0].first.sourceLabel)
        assertEquals(200_000, r.host.inserts[0].first.durationMs)
        // dedupe: another landing appends nothing new
        r.d.simulateLandingForTesting("c")
        assertEquals(2, r.host.inserts.size)
        r.d.cancel()
    }

    @Test fun shuffledMixGetsRandomPlacement() = runTest {
        val r = rig(listOf("a", "b"), onDisk = setOf("a"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        runningAuto(r, "mine", shuffled = true)
        r.d.simulateLandingForTesting("b")
        assertEquals(listOf(AutoPlacement.RANDOM), r.host.inserts.map { it.second })
        r.d.cancel()
    }

    @Test fun someoneElsesMixIsNeverFed() = runTest {
        val r = rig(listOf("a", "b"), onDisk = setOf("a"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        runningAuto(r, "mine")
        r.host.autoSourceLabel = "theirs"
        r.d.simulateLandingForTesting("b")
        assertTrue(r.host.inserts.isEmpty())
        assertTrue(r.host.starts.isEmpty())
        r.d.cancel()
    }

    @Test fun exhaustedMixIsReArmedWithLateArrivals() = runTest {
        val r = rig(listOf("a", "b"), onDisk = setOf("a"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.host.autoMixing = false
        r.host.autoEndedExhausted = true
        r.d.noteAutoStarted(setOf("a"), lead = 12.0, fade = 4.0, label = "mine", shuffled = true)
        r.d.simulateLandingForTesting("b")
        val s = r.host.starts.single()
        assertEquals(listOf("b"), s.items.map { it.loadable.songId })
        assertFalse(s.shuffled)
        assertEquals(12.0, s.lead, 0.0); assertEquals(4.0, s.fade, 0.0); assertEquals("mine", s.label)
        r.d.cancel()
    }

    @Test fun exhaustedPickupYieldsToADeckThatIsSounding() = runTest {
        val r = rig(listOf("a", "b"), onDisk = setOf("a"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.host.autoEndedExhausted = true
        r.d.noteAutoStarted(setOf("a"), 15.0, 3.0, "mine")
        r.host.isRunning = true // DJ hand-mixing
        r.d.simulateLandingForTesting("b")
        assertTrue(r.host.starts.isEmpty())
        r.d.cancel()
    }

    @Test fun zeroStartPickupStartsOnFirstLanding() = runTest {
        val r = rig(listOf("a", "b"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.d.noteAutoStarted(emptySet(), 15.0, 3.0, "mine")
        assertTrue(r.d.autoStartPendingForTesting)
        r.d.simulateLandingForTesting("a")
        assertFalse(r.d.autoStartPendingForTesting)
        assertEquals(listOf("a", "b"), r.host.starts.single().items.map { it.loadable.songId }) // b is ripped => streamable
        r.d.cancel()
    }

    @Test fun deckGestureSinceArmKillsZeroStart() = runTest {
        val r = rig(listOf("a", "b"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.d.noteAutoStarted(emptySet(), 15.0, 3.0, "mine")
        r.host.deckGestureGeneration++ // the DJ loaded a deck by hand
        r.d.simulateLandingForTesting("a")
        assertTrue(r.host.starts.isEmpty())
        assertFalse(r.d.autoStartPendingForTesting)
        r.d.simulateLandingForTesting("b")
        assertTrue(r.host.starts.isEmpty()) // and it stays dead
        r.d.cancel()
    }

    @Test fun runningMixClearsPendingZeroStart() = runTest {
        val r = rig(listOf("a", "b"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.d.noteAutoStarted(emptySet(), 15.0, 3.0, "mine")
        r.host.autoMixing = true; r.host.autoSourceLabel = "mine"
        r.d.simulateLandingForTesting("a")
        assertFalse(r.d.autoStartPendingForTesting)
        assertEquals(2, r.host.inserts.size)
        r.d.cancel()
    }

    @Test fun ripFlipJoinsRunningMixBeforeItsDownload() = runTest {
        val r = rig(listOf("a", "b"), onDisk = setOf("a"), ripped = setOf("a"))
        r.burns.userBurn = true // park the burn lane behind a user burn
        r.rips.onRefresh = { r.rips.ripped += "b" }
        r.d.begin(crate)
        runningAuto(r, "mine")
        advanceTimeBy(4600)
        assertEquals(listOf("b"), r.host.inserts.map { it.first.loadable.songId })
        r.d.cancel()
    }

    // ---- cancel / leave / retry ----------------------------------------------------------------

    @Test fun cancelKillsTheWholeArmAndClearsState() = runTest {
        val r = rig(listOf("a", "b"), onDisk = setOf("a"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.d.noteAutoStarted(emptySet(), 15.0, 3.0, "mine")
        r.d.cancel()
        assertFalse(r.d.autoArmedForTesting)
        assertFalse(r.d.autoStartPendingForTesting)
        assertFalse(r.d.isActive)
        assertEquals(0, r.d.totalCount); assertEquals(0, r.d.downloadedCount)
        assertTrue(r.d.sources.isEmpty()); assertTrue(r.d.downloadedIds.isEmpty())
        assertEquals(1, r.burns.stops)
        assertEquals(listOf("b"), r.burns.cancelled)
        assertEquals(listOf("b"), r.host.cancelledStreams)
        // a stale landing after cancel never starts a mix
        r.d.simulateLandingForTesting("b")
        assertTrue(r.host.starts.isEmpty())
    }

    @Test fun cancelledRunTailCannotTouchTheNextRun() = runTest {
        val r = rig(listOf("a", "b"))
        val gate = CompletableDeferred<Unit>()
        r.burns.gate = gate
        r.d.begin(crate)
        r.d.cancel()
        r.burns.gate = null
        r.d.begin(crate)
        runCurrent()
        gate.complete(Unit) // the first run's parked burn wakes up late
        runCurrent()
        assertEquals(2, r.d.downloadedCount)
        assertTrue("a" in r.burns.burned)
    }

    @Test fun mixLeaveCancelsOnlyWhenEngineIdle() = runTest {
        val r = rig(listOf("a", "b"))
        r.burns.gate = CompletableDeferred()
        r.d.begin(crate)
        r.d.handleMixLeave(engineActive = true)
        assertTrue(r.d.isActive)
        assertEquals(2, r.d.totalCount)
        r.d.handleMixLeave(engineActive = false)
        assertFalse(r.d.isActive)
        assertEquals(0, r.d.totalCount)
    }

    @Test fun missedBurnsGetOneSecondSweep() = runTest {
        val r = rig(listOf("a", "b"))
        val tries = HashMap<String, Int>()
        r.burns.lands = { id -> tries.merge(id, 1, Int::plus); id == "b" || tries[id]!! >= 2 }
        r.d.begin(crate)
        runCurrent()
        advanceTimeBy(2000)
        assertEquals(listOf("a", "b", "a"), r.burns.burned)
        assertEquals(2, r.d.downloadedCount)
    }

    @Test fun structuralFailuresStandAfterOneRetry() = runTest {
        val r = rig(listOf("a", "b"))
        r.burns.lands = { it == "b" }
        r.d.begin(crate)
        advanceTimeBy(5000)
        assertEquals(listOf("a", "b", "a"), r.burns.burned) // exactly one re-run
        assertEquals(1, r.d.downloadedCount)
    }

    @Test fun burnWaitsWhileAUserBurnOwnsTheStore() = runTest {
        val r = rig(listOf("a"))
        r.burns.userBurn = true
        r.d.begin(crate)
        advanceTimeBy(2000)
        assertTrue(r.burns.burned.isEmpty())
        r.burns.userBurn = false
        advanceTimeBy(600)
        assertEquals(listOf("a"), r.burns.burned)
        assertTrue(currentTime >= 2600)
    }

    @Test fun backgroundTransferInFlightIsNotAMissAndLandsViaFinalize() = runTest {
        val r = rig(listOf("a"))
        r.burns.lands = { false }
        // emulate the background path: burn() returns with the item still downloading
        val bg = object : MixDownloadBurns by r.burns {
            override suspend fun burn(songId: String, title: String, artist: String) {
                r.burns.statuses[songId] = MixBurnStatus(BurnState.DOWNLOADING, null, 0)
            }
        }
        val d = CollectionMixDownloader(CoroutineScope(UnconfinedTestDispatcher(testScheduler)), bg, r.rips, r.host)
        d.resolveRipIds = { listOf("a") }
        d.begin(crate)
        runCurrent()
        assertEquals(0, d.downloadedCount)
        assertTrue(d.isActive)
        r.burns.disk += "a"
        r.burns.finalized!!.invoke("a")
        assertEquals(1, d.downloadedCount)
        assertFalse(d.isActive)
    }

    // ---- pure helpers ----------------------------------------------------------------------------

    @Test fun throughputWindowPrunesAndFloorsTheSpan() {
        val w = CollectionMixDownloader.ThroughputWindow()
        assertNull(w.bytesPerSecond(0.0))
        w.add(1000, 100.0)
        assertEquals(1000.0, w.bytesPerSecond(100.0)!!, 1e-9) // 1 s floor
        w.add(1000, 110.0)
        assertEquals(2000.0 / 10, w.bytesPerSecond(110.0)!!, 1e-9)
        assertEquals(2000.0 / 20, w.bytesPerSecond(120.0)!!, 1e-9) // first sample at 100 still in (<=30 s)
        assertEquals(1000.0 / 25, w.bytesPerSecond(135.0)!!, 1e-9) // t=100 dropped, t=110 remains, span 25
    }

    @Test fun etaMathAndLabel() {
        assertNull(CollectionMixDownloader.etaSeconds(100.0, null))
        assertEquals(10.0, CollectionMixDownloader.etaSeconds(10.0, 32_768.0)!!, 1e-9)
        assertEquals("—", CollectionMixDownloader.etaLabel(null))
        assertEquals("—", CollectionMixDownloader.etaLabel(-1.0))
        assertEquals("—", CollectionMixDownloader.etaLabel(Double.POSITIVE_INFINITY))
        assertEquals("45s", CollectionMixDownloader.etaLabel(45.2))
        assertEquals("3m 20s", CollectionMixDownloader.etaLabel(200.0))
        assertEquals("1m 0s", CollectionMixDownloader.etaLabel(59.6))
    }
}

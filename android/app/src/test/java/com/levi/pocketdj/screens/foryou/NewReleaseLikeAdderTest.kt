package com.levi.pocketdj.screens.foryou

import com.levi.pocketdj.data.recs.ArtistReleaseEntry
import com.levi.pocketdj.data.recs.LikeAddAttempt
import com.levi.pocketdj.data.recs.LikeAddState
import com.levi.pocketdj.data.recs.LikedRelease
import com.levi.pocketdj.data.recs.LikedReleasesStore
import com.levi.pocketdj.data.recs.ReleaseFeedTransport
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The like-adder's state machine, driven with a counting fake port - no network, no controller. */
class NewReleaseLikeAdderTest {
    private val day = 86_400_000.0
    private val hour = 3_600_000.0
    private var clockMs = 1_800_000_000_000.0

    private class FakePort : ReleaseAddPort {
        val addCalls = ArrayList<String>()
        val writeCalls = ArrayList<String>()
        var next = ReleaseAddReport("confirmed (web)", recorded = true, error = null)
        var offline = false
        override val isOffline: Boolean get() = offline
        private var running = 0
        var maxConcurrent = 0
        /** When set, `add` suspends until it completes - holds an add IN FLIGHT deterministically. */
        var gate: kotlinx.coroutines.CompletableDeferred<Unit>? = null
        override suspend fun add(release: LikedRelease): ReleaseAddReport {
            addCalls += release.storeId
            running++; maxConcurrent = maxOf(maxConcurrent, running)
            yield()
            gate?.await()
            running--
            return next
        }
        override suspend fun retryWrite(release: LikedRelease): ReleaseAddReport { writeCalls += release.storeId; return next }
    }

    private fun make(
        port: FakePort = FakePort(),
        transport: ReleaseFeedTransport? = null,
        file: File? = null,
    ): Triple<NewReleaseLikeAdder, FakePort, LikedReleasesStore> {
        val store = LikedReleasesStore(file)
        val adder = NewReleaseLikeAdder(store, port, transport, CoroutineScope(Dispatchers.Unconfined)) { clockMs }
        return Triple(adder, port, store)
    }

    private fun entry(id: String, at: Double? = null) = ArtistReleaseEntry(
        artistId = id.toIntOrNull() ?: 1, artistName = "A", releaseId = id, releaseName = "T$id",
        releaseAtMs = at ?: (clockMs - 2 * day), releaseKind = "album", trackCount = 8,
    )

    private fun fail(msg: String = "boom") = ReleaseAddReport("confirmed (web)", recorded = false, error = msg)

    // ---- one add per thumbs-up ----

    @Test fun likeAddsExactlyOnceAndMarksAdded() = runBlocking {
        val (adder, port, store) = make()
        adder.liked(entry("1"))?.join()
        assertEquals(listOf("1"), port.addCalls)
        assertEquals(LikeAddState.ADDED, store.releases["1"]?.attempt?.state)
        assertTrue(adder.busy.value.ids.isEmpty())
    }

    @Test fun doubleTapWhileInFlightAddsOnce() = runBlocking {
        val (adder, port, _) = make()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        port.gate = gate
        val a = adder.liked(entry("1"))
        assertTrue("the first add is running", "1" in adder.busy.value.inFlight)
        val b = adder.liked(entry("1")) // the double tap, while the first is still in flight
        gate.complete(Unit)
        a?.join(); b?.join()
        assertEquals(listOf("1"), port.addCalls)
        assertTrue("no id left queued behind a redundant tap", adder.busy.value.ids.isEmpty())
    }

    @Test fun relartistEntryIsANoOp() {
        val (adder, port, store) = make()
        assertNull(adder.liked(ArtistReleaseEntry(5, "A")))
        assertTrue(port.addCalls.isEmpty()); assertTrue(store.releases.isEmpty())
    }

    @Test fun verdictGoneBeforeTheAddStartsCancelsIt() = runBlocking {
        val (adder, port, _) = make()
        adder.acceptedProvider = { emptyMap() }
        adder.liked(entry("1"))?.join()
        assertTrue(port.addCalls.isEmpty())
        assertTrue("and nothing else is called - there is no library removal", port.writeCalls.isEmpty())
    }

    @Test fun alreadyOwnedLikeDoesNotAdd() {
        val (adder, port, _) = make()
        adder.isOwned = { true }
        assertNull(adder.liked(entry("1")))
        assertTrue(port.addCalls.isEmpty())
    }

    // ---- failure keeps everything ----

    @Test fun failureKeepsTheReleaseWithTheHonestMessage() = runBlocking {
        val port = FakePort().apply { next = fail("Couldn’t read the album’s tracks — try again.") }
        val (adder, _, store) = make(port)
        adder.liked(entry("1"))?.join()
        val a = store.releases["1"]?.attempt
        assertEquals(LikeAddState.FAILED, a?.state)
        assertEquals("Couldn’t read the album’s tracks — try again.", a?.message)
        assertEquals(false, a?.recorded)
    }

    @Test fun recordedButWriteFailedIsFailedWithLibraryNoticeAndRetryRunsOnlyTheWrite() = runBlocking {
        val port = FakePort().apply {
            next = ReleaseAddReport("Apple Music write failed: nope", recorded = true,
                error = LikeAddWording.libraryNotice("Apple Music write failed: nope"))
        }
        val (adder, _, store) = make(port)
        adder.liked(entry("1"))?.join()
        assertEquals(LikeAddState.FAILED, store.releases["1"]?.attempt?.state)
        assertTrue(store.releases["1"]?.attempt?.message?.contains("Apple Music library add failed") == true)
        port.next = ReleaseAddReport("confirmed (web)", recorded = true, error = null)
        adder.retry("1", writeOnly = true)
        assertEquals(listOf("1"), port.writeCalls)
        assertEquals(listOf("1"), port.addCalls)
        assertEquals(LikeAddState.ADDED, store.releases["1"]?.attempt?.state)
        assertTrue(store.releases["1"]?.attempt?.writeProven == true)
    }

    // ---- sweep ----

    @Test fun offlineSweepRetriesOnceAndRespectsTheSixHourThrottle() = runBlocking {
        val port = FakePort().apply { next = fail(); offline = true }
        val (adder, _, store) = make(port)
        adder.liked(entry("1"))?.join()
        assertEquals(LikeAddState.OFFLINE, store.releases["1"]?.attempt?.state)
        assertEquals(1, port.addCalls.size)

        clockMs += 5 * hour
        assertEquals(0, adder.sweep()); assertEquals(1, port.addCalls.size)

        clockMs += 2 * hour
        port.offline = false
        port.next = ReleaseAddReport("confirmed (web)", true, null)
        assertEquals(1, adder.sweep()); assertEquals(2, port.addCalls.size)
        assertEquals(LikeAddState.ADDED, store.releases["1"]?.attempt?.state)

        clockMs += 10 * hour
        assertEquals(0, adder.sweep())
    }

    @Test fun sweepNeverRetriesFailedItems() = runBlocking {
        val port = FakePort().apply { next = fail() }
        val (adder, _, store) = make(port)
        adder.liked(entry("1"))?.join()
        assertEquals(LikeAddState.FAILED, store.releases["1"]?.attempt?.state)
        clockMs += 48 * hour
        assertEquals(0, adder.sweep()); assertEquals(1, port.addCalls.size)
    }

    @Test fun sweepSkipsAnItemHeNoLongerLikes() = runBlocking {
        val port = FakePort().apply { next = fail(); offline = true }
        val (adder, _, _) = make(port)
        adder.liked(entry("1"))?.join()
        adder.acceptedProvider = { emptyMap() }
        clockMs += 8 * hour
        assertEquals(0, adder.sweep())
    }

    @Test fun preOrderIsAwaitingThenAddedOnReleaseDay() = runBlocking {
        val port = FakePort().apply { next = ReleaseAddReport("confirmed (web)", recorded = false, error = null) }
        val (adder, _, store) = make(port)
        adder.liked(entry("1", at = clockMs + 3 * day))?.join()
        assertEquals(LikeAddState.AWAITING_RELEASE, store.releases["1"]?.attempt?.state)
        assertTrue(store.releases["1"]?.attempt?.writeProven == true)

        clockMs += 2 * day
        assertEquals(0, adder.sweep()); assertEquals(1, port.addCalls.size)

        clockMs += 1.5 * day
        port.next = ReleaseAddReport("confirmed (web)", recorded = true, error = null)
        assertEquals(1, adder.sweep()); assertEquals(2, port.addCalls.size)
        assertEquals(LikeAddState.ADDED, store.releases["1"]?.attempt?.state)
    }

    @Test fun sweepPrunesRowsWhoseVerdictIsGone() = runBlocking {
        val (adder, _, store) = make()
        store.upsert(listOf(LikedRelease("1"), LikedRelease("2")))
        adder.acceptedProvider = { mapOf("rel:2" to 1.0) }
        adder.sweep()
        assertEquals(setOf("2"), store.releases.keys)
    }

    // ---- Add all ----

    @Test fun addAllRunsOneAtATimeAndSkipsOwned() = runBlocking {
        val (adder, port, store) = make()
        store.upsert(listOf("1", "2", "3", "4").map { LikedRelease(it) })
        adder.isOwned = { it.storeId == "3" }
        adder.addAll(listOf("1", "2", "3", "4"))
        assertEquals(listOf("1", "2", "4"), port.addCalls)
        assertEquals(1, port.maxConcurrent)
        assertFalse(adder.busy.value.addingAll)
        assertTrue(adder.busy.value.queued.isEmpty())
    }

    @Test fun addAllSkipsRowsUnlikedWhileWaiting() = runBlocking {
        val (adder, port, store) = make()
        store.upsert(listOf(LikedRelease("1"), LikedRelease("2")))
        adder.acceptedProvider = { mapOf("rel:1" to 1.0) }
        adder.addAll(listOf("1", "2"))
        assertEquals(listOf("1"), port.addCalls)
    }

    // ---- persistence ----

    @Test fun interruptedAddingBecomesOfflineAfterReload() {
        val f = File.createTempFile("pdj-adder", ".json").also { it.deleteOnExit() }
        val a = LikedReleasesStore(f)
        a.upsert(LikedRelease("1"))
        a.setAttempt("1", LikeAddAttempt(1.0, LikeAddState.ADDING))
        val b = LikedReleasesStore(f)
        assertEquals(LikeAddState.OFFLINE, b.releases["1"]?.attempt?.state)
        assertEquals(NewReleaseLikeAdder.OFFLINE_MESSAGE, b.releases["1"]?.attempt?.message)
    }

    // ---- hydration ----

    private class Stub(override val canSync: Boolean, val body: String) : ReleaseFeedTransport {
        override suspend fun fetch(url: String): String = body
    }

    @Test fun hydrateMissingFetchesOnlyUnknownIdsAndTombstonesTheRest() = runBlocking {
        val t = Stub(true, """{"data":[{"id":"2","attributes":{"name":"Two","artistName":"B"}}]}""")
        val (adder, _, store) = make(transport = t)
        store.upsert(LikedRelease("1"))
        val n = adder.hydrateMissing(mapOf("rel:1" to 1.0, "rel:2" to 2.0, "rel:3" to 3.0, "relartist:9" to 4.0))
        assertEquals(2, n)
        assertEquals("Two", store.releases["2"]?.title)
        assertEquals(2.0, store.releases["2"]?.likedAtMs)
        assertEquals(true, store.releases["3"]?.tombstoned)
        assertNull(store.releases["9"])
    }

    @Test fun hydrateIsInertWithoutAnAuthorizedTransport() = runBlocking {
        val (adder, _, store) = make()
        assertEquals(0, adder.hydrateMissing(mapOf("rel:5" to 1.0)))
        val (adder2, _, store2) = make(transport = Stub(false, "{}"))
        assertEquals(0, adder2.hydrateMissing(mapOf("rel:5" to 1.0)))
        assertTrue(store.releases.isEmpty() && store2.releases.isEmpty())
    }

    // ---- the outcome table (pure) ----

    @Test fun outcomeTableEveryRow() {
        val now = 1_000.0; val past = 500.0; val future = 5_000.0
        fun s(r: ReleaseAddReport, at: Double? = past, offline: Boolean = false, canWrite: Boolean = true) =
            NewReleaseLikeAdder.state(r, at, now, offline, canWrite)
        // recorded + proven
        assertEquals(LikeAddState.ADDED, s(ReleaseAddReport("confirmed (web)", true, null)).state)
        assertEquals(LikeAddState.ADDED, s(ReleaseAddReport("confirmed", true, null)).state)
        // recorded + skip on a device that cannot write at all
        assertEquals(LikeAddState.ADDED, s(ReleaseAddReport("Apple Music write skipped: no Apple Music connection", true, null), canWrite = false).state)
        // recorded + unproven (failed / skipped-but-could-write / legacy null)
        for (tok in listOf("Apple Music write failed: x", "Apple Music write skipped: no Apple Music connection", null)) {
            val o = s(ReleaseAddReport(tok, true, "notice"))
            assertEquals(LikeAddState.FAILED, o.state); assertEquals("notice", o.message)
        }
        // nothing recorded: pre-order (write landed or not)
        assertEquals(LikeAddState.AWAITING_RELEASE, s(ReleaseAddReport("confirmed (web)", false, null), at = future).state)
        assertEquals(LikeAddState.AWAITING_RELEASE, s(ReleaseAddReport("Apple Music write failed: x", false, "e"), at = future).state)
        // nothing recorded: offline
        val off = s(ReleaseAddReport(null, false, "e"), offline = true)
        assertEquals(LikeAddState.OFFLINE, off.state); assertEquals(NewReleaseLikeAdder.OFFLINE_MESSAGE, off.message)
        // nothing recorded: real failure
        val bad = s(ReleaseAddReport("confirmed (web)", false, "Couldn’t read the album’s tracks — try again."))
        assertEquals(LikeAddState.FAILED, bad.state)
        assertEquals("Couldn’t read the album’s tracks — try again.", bad.message)
        // an unknown release date is not a pre-order
        assertEquals(LikeAddState.FAILED, s(ReleaseAddReport("confirmed (web)", false, null), at = null).state)
    }

    @Test fun wordingMatchesTheAlbumPage() {
        assertNull(LikeAddWording.libraryNotice("confirmed (web)"))
        assertEquals("Added to PocketDJ, but the Apple Music library add failed: nope", LikeAddWording.libraryNotice("Apple Music write failed: nope"))
        assertEquals("Added to PocketDJ only — no Apple Music connection.", LikeAddWording.libraryNotice("Apple Music write skipped: no Apple Music connection"))
    }
}

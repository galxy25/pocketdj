package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.applemusic.AppleMusicAlbumRef
import com.levi.pocketdj.data.discover.DiscoverAddState
import com.levi.pocketdj.data.recs.AlbumOwnership
import com.levi.pocketdj.data.rips.RipJob
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AlbumPreviewControllerTest {

    private fun row(id: String, n: Int = 1) = AlbumTrackRow(id, "T$id", "A", n)

    // ---- ownership states -------------------------------------------------------------------

    @Test fun ownershipDrivesTheAddWording() {
        val tracks = listOf(row("1"), row("2"), row("3"))
        val none = OwnedSets().ownershipOf(tracks)
        assertEquals(AlbumOwnership.None(3), none)
        assertEquals("Add album to your library", none.addTitle)

        // one track by provisional id, one by an indexed song claiming the Apple Music id
        val partial = OwnedSets(catalogSongIds = setOf("amrec_1"), catalogAppleMusicIds = setOf("2")).ownershipOf(tracks)
        assertEquals(AlbumOwnership.Partial(2, 3), partial)
        assertEquals("Add remaining (1)", partial.addTitle)

        val owned = OwnedSets(rippedSongIds = setOf("amrec_1", "amrec_2", "amrec_3")).ownershipOf(tracks)
        assertEquals(AlbumOwnership.Owned(3), owned)
        assertEquals("In your library", owned.addTitle)
    }

    @Test fun perRowTickUsesTheSameOracle() {
        val sets = OwnedSets(catalogAppleMusicIds = setOf("2"))
        assertFalse(sets.owns("1"))
        assertTrue(sets.owns("2"))
    }

    @Test fun addModeIsDecidedOnlyByOwnershipAndRecordedAdd() {
        val tracks = listOf(row("1"), row("2"))
        val none = OwnedSets().ownershipOf(tracks)
        val partial = OwnedSets(catalogAppleMusicIds = setOf("1")).ownershipOf(tracks)
        val owned = OwnedSets(catalogAppleMusicIds = setOf("1", "2")).ownershipOf(tracks)

        assertEquals(AlbumAddMode.Add("Add album to your library"), AlbumPreviewPresentation.addMode(none, null, false, false))
        assertEquals(AlbumAddMode.Add("Add remaining (1)"), AlbumPreviewPresentation.addMode(partial, null, false, false))
        assertEquals(AlbumAddMode.Owned, AlbumPreviewPresentation.addMode(owned, null, false, false))
        // The catalog holds the album but the tracklist could not expand: still "owned", never an add.
        assertEquals(AlbumAddMode.Owned, AlbumPreviewPresentation.addMode(AlbumOwnership.None(0), null, true, true))
        // ...whereas an album we simply could not expand AND do not own keeps the add.
        assertEquals(AlbumAddMode.Add("Add album to your library"), AlbumPreviewPresentation.addMode(AlbumOwnership.None(0), null, false, true))
        // A recorded add wins over everything (live n/m).
        val rec = DiscoverAddState.Adding(1, 2)
        assertEquals(AlbumAddMode.Recorded(rec), AlbumPreviewPresentation.addMode(none, rec, false, false))
    }

    @Test fun openAlbumOnlyWhenCatalogHasIt() {
        assertTrue(AlbumPreviewPresentation.showOpenAlbum("alb_1"))
        assertFalse(AlbumPreviewPresentation.showOpenAlbum(null))
    }

    @Test fun runtimeFormatting() {
        assertEquals("3:05", AlbumPreviewPresentation.runtime(185.0))
        assertEquals("1:02:03", AlbumPreviewPresentation.runtime(3723.0))
        assertEquals("", AlbumPreviewPresentation.runtime(0.0))
        assertEquals("", AlbumPreviewPresentation.runtime(Double.NaN))
    }

    // ---- download state reducer -------------------------------------------------------------

    @Test fun downloadStateReducer() {
        val ids = listOf("a", "b", "c")
        assertEquals(AlbumDownloadState.Idle, AlbumDownloadState.of(emptyList(), emptySet(), emptyMap()))
        assertEquals(AlbumDownloadState.Working(1, 3), AlbumDownloadState.of(ids, setOf("a"), emptyMap()))
        assertEquals(AlbumDownloadState.Done(3), AlbumDownloadState.of(ids, ids.toSet(), emptyMap()))
        val failed = AlbumDownloadState.of(ids, setOf("a"), mapOf("b" to "no media", "c" to "x"))
        assertEquals(AlbumDownloadState.Failed(1, 3, "no media"), failed)
        assertEquals("1/3 downloaded — no media", failed.label)
        assertEquals("no media", AlbumDownloadState.of(listOf("a"), emptySet(), mapOf("a" to "no media")).label)
        assertEquals("Downloading… 1/3", AlbumDownloadState.Working(1, 3).label)
        assertTrue(AlbumDownloadState.Idle.isTappable)
        assertTrue(failed.isTappable)
        assertFalse(AlbumDownloadState.Working(0, 3).isTappable)
        assertFalse(AlbumDownloadState.Done(3).isTappable)
    }

    // ---- fakes ------------------------------------------------------------------------------

    private class FakeMeta(
        var server: Boolean = true,
        var offline: Boolean = false,
        var tier1: List<DiscoverAlbumTrack> = emptyList(),
        var tier2: DiscoverAlbumExpansion = DiscoverAlbumExpansion.EMPTY,
        var addResult: DiscoverAddOutcome = DiscoverAddOutcome(true, LibraryWrite.CONFIRMED_WEB),
    ) : AlbumPreviewPort {
        var adds = 0
        override suspend fun hasServer() = server
        override suspend fun canAddToLibrary() = true
        override suspend fun isOffline() = offline
        override suspend fun catalogTracks(albumStoreId: String) = tier1
        override suspend fun expansion(albumStoreId: String) = tier2
        override suspend fun addAlbum(hit: DiscoverAlbumHit): DiscoverAddOutcome { adds++; return addResult }
    }

    /** Jobs land after [readyAfterFetches] fetches (per job), except ids in [failing]. */
    private class FakeDl(val readyAfterFetches: Int = 2, val failing: Set<String> = emptySet()) : AlbumDownloadPort {
        val requested = mutableListOf<String>()
        val fetches = mutableListOf<String>()
        val onDeviceIds = HashSet<String>()
        private val counts = HashMap<String, Int>()
        var landedBatches = 0
        override suspend fun configured() = true
        override suspend fun request(track: DownloadTrack): RipJob? {
            requested += track.songId
            return RipJob(phase = "queued", jobId = "job-${track.songId}", songId = track.songId)
        }
        override suspend fun fetchJob(jobId: String): RipJob? {
            fetches += jobId
            val id = jobId.removePrefix("job-")
            val n = (counts[jobId] ?: 0) + 1
            counts[jobId] = n
            return when {
                id in failing -> RipJob(phase = RipJob.PHASE_ERROR, jobId = jobId, error = "no media for $id")
                n >= readyAfterFetches -> RipJob(phase = RipJob.PHASE_READY, jobId = jobId, url = "https://x/$id.mp3")
                else -> RipJob(phase = "ripping", jobId = jobId)
            }
        }
        override suspend fun ripsLanded(songIds: List<String>) { landedBatches++; onDeviceIds += songIds }
        override fun onDevice(songId: String) = songId in onDeviceIds
        override fun burnError(songId: String): String? = null
    }

    private fun tracks(vararg ids: String) = ids.map { DownloadTrack(it, "T$it", "A", it, 180_000) }

    private fun TestScope.controller(dl: FakeDl, meta: FakeMeta = FakeMeta()) =
        AlbumPreviewController(backgroundScope, meta, dl, pollMs = 1_000, maxTicks = 100)

    // ---- ONE shared poll loop ---------------------------------------------------------------

    @Test fun twoAlbumsShareOneLoopAndItExitsWhenIdle() = runTest(StandardTestDispatcher()) {
        val dl = FakeDl(readyAfterFetches = 2)
        val c = controller(dl)
        c.download("albumA", tracks("1", "2"))
        c.download("albumB", tracks("3"))
        runCurrent()
        assertEquals(1, c.loopStarts)
        assertEquals(listOf("1", "2", "3"), dl.requested) // ordered requests: the ripper is concurrency-1

        advanceTimeBy(1_001); runCurrent()
        // tick 1: every outstanding job fetched exactly once by the single loop
        assertEquals(listOf("job-1", "job-2", "job-3"), dl.fetches)
        assertTrue(c.downloads.value["albumA"] is AlbumDownloadState.Working)

        advanceTimeBy(1_000); runCurrent()
        assertEquals(AlbumDownloadState.Done(2), c.downloads.value["albumA"])
        assertEquals(AlbumDownloadState.Done(1), c.downloads.value["albumB"])
        assertEquals(1, c.loopStarts) // never a second loop
        assertEquals(1, dl.landedBatches) // manifest refreshed once for the whole tick, not per track
        val fetchesAtIdle = dl.fetches.size
        advanceTimeBy(10_000); runCurrent()
        assertEquals("an idle loop must stop polling", fetchesAtIdle, dl.fetches.size)

        // a later download starts a fresh loop (the first one exited)
        c.download("albumC", tracks("9")); runCurrent()
        assertEquals(2, c.loopStarts)
    }

    @Test fun tappingDownloadWhileWorkingIsANoOp() = runTest(StandardTestDispatcher()) {
        val dl = FakeDl(readyAfterFetches = 3)
        val c = controller(dl)
        assertNotNull(c.download("alb", tracks("1", "2")))
        runCurrent()
        assertNull(c.download("alb", tracks("1", "2")))
        runCurrent()
        assertEquals(listOf("1", "2"), dl.requested)
        assertEquals(1, c.loopStarts)
    }

    @Test fun downloadProgressesWithoutAnyScreenCollecting() = runTest(StandardTestDispatcher()) {
        // The controller owns the task: nothing here observes `downloads` until the end (the screen was dismissed).
        val dl = FakeDl(readyAfterFetches = 1)
        val c = controller(dl)
        c.download("alb", tracks("1", "2", "3"))
        runCurrent(); advanceTimeBy(1_001); runCurrent()
        assertEquals(AlbumDownloadState.Done(3), c.downloads.value["alb"])
        assertEquals(setOf("1", "2", "3"), dl.onDeviceIds)
    }

    @Test fun alreadyRippedTrackIsBurnedWithoutPolling() = runTest(StandardTestDispatcher()) {
        val dl = object : AlbumDownloadPort by FakeDl() {
            val landed = mutableSetOf<String>()
            override suspend fun request(track: DownloadTrack) = RipJob(phase = RipJob.PHASE_READY, url = "https://x/a.mp3")
            override suspend fun ripsLanded(songIds: List<String>) { landed += songIds }
            override fun onDevice(songId: String) = songId in landed
        }
        val c = AlbumPreviewController(backgroundScope, FakeMeta(), dl, pollMs = 1_000)
        c.download("alb", tracks("1")); runCurrent()
        assertEquals(AlbumDownloadState.Done(1), c.downloads.value["alb"])
    }

    @Test fun failedTrackSettlesAlbumAndRetryRequestsOnlyThatTrack() = runTest(StandardTestDispatcher()) {
        val dl = FakeDl(readyAfterFetches = 1, failing = setOf("2"))
        val c = controller(dl)
        c.download("alb", tracks("1", "2")); runCurrent()
        advanceTimeBy(1_001); runCurrent()
        assertEquals(AlbumDownloadState.Failed(1, 2, "no media for 2"), c.downloads.value["alb"])

        val dl2requestedBefore = dl.requested.size
        c.download("alb", tracks("1", "2")); runCurrent()
        assertEquals("track 1 is already on device and is not re-requested", listOf("2"), dl.requested.drop(dl2requestedBefore))
    }

    @Test fun unrequestableTrackFailsWithoutStallingTheLoop() = runTest(StandardTestDispatcher()) {
        val dl = object : AlbumDownloadPort by FakeDl() {
            override suspend fun request(track: DownloadTrack): RipJob? = null
        }
        val c = AlbumPreviewController(backgroundScope, FakeMeta(), dl, pollMs = 1_000)
        c.download("alb", tracks("1")); runCurrent()
        assertEquals(AlbumDownloadState.Failed(0, 1, "Couldn’t request a copy"), c.downloads.value["alb"])
    }

    // ---- store-owned add --------------------------------------------------------------------

    @Test fun addIsSingleFlightAndRecordsFailure() = runTest(StandardTestDispatcher()) {
        val meta = FakeMeta(addResult = DiscoverAddOutcome(false, LibraryWrite.SKIPPED_NO_CONNECTION, "Nope"))
        val c = controller(FakeDl(), meta)
        val hit = DiscoverAlbumHit(appleMusicId = "77", title = "Rec", artist = "Art")
        assertNotNull(c.addAlbum(hit))
        assertNull("second tap while adding is ignored", c.addAlbum(hit))
        runCurrent()
        assertEquals(1, meta.adds)
        assertEquals(AlbumAddUi(adding = false, error = "Nope"), c.adds.value["77"])
    }

    // ---- tiers ------------------------------------------------------------------------------

    @Test fun tier1WinsAndKeepsTheRef() = runTest {
        val meta = FakeMeta(tier1 = listOf(DiscoverAlbumTrack("1", "One", "A", 1, 1, 1000)))
        val ref = AppleMusicAlbumRef("77", "Rec", "Art", 2026)
        val load = controller(FakeDl(), meta).load(ref)
        assertEquals(ref, load.album)
        assertEquals(listOf(AlbumTrackRow("1", "One", "A", 1, 1, 1000)), load.tracks)
        assertNull(load.unavailable)
    }

    @Test fun tier2FillsATracklistAndABareRef() = runTest {
        val meta = FakeMeta(
            tier2 = DiscoverAlbumExpansion(
                DiscoverAlbumHit(appleMusicId = "77", title = "Real Title", artist = "Real Artist", year = 2025, artworkUrl = "u"),
                listOf(DiscoverAlbumTrack("5", "Five", "Real Artist", trackNumber = 5)),
            ),
        )
        val load = controller(FakeDl(), meta).load(AppleMusicAlbumRef("77", "Album", ""))
        assertEquals("Real Title", load.album.title)
        assertEquals("Real Artist", load.album.artist)
        assertEquals(2025, load.album.year)
        assertEquals(listOf("5"), load.tracks.map { it.storeId })
    }

    @Test fun nothingToExpandNamesTheReason() = runTest {
        val ref = AppleMusicAlbumRef("77", "Rec", "Art")
        assertEquals(AlbumPreviewUnavailable.NotFound, controller(FakeDl(), FakeMeta(server = true)).load(ref).unavailable)
        assertEquals(AlbumPreviewUnavailable.NoServer, controller(FakeDl(), FakeMeta(server = false)).load(ref).unavailable)
        assertEquals(AlbumPreviewUnavailable.Offline, controller(FakeDl(), FakeMeta(offline = true)).load(ref).unavailable)
        assertTrue(controller(FakeDl(), FakeMeta()).load(ref).tracks.isEmpty())
    }

    @Test fun portFailuresDegradeInsteadOfThrowing() = runTest {
        val boom = object : AlbumPreviewPort by FakeMeta() {
            override suspend fun catalogTracks(albumStoreId: String): List<DiscoverAlbumTrack> = error("net")
            override suspend fun expansion(albumStoreId: String): DiscoverAlbumExpansion = error("net")
        }
        val load = AlbumPreviewController(backgroundScope, boom, FakeDl()).load(AppleMusicAlbumRef("1", "T", "A"))
        assertEquals(AlbumPreviewUnavailable.NotFound, load.unavailable)
    }

    // ---- router -----------------------------------------------------------------------------

    @Test fun routerDeliversTheAlbumAndRejectsBlankIds() = runTest(StandardTestDispatcher()) {
        var got: AppleMusicAlbumRef? = null
        val j = launch { got = StoreAlbumRouter.events.first() }
        runCurrent()
        assertFalse(StoreAlbumRouter.open(AppleMusicAlbumRef("", "x", "y")))
        assertTrue(StoreAlbumRouter.open(DiscoverAlbumHit(appleMusicId = "55", title = "T", artist = "A", year = 2024)))
        runCurrent()
        assertEquals("55", got?.storeId)
        assertEquals(2024, got?.year)
        j.cancel()
    }
}

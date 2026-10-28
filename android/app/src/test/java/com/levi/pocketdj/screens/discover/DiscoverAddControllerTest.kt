package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.discover.DiscoverAddState
import com.levi.pocketdj.data.discover.DiscoverAddsStore
import com.levi.pocketdj.data.rips.RipJob
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DiscoverAddControllerTest {
    @get:Rule val tmp = TemporaryFolder()

    private class FakeRips(var server: Boolean = true) : DiscoverRipPort {
        val requested = mutableListOf<String>()
        val watched = mutableListOf<Pair<String, String>>()
        var manifestRefreshes = 0
        var serverTracks: List<DiscoverAlbumTrack> = emptyList()
        var outcome: (String) -> DiscoverRipOutcome = { DiscoverRipOutcome.Queued("job-$it") }
        override suspend fun configured() = server
        override suspend fun request(songId: String, title: String, artist: String, appleMusicId: String, lengthMs: Int?): DiscoverRipOutcome {
            requested += songId
            return if (!server) DiscoverRipOutcome.NoServer else outcome(songId)
        }
        override suspend fun serverAlbumTracks(collectionId: String) = serverTracks
        override fun watch(songId: String, jobId: String) { watched += songId to jobId }
        override suspend fun refreshManifest() { manifestRefreshes++ }
    }

    private class FakeLibrary(var token: String = "confirmed (web)", var restTracks: List<DiscoverAlbumTrack> = emptyList()) : DiscoverLibraryPort {
        val songs = mutableListOf<String>(); val albums = mutableListOf<String>()
        override suspend fun addSong(appleMusicId: String): String { songs += appleMusicId; return token }
        override suspend fun addAlbum(appleMusicId: String): String { albums += appleMusicId; return token }
        override suspend fun albumTracks(appleMusicId: String) = restTracks
    }

    private fun store() = DiscoverAddsStore(File(tmp.root, "d.json"))
    private fun hit(id: String = "11") = DiscoverHit(appleMusicId = id, title = "Song $id", artist = "Art", album = "Alb", durationMs = 1000, albumAppleMusicId = "77", trackNumber = 2)
    private fun albumHit() = DiscoverAlbumHit(appleMusicId = "77", albumId = "amrec_album_77", title = "Alb", artist = "Art", year = 2020, trackCount = 3)
    private fun tracks(n: Int) = (1..n).map { DiscoverAlbumTrack(id = "t$it", title = "Track $it", artist = "Art", discNumber = 1, trackNumber = it, durationMs = 1000) }

    @Test fun songAddRecordsProvisionalRowAfterServerAcceptsAndPolls() = runBlocking {
        val s = store(); val rips = FakeRips(); val lib = FakeLibrary()
        val logged = mutableListOf<String?>()
        s.onUserCatalogAdd = { _, lw -> logged += lw }
        val out = DiscoverAddController(s, rips, lib).addSong(hit())
        assertTrue(out.accepted)
        assertEquals(listOf("11"), lib.songs)
        assertEquals(listOf("amrec_11"), rips.requested)
        assertEquals(listOf("amrec_11" to "job-amrec_11"), rips.watched)
        val row = s.entry("amrec_11")!!
        assertEquals("11", row.appleMusicId); assertEquals("77", row.albumAppleMusicId); assertEquals(2, row.trackNumber)
        assertNull("a song-scope add records NO provisional album", row.albumId)
        assertEquals("confirmed (web)", row.libraryWrite)
        assertEquals(listOf<String?>("confirmed (web)"), logged)
    }

    @Test fun songAddRejectedByServerRecordsNothing() = runBlocking {
        val s = store(); val rips = FakeRips().apply { outcome = { DiscoverRipOutcome.Failed } }
        val out = DiscoverAddController(s, rips, FakeLibrary()).addSong(hit())
        assertFalse(out.accepted)
        assertEquals(DiscoverAddWording.ADD_FAILED, out.error)
        assertTrue(s.entries.isEmpty())
    }

    @Test fun songAddWithoutServerStillBecomesACatalogCitizen() = runBlocking {
        val s = store()
        val out = DiscoverAddController(s, FakeRips(server = false), FakeLibrary(token = "Apple Music write skipped: no Apple Music connection")).addSong(hit())
        assertTrue(out.accepted)
        assertEquals("Apple Music write skipped: no Apple Music connection", s.entry("amrec_11")?.libraryWrite) // truthful, not "confirmed"
    }

    @Test fun readyServerAnswerRefreshesTheManifestInsteadOfPolling() = runBlocking {
        val rips = FakeRips().apply { outcome = { DiscoverRipOutcome.Ready } }
        DiscoverAddController(store(), rips, FakeLibrary()).addSong(hit())
        assertEquals(1, rips.manifestRefreshes); assertTrue(rips.watched.isEmpty())
    }

    @Test fun albumFanOutRecordsOnlyAcceptedTracksInOneBatch() = runBlocking {
        val s = store()
        val rips = FakeRips().apply {
            serverTracks = tracks(4)
            outcome = { if (it == "amrec_t3") DiscoverRipOutcome.Failed else DiscoverRipOutcome.Queued("j") }
        }
        var changed = 0
        s.onChanged = { changed++ }
        val out = DiscoverAddController(s, rips, FakeLibrary()).addAlbum(albumHit(), AlbumAddIntent.AND_PREPARE_COPIES)
        assertTrue(out.accepted)
        assertEquals("every track was asked", 4, rips.requested.size)
        val album = s.albums.single()
        assertEquals(listOf("amrec_t1", "amrec_t2", "amrec_t4"), album.trackIds)
        assertEquals(listOf("amrec_t1", "amrec_t2", "amrec_t4"), s.entries.map { it.songId })
        assertEquals("one catalog rebuild per album, not per track", 1, changed)
        assertTrue(s.entries.all { it.albumId == "amrec_album_77" && it.albumAppleMusicId == "77" && it.year == 2020 })
        assertEquals(listOf(1, 2, 4), s.entries.map { it.trackNumber })
        assertEquals(true, album.preparedCopies)
        assertEquals("the catalog's promise (hit.trackCount) is kept", 3, album.trackCount)
    }

    @Test fun libraryOnlyAlbumRequestsNoRipsAndNeverSpins() = runBlocking {
        val s = store(); val rips = FakeRips()
        val lib = FakeLibrary(restTracks = tracks(3))
        val out = DiscoverAddController(s, rips, lib).addAlbum(albumHit(), AlbumAddIntent.LIBRARY_ONLY)
        assertTrue(out.accepted)
        assertTrue(rips.requested.isEmpty())
        assertEquals(3, s.entries.size)
        assertEquals(false, s.albums.single().preparedCopies)
        assertEquals(DiscoverAddState.Added, DiscoverAddState.of(s.albums.single(), emptySet(), emptySet()))
    }

    @Test fun serverlessDownloadIntentAlsoDoesNotSpin() = runBlocking {
        val s = store()
        val lib = FakeLibrary(restTracks = tracks(2))
        DiscoverAddController(s, FakeRips(server = false), lib).addAlbum(albumHit(), AlbumAddIntent.AND_PREPARE_COPIES)
        assertEquals("no capture can ever land", false, s.albums.single().preparedCopies)
    }

    @Test fun restTracksLeadAndServerIsTheFallback() = runBlocking {
        val s = store()
        val rips = FakeRips().apply { serverTracks = tracks(5) }
        DiscoverAddController(s, rips, FakeLibrary(restTracks = tracks(2))).addAlbum(albumHit(), AlbumAddIntent.LIBRARY_ONLY)
        assertEquals(2, s.entries.size)
        val s2 = DiscoverAddsStore(File(tmp.root, "d2.json"))
        DiscoverAddController(s2, rips, FakeLibrary()).addAlbum(albumHit(), AlbumAddIntent.LIBRARY_ONLY)
        assertEquals(5, s2.entries.size)
    }

    @Test fun albumWithNoReadableTracksOrNoAcceptedTrackRecordsNothing() = runBlocking {
        val s = store()
        val none = DiscoverAddController(s, FakeRips(), FakeLibrary()).addAlbum(albumHit(), AlbumAddIntent.AND_PREPARE_COPIES)
        assertFalse(none.accepted); assertNotNull(none.error)
        val rejecting = FakeRips().apply { serverTracks = tracks(2); outcome = { DiscoverRipOutcome.Failed } }
        val all = DiscoverAddController(s, rejecting, FakeLibrary()).addAlbum(albumHit(), AlbumAddIntent.AND_PREPARE_COPIES)
        assertFalse(all.accepted)
        assertTrue(s.entries.isEmpty() && s.albums.isEmpty())
    }

    @Test fun albumStatesSettleToPartialWhenARipDies() = runBlocking {
        val s = store(); val rips = FakeRips().apply { serverTracks = tracks(3) }
        val c = DiscoverAddController(s, rips, FakeLibrary())
        c.addAlbum(albumHit(), AlbumAddIntent.AND_PREPARE_COPIES)
        val ready = MutableStateFlow(setOf("amrec_t1")); val errored = MutableStateFlow(emptySet<String>())
        val flow = c.albumStates(ready, errored)
        assertEquals(DiscoverAddState.Adding(1, 3), flow.first()["amrec_album_77"])
        ready.value = setOf("amrec_t1", "amrec_t2"); errored.value = setOf("amrec_t3")
        assertEquals(DiscoverAddState.Partial(2, 3), flow.first()["amrec_album_77"])
        errored.value = emptySet(); ready.value = setOf("amrec_t1", "amrec_t2", "amrec_t3")
        assertEquals(DiscoverAddState.Added, flow.first()["amrec_album_77"])
    }

    @Test fun removeFromLibraryDropsLogsAndIgnoresRealSources() = runBlocking {
        val s = store(); val c = DiscoverAddController(s, FakeRips(), FakeLibrary())
        c.addSong(hit())
        val removed = mutableListOf<String>()
        c.onUserCatalogRemove = { removed += it.id }
        assertFalse("real sources are not user-removable", c.removeFromLibrary("amrec_11", "Apple Music", "t", "a"))
        assertTrue(c.removeFromLibrary("amrec_11", "Discover", "t", "a"))
        assertEquals(listOf("amrec_11"), removed)
        assertTrue(s.entries.isEmpty())
        assertFalse(c.removeFromLibrary("amrec_11", "Discover", "t", "a"))
        // Imported rows go through the supplied remover with the catalog's title.
        val gone = mutableListOf<String>()
        assertTrue(c.removeFromLibrary("amrec_5", "Imported", "Imp", "Z") { gone += it })
        assertEquals(listOf("amrec_11", "amrec_5"), removed); assertEquals(listOf("amrec_5"), gone)
    }

    @Test fun removableSourcesAreDiscoverAndImportedOnly() {
        assertTrue(isRemovableFromLibrary("Discover")); assertTrue(isRemovableFromLibrary("Imported"))
        assertFalse(isRemovableFromLibrary("Apple Music")); assertFalse(isRemovableFromLibrary(null))
    }

    @Test fun ripJobViewMapsToOutcome() {
        assertEquals(DiscoverRipOutcome.Ready, DiscoverAddController.outcomeOf(RipJob(phase = "ready", url = "u")))
        assertEquals(DiscoverRipOutcome.Failed, DiscoverAddController.outcomeOf(RipJob(phase = "error", error = "x")))
        assertEquals(DiscoverRipOutcome.Queued("j1"), DiscoverAddController.outcomeOf(RipJob(phase = "queued", jobId = "j1")))
    }
}

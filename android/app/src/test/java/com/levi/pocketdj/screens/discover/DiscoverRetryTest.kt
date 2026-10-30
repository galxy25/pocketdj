package com.levi.pocketdj.screens.discover

import com.levi.pocketdj.data.discover.DiscoverAddsStore
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DiscoverRetryTest {
    @get:Rule val tmp = TemporaryFolder()
    private val day = DiscoverAddsStore.REFRESH_INTERVAL_MS

    private class Rips(var expansion: DiscoverAlbumExpansion) : DiscoverRipPort {
        val requested = mutableListOf<String>()
        var expansionCalls = 0
        override suspend fun configured() = true
        override suspend fun request(songId: String, title: String, artist: String, appleMusicId: String, lengthMs: Int?): DiscoverRipOutcome {
            requested += songId; return DiscoverRipOutcome.Ready
        }
        override suspend fun serverAlbumTracks(collectionId: String) = expansion.tracks
        override suspend fun albumExpansion(collectionId: String): DiscoverAlbumExpansion { expansionCalls++; return expansion }
        override fun watch(songId: String, jobId: String) {}
        override suspend fun refreshManifest() {}
    }

    private class Lib(var token: String) : DiscoverLibraryPort {
        var calls = 0
        override suspend fun addSong(appleMusicId: String) = token
        override suspend fun addAlbum(appleMusicId: String): String { calls++; return token }
        override suspend fun albumTracks(appleMusicId: String) = emptyList<DiscoverAlbumTrack>()
    }

    private fun store() = DiscoverAddsStore(File(tmp.root, "d.json"))
    private fun trk(i: Int, title: String = "Track $i") = DiscoverAlbumTrack("t$i", title, "Art", 1, i, 1000)
    private fun seedAlbum(s: DiscoverAddsStore, write: String? = null, trackCount: Int = 2, prepared: Boolean? = true) {
        val e = (1..2).map {
            DiscoverAddsStore.Entry(songId = "amrec_t$it", appleMusicId = "t$it", title = "Track $it", artist = "Art",
                album = "Alb", albumId = "amrec_album_77", albumAppleMusicId = "77", trackNumber = it, discNumber = 1)
        }
        s.addAlbumBatch(
            DiscoverAddsStore.AlbumEntry(albumId = "amrec_album_77", appleMusicId = "77", title = "Alb", artist = "Art",
                trackIds = e.map { it.songId }, trackCount = trackCount, libraryWrite = write, preparedCopies = prepared, addedAtMs = 1.0),
            e,
        )
    }

    // ---- retry gate + wording ----

    @Test fun retryOfferedUnlessProvenOrUnwritable() {
        assertTrue(AlbumLibraryWriteRetry.needsRetry(null, true))               // legacy nil proves nothing
        assertTrue(AlbumLibraryWriteRetry.needsRetry(LibraryWrite.failed("500"), true))
        assertTrue(AlbumLibraryWriteRetry.needsRetry(LibraryWrite.SKIPPED_NO_CONNECTION, true))
        assertFalse(AlbumLibraryWriteRetry.needsRetry(LibraryWrite.CONFIRMED_WEB, true))
        assertFalse("dead control when the device can't write", AlbumLibraryWriteRetry.needsRetry(null, false))
    }

    @Test fun noticeWording() {
        assertNull(AlbumLibraryWriteRetry.notice(LibraryWrite.CONFIRMED_WEB))
        assertTrue(AlbumLibraryWriteRetry.notice(LibraryWrite.failed("boom"))!!.endsWith("failed: boom"))
        assertTrue(AlbumLibraryWriteRetry.notice(LibraryWrite.SKIPPED_NO_CONNECTION)!!.contains("only"))
    }

    @Test fun retryHealsStoredTokenAndLogsOnceWhenProven() = runBlocking {
        val s = store(); seedAlbum(s, write = LibraryWrite.failed("HTTP 500"))
        val logged = mutableListOf<String?>()
        s.onUserCatalogAdd = { _, lw -> logged += lw }
        assertEquals(setOf("amrec_album_77"), AlbumLibraryWriteRetry.albumIdsNeedingRetry(s.albums, true))
        val lib = Lib(LibraryWrite.CONFIRMED_WEB)
        val c = DiscoverAddController(s, Rips(DiscoverAlbumExpansion.EMPTY), lib)
        assertEquals(LibraryWrite.CONFIRMED_WEB, c.retryAlbumLibraryWrite("amrec_album_77", "77"))
        assertEquals(LibraryWrite.CONFIRMED_WEB, s.albumEntry("amrec_album_77")!!.libraryWrite)
        assertTrue(AlbumLibraryWriteRetry.albumIdsNeedingRetry(s.albums, true).isEmpty())
        c.retryAlbumLibraryWrite("amrec_album_77", "77") // idempotent: no second log
        assertEquals(listOf<String?>(LibraryWrite.CONFIRMED_WEB), logged)
    }

    @Test fun failedRetryKeepsOfferingRetry() = runBlocking {
        val s = store(); seedAlbum(s, write = null)
        val c = DiscoverAddController(s, Rips(DiscoverAlbumExpansion.EMPTY), Lib(LibraryWrite.failed("429")))
        c.retryAlbumLibraryWrite("amrec_album_77", "77")
        assertEquals(LibraryWrite.failed("429"), s.albumEntry("amrec_album_77")!!.libraryWrite)
        assertTrue(AlbumLibraryWriteRetry.needsRetry(s.albumEntry("amrec_album_77")!!.libraryWrite, true))
    }

    // ---- pre-release refresh ----

    @Test fun needsRefreshRules() {
        fun e(t: String) = DiscoverAddsStore.Entry(songId = "a", title = t)
        val full = DiscoverAddsStore.AlbumEntry(albumId = "x", title = "Alb", trackCount = 1, releaseDateMs = 100.0, lastRefreshAtMs = 200.0)
        assertFalse("checked since release, complete", DiscoverAddsStore.needsRefresh(full, listOf(e("Real")), 10 * day))
        assertTrue("placeholder track", DiscoverAddsStore.needsRefresh(full, listOf(e("Track 3")), 10 * day + 200.0))
        assertTrue("fewer tracks than promised, due daily",
            DiscoverAddsStore.needsRefresh(full.copy(trackCount = 5, lastRefreshAtMs = 0.0), listOf(e("Real")), day))
        assertFalse("provisional but checked <24h ago",
            DiscoverAddsStore.needsRefresh(full.copy(trackCount = 5, lastRefreshAtMs = 1000.0, releaseDateMs = 500.0), listOf(e("Real")), 2000.0 + 0))
        assertTrue("release day passed since last check -> immediately",
            DiscoverAddsStore.needsRefresh(full.copy(trackCount = 5, lastRefreshAtMs = 1000.0, releaseDateMs = 1500.0), listOf(e("Real")), 2000.0))
        assertTrue(DiscoverAddsStore.needsRefresh(full.copy(title = "Sorry, we don't have an album title yet"), listOf(e("Real")), 200.0 + day))
    }

    @Test fun placeholderMatchers() {
        assertTrue(DiscoverAddsStore.isPlaceholderTitle(" track 16 "))
        assertFalse(DiscoverAddsStore.isPlaceholderTitle("Track Star"))
        assertTrue(DiscoverAddsStore.isPlaceholderAlbum("Sorry, we dont have an album title yet…"))
        assertFalse(DiscoverAddsStore.isPlaceholderAlbum("Sorry"))
    }

    @Test fun parseReleaseDate() {
        assertEquals(1_788_393_600_000.0, DiscoverAddController.parseReleaseDateMs("2026-09-03")!!, 0.0)
        assertEquals(1_788_393_600_000.0, DiscoverAddController.parseReleaseDateMs("2026-09-03T00:00:00Z")!!, 0.0)
        assertNull(DiscoverAddController.parseReleaseDateMs("soon"))
        assertNull(DiscoverAddController.parseReleaseDateMs(null))
    }

    @Test fun refreshRetitlesAppendsRequestsRipsAndStampsRelease() = runBlocking {
        val s = store(); seedAlbum(s, trackCount = 3)
        var rebuilt = 0; s.onChanged = { rebuilt++ }
        val album = DiscoverAlbumHit(appleMusicId = "77", title = "Real Title", artist = "Art", trackCount = 3, releaseDate = "2026-09-03")
        val rips = Rips(DiscoverAlbumExpansion(album, listOf(trk(1, "One"), trk(2, "Two"), trk(3, "Three"))))
        val c = DiscoverAddController(s, rips, Lib("x"))
        val now = 5_000_000_000_000.0
        assertEquals(1, c.refreshProvisionalAlbums(now))
        assertEquals(listOf("One", "Two", "Three"), listOf("amrec_t1", "amrec_t2", "amrec_t3").map { s.entry(it)!!.title })
        val a = s.albumEntry("amrec_album_77")!!
        assertEquals("Real Title", a.title)
        assertEquals(listOf("amrec_t1", "amrec_t2", "amrec_t3"), a.trackIds)
        assertEquals(now, a.lastRefreshAtMs!!, 0.0)
        assertNotNull(a.releaseDateMs)
        assertEquals(listOf("amrec_t3"), rips.requested)      // only the NEW track gets a rip
        assertEquals("Real Title", s.entry("amrec_t3")!!.album)
        assertEquals(1, rebuilt)
        // settled now: not due again within the day
        assertEquals(0, c.refreshProvisionalAlbums(now + 1000))
        assertEquals(1, rips.expansionCalls)
    }

    @Test fun refreshSkipsEmptyExpansionAndLibraryOnlyAlbumsDoNotRip() = runBlocking {
        val s = store(); seedAlbum(s, trackCount = 3, prepared = false)
        val rips = Rips(DiscoverAlbumExpansion.EMPTY)
        val c = DiscoverAddController(s, rips, Lib("x"))
        assertEquals(0, c.refreshProvisionalAlbums(5e12))
        assertNull("offline miss must not stamp lastRefresh", s.albumEntry("amrec_album_77")!!.lastRefreshAtMs)
        rips.expansion = DiscoverAlbumExpansion(null, listOf(trk(1, "One"), trk(2, "Two"), trk(3, "Three")))
        assertEquals(1, c.refreshProvisionalAlbums(5e12))
        assertTrue(rips.requested.isEmpty())
        assertNotNull(s.entry("amrec_t3"))
    }
}

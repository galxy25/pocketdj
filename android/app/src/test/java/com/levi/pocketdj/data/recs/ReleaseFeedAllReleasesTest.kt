package com.levi.pocketdj.data.recs

import com.levi.pocketdj.screens.foryou.NewReleaseKindFilter
import com.levi.pocketdj.screens.foryou.NewReleaseKinds
import com.levi.pocketdj.screens.foryou.kindClass
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/design/new-feed-all-releases.md: the feed keeps EVERY release in the window. */
class ReleaseFeedAllReleasesTest {
    private val day = 86_400_000.0
    private val now = 1_800_000_000_000.0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val tmp = kotlin.io.path.createTempDirectory("relfeed-all").toFile()
    private val file = File(tmp, ReleaseFeedService.FILE_NAME)

    @After fun cleanup() { scope.cancel(); tmp.deleteRecursively() }

    private class Routing(var batch: String = "{\"data\":[]}", var overflow: String? = null) : ReleaseFeedTransport {
        override val canSync = true
        val urls = ConcurrentLinkedQueue<String>()
        val calls = AtomicInteger(0)
        override suspend fun fetch(url: String): String {
            calls.incrementAndGet(); urls += url
            if ("/albums?" in url) return overflow ?: throw ReleaseFeedTransportError.Http(400)
            return batch
        }
    }

    private fun service(t: ReleaseFeedTransport?, f: File? = file) =
        ReleaseFeedService(t, f, scope, timeScale = 0.0, clock = { now }, random = { 0.0 })

    private fun iso(daysAgo: Double): String =
        Instant.ofEpochMilli((now - daysAgo * day).toLong()).atZone(ZoneOffset.UTC).toLocalDate().toString()

    private fun row(
        artist: Int, id: String, title: String, daysAgo: Double, kind: String = "album", name: String = "Artist $artist",
        explicit: Boolean? = null, credit: String? = null, tracks: Int? = null,
    ) = ArtistReleaseEntry(artist, name, now, id, title, now - daysAgo * day, null, kind, tracks, explicit, releaseArtistName = credit)

    private fun feed(vararg rows: ArtistReleaseEntry): ReleaseFeedService =
        service(null, null).also { it.seedForTesting(rows.toList()) }

    private suspend fun settle(svc: ReleaseFeedService, t: Routing) = withTimeout(10_000) {
        var last = -1; var stable = 0
        while (stable < 3) {
            delay(30)
            val n = t.calls.get()
            if (!svc.isFetchingNow && n == last) stable++ else stable = 0
            last = n
        }
    }

    // ---- the bug ------------------------------------------------------------------------------

    @Test fun albumThenNewerSingleYieldsTwoRowsAndAlbumsOnlyKeepsTheAlbum() {
        val svc = feed(row(1, "10", "Record", 10.0, tracks = 9), row(1, "11", "Hit - Single", 2.0, "single", tracks = 1))
        val items = svc.feed(now)
        assertEquals(listOf("rel:11", "rel:10"), items.map { it.id })
        val a = NewReleaseKinds.arrange(items, NewReleaseKindFilter.ALBUMS, { it.entry.kindClass })
        assertEquals(listOf("rel:10"), a.flat.map { it.id })
        assertEquals(1, a.hiddenSingles)
    }

    // ---- request + parse ----------------------------------------------------------------------

    @Test fun overflowUrlIsBuiltNotFollowed() {
        val u = ReleaseFeedService.overflowUrl(42)
        assertTrue(u, u.startsWith("https://api.music.apple.com/v1/catalog/us/artists/42/albums?sort=-releaseDate&offset=25&limit=100&fields%5Balbums%5D="))
    }

    @Test fun relationshipBodyFlattensDedupedWithCredit() {
        val body = """{"data":[{"id":"271256","attributes":{"name":"Drake"},"relationships":{"albums":{"data":[
          {"id":"3","attributes":{"name":"Ya Hit (feat. Drake) - Single","releaseDate":"2027-01-10","artistName":"Future","isSingle":true}},
          {"id":"2","attributes":{"name":"Habits - Single","releaseDate":"2027-01-05","artistName":"Drake","isSingle":true,"contentRating":"explicit"}},
          {"id":"2","attributes":{"name":"Habits - Single","releaseDate":"2027-01-05","artistName":"Drake","isSingle":true}},
          {"id":"1","attributes":{"name":"Big One","releaseDate":"2016","artistName":"Drake"}}]}},
          "views":{"latest-release":{"data":[{"id":"2","attributes":{"name":"Habits - Single"}}]}}},
          {"id":"9","attributes":{"name":"Empty"}}]}"""
        val rows = ArtistsCatalogResponse.parse(body, 5.0)!!
        assertEquals(listOf("3", "2", "1"), rows.filter { it.artistId == 271256 }.map { it.releaseId })
        assertEquals("Future", rows.first().releaseArtistName)
        assertNull(rows.first { it.releaseId == "1" }.releaseAtMs)
        assertEquals(1, rows.count { it.artistId == 9 })
        assertNull(ArtistsCatalogResponse.parse("{}", 0.0))
    }

    // ---- dedupe -------------------------------------------------------------------------------

    @Test fun appearsOnIsDroppedButCollabAndEmptyCreditAreKept() {
        val rows = listOf(
            row(1, "1", "Ya Hit - Single", 1.0, name = "Drake", credit = "Future, Drake & Metro Boomin"),
            row(1, "2", "Own", 1.0, name = "Drake", credit = "Drake"),
            row(1, "3", "Elsewhere", 1.0, name = "Drake", credit = "Future"),
            row(1, "4", "Nocredit", 1.0, name = "Drake"),
        )
        assertEquals(listOf("1", "2", "4"), ReleaseFeedDedupe.ownReleases(rows, "Drake").map { it.releaseId })
    }

    @Test fun oneReleaseUnderTwoArtistsKeepsTheFirstCredited() {
        val a = row(5, "9", "Duet", 1.0, name = "Beta", credit = "Alpha & Beta")
        val b = row(7, "9", "Duet", 1.0, name = "Alpha", credit = "Alpha & Beta")
        assertEquals(listOf(7), ReleaseFeedDedupe.acrossArtists(listOf(a, b)).map { it.artistId })
        assertEquals(1, feed(a, b).feed(now).size)
    }

    @Test fun cleanAndExplicitTwinsCollapseWithPreferenceAndVerdict() {
        val svc = feed(row(1, "20", "Details", 8.0, explicit = false), row(1, "21", "Details", 2.0, explicit = true))
        svc.prefersExplicit = { true }
        assertEquals(listOf("rel:21"), svc.feed(now).map { it.id })
        assertEquals(listOf("20"), svc.feed(now).first().alternateReleaseIds)
        svc.prefersExplicit = { false }
        assertEquals(listOf("rel:20"), svc.feed(now).map { it.id })
        svc.prefersExplicit = null
        assertEquals("unset prefers clean", listOf("rel:20"), svc.feed(now).map { it.id })
        svc.hasVerdict = { it == "rel:21" }
        assertEquals("a verdict beats preference", listOf("rel:21"), svc.feed(now).map { it.id })
        svc.hasVerdict = null
        svc.ownsRelease = { it.storeId == "21" }
        assertTrue("owning either twin drops the record", svc.feed(now).isEmpty())
    }

    @Test fun editionsCollapseButLiveAndRemixStaySeparate() {
        assertEquals(listOf("rel:2"), feed(row(1, "1", "Rec", 12.0), row(1, "2", "Rec (Deluxe Edition)", 2.0)).feed(now).map { it.id })
        assertEquals(2, feed(row(1, "1", "Rec", 12.0), row(1, "2", "Rec (Live)", 2.0)).feed(now).size)
        assertEquals(
            2,
            feed(row(1, "1", "Song - Single", 12.0, "single"), row(1, "2", "Song (X Remix) - Single", 2.0, "single")).feed(now).size,
        )
    }

    @Test fun singleAndItsAlbumStayTwoRows() {
        assertEquals(2, feed(row(1, "1", "anything", 3.0, tracks = 8), row(1, "2", "anything - Single", 3.0, "single", tracks = 1)).feed(now).size)
    }

    // ---- cache invariants + migration ---------------------------------------------------------

    @Test fun normalizeEvictsKeepsHeadAndDropsUndated() {
        val head = row(1, "1", "Head", 90.0)
        val future = row(1, "2", "Soon", 0.0).copy(releaseAtMs = now + 5 * day)
        val rows = listOf(
            head, row(1, "3", "Fresh", 5.0), row(1, "4", "Old", 45.0), future,
            ArtistReleaseEntry(1, "Artist 1", now, "5"), row(1, "3", "Dup", 5.0),
        )
        val out = ReleaseFeedCache.normalize(rows, now)
        assertEquals(listOf("2", "3"), out.map { it.releaseId })
        assertEquals(listOf("1"), ReleaseFeedCache.normalize(listOf(head), now).map { it.releaseId })
    }

    @Test fun v1FileLoadsWithNoFetchAndTtlClocksKept() {
        val v1 = ReleaseFeedDocument(
            listOf(row(1, "10", "Rec", 4.0), ArtistReleaseEntry(2, "B", now - 3 * day)), schemaVersion = 1,
        )
        file.writeText(ReleaseFeedDocumentCodec.encode(v1))
        val t = Routing()
        val svc = service(t)
        assertEquals(2, svc.cachedArtistCount)
        assertEquals(now - 3 * day, svc.entry(2)!!.checkedAtMs, 0.0)
        assertEquals(0, svc.pendingCount)
        assertEquals(0, t.calls.get())
        svc.playsForArtist = { 2860 } // 2-day TTL; artist 1 was checked "now"
        svc.noteArtistPlayed(1, "Artist 1", now)
        assertEquals("a play inside the TTL queues nothing", 0, svc.pendingCount)
    }

    @Test fun v2RoundTripsAndDowngradeKeepsTheHead() = runBlocking {
        val body = """{"data":[{"id":"1","attributes":{"name":"A"},"relationships":{"albums":{"data":[
          {"id":"11","attributes":{"name":"S - Single","releaseDate":"${iso(1.0)}","isSingle":true,"artistName":"A"}},
          {"id":"10","attributes":{"name":"Album","releaseDate":"${iso(8.0)}","artistName":"A"}}]}}}]}"""
        val t = Routing(body)
        val svc = service(t)
        svc.playsForArtist = { 0 }
        svc.noteArtistPlayed(1, "A", now)
        settle(svc, t)
        val doc = ReleaseFeedDocumentCodec.decode(file.readText())!!
        assertEquals(2, doc.schemaVersion)
        assertEquals(listOf("11", "10"), doc.entries.map { it.releaseId })
        // Old builds: first row per artist (putIfAbsent) = the head.
        val old = HashMap<Int, ArtistReleaseEntry>().also { m -> doc.entries.forEach { m.putIfAbsent(it.artistId, it) } }
        assertEquals("11", old[1]!!.releaseId)
        val reopened = service(null)
        assertEquals(listOf("11", "10"), reopened.releases(1).map { it.releaseId })
    }

    @Test fun applyReplacesTheListAndCarriesSimilarForward() = runBlocking {
        val body = """{"data":[{"id":"1","attributes":{"name":"A"},"relationships":{"albums":{"data":[
          {"id":"new","attributes":{"name":"New","releaseDate":"${iso(1.0)}","artistName":"A"}}]}}}]}"""
        val t = Routing(body)
        val svc = service(t, null)
        svc.seedForTesting(listOf(row(1, "gone", "Withdrawn Preorder", -5.0, name = "A").copy(similarArtistIds = listOf(7, 8), similarCheckedAtMs = 1.0)))
        svc.playsForArtist = { 0 }
        svc.recheckKnownArtists()
        settle(svc, t)
        assertEquals(listOf("new"), svc.releases(1).map { it.releaseId })
        assertEquals(listOf(7, 8), svc.entry(1)!!.similarArtistIds)
        assertEquals(listOf(7, 8), svc.similarArtistIds(listOf(1)))
    }

    // ---- overflow -----------------------------------------------------------------------------

    private fun saturated(next: Boolean = true): String {
        val items = (1..25).joinToString(",") {
            """{"id":"${100 + it}","attributes":{"name":"R$it - Single","releaseDate":"${iso(it * 0.5)}","isSingle":true,"artistName":"A"}}"""
        }
        return """{"data":[{"id":"1","attributes":{"name":"A"},"relationships":{"albums":{"data":[$items]${if (next) ",\"next\":\"/v1/x?offset=25\"" else ""}}}}]}"""
    }

    @Test fun saturatedArtistGetsExactlyOneFollowUp() = runBlocking {
        val t = Routing(saturated(), """{"data":[{"id":"200","attributes":{"name":"Older - Single","releaseDate":"${iso(14.0)}","isSingle":true,"artistName":"A"}}]}""")
        val svc = service(t, null)
        svc.playsForArtist = { 0 }
        svc.noteArtistPlayed(1, "A", now)
        settle(svc, t)
        assertEquals(2, t.calls.get())
        assertTrue(t.urls.last().contains("/artists/1/albums?sort=-releaseDate&offset=25&limit=100"))
        assertEquals(26, svc.releases(1).size)
    }

    @Test fun failedFollowUpKeepsThe25AndDoesNotRequeue() = runBlocking {
        val t = Routing(saturated())
        val svc = service(t, null)
        svc.playsForArtist = { 0 }
        svc.noteArtistPlayed(1, "A", now)
        settle(svc, t)
        assertEquals(25, svc.releases(1).size)
        assertEquals(0, svc.pendingCount)
    }

    @Test fun noFollowUpWithoutNext() = runBlocking {
        val t = Routing(saturated(next = false))
        val svc = service(t, null)
        svc.playsForArtist = { 0 }
        svc.noteArtistPlayed(1, "A", now)
        settle(svc, t)
        assertEquals(1, t.calls.get())
        assertNotNull(svc.entry(1))
        assertFalse(svc.releases(1).isEmpty())
    }
}

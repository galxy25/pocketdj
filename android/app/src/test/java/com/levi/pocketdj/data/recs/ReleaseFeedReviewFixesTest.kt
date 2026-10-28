package com.levi.pocketdj.data.recs

import com.levi.pocketdj.data.catalog.IndexArtist
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** BRW-14 review fixes: UI-visible revision bumps, resolver memo, JSON shape. */
class ReleaseFeedReviewFixesTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val tmp = kotlin.io.path.createTempDirectory("relfeedfix").toFile()
    private val file = File(tmp, ReleaseFeedService.FILE_NAME)

    @After fun cleanup() { scope.cancel(); tmp.deleteRecursively() }

    private class T(override val canSync: Boolean = true, val onFetch: suspend () -> String) : ReleaseFeedTransport {
        override suspend fun fetch(url: String): String = onFetch()
    }

    private fun svc(t: ReleaseFeedTransport?) =
        ReleaseFeedService(t, file, scope, timeScale = 0.0, clock = { 1_800_000_000_000.0 }, random = { 0.0 })

    @Test fun ownershipChangedBumpsRevisionSoCachedUiRecomputes() {
        val s = svc(null)
        val before = s.revisionFlow.value
        s.ownershipChanged()
        assertTrue(s.revisionFlow.value > before)
    }

    @Test fun ownershipFilterIsReadAtFeedTimeAfterTheIndexArrives() {
        val s = svc(null)
        val now = 1_800_000_000_000.0
        s.seedForTesting(listOf(ArtistReleaseEntry(1, "A", now, "r1", "Rel", now - 86_400_000.0)))
        assertEquals(1, s.feed(now).size) // index not built yet: owns nothing
        s.ownsRelease = { true }
        s.ownershipChanged()
        assertEquals(0, s.feed(now).size)
    }

    @Test fun fetchingFlipAndFailureBumpRevision() = runBlocking {
        val seen = java.util.concurrent.CopyOnWriteArrayList<Int>()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val t = T { gate.await(); throw ReleaseFeedTransportError.Http(400) }
        val s = svc(t)
        s.noteArtistPlayed(7, "Seven")
        // drain started: isFetching flipped true with a bump
        val start = System.currentTimeMillis()
        while (!s.isFetchingNow && System.currentTimeMillis() - start < 5000) delay(5)
        assertTrue(s.isFetchingNow)
        val during = s.revisionFlow.value
        assertTrue("fetching start must bump", during > 0)
        gate.complete(Unit)
        while ((s.isFetchingNow || s.emptyReason() !is ReleaseEmptyReason.Unreachable) && System.currentTimeMillis() - start < 8000) delay(5)
        assertTrue(s.emptyReason() is ReleaseEmptyReason.Unreachable)
        assertTrue("failure/finish must bump", s.revisionFlow.value > during)
        seen.clear()
    }

    @Test fun resolverBuildsOncePerListIdentity() {
        val list = listOf(IndexArtist(key = "the band", name = "The Band", id = 11L), IndexArtist(key = "x", name = "X", id = 12L))
        val r = ArtistIdResolver { list }
        assertEquals(11, r.resolve("The  Band"))
        assertEquals(12, r.resolve("x"))
        assertEquals(null, r.resolve("nobody"))
        assertEquals(1, r.buildCount)
        val r2 = ArtistIdResolver { list.toList() } // new instance every call = would rebuild every time
        r2.resolve("x"); r2.resolve("x")
        assertEquals(2, r2.buildCount)
    }

    @Test fun encodedEntryAlwaysCarriesNameAndCheckedAtForIosDecoder() {
        val text = ReleaseFeedDocumentCodec.encode(ReleaseFeedDocument(listOf(ArtistReleaseEntry(artistId = 5))))
        assertTrue(text, text.contains("\"artistName\""))
        assertTrue(text, text.contains("\"checkedAtMs\""))
        val back = ReleaseFeedDocumentCodec.decode(text)!!
        assertEquals(1, back.entries.size)
    }
}

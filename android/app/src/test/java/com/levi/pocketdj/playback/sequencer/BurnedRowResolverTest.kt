package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.playback.PlaybackMode
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnedRowResolverTest {
    private val burned = mapOf(
        "a" to BurnedHit(File("/b/album.mp3"), isCut = false, startMs = 60_000, durationMs = 30_000),
        "b" to BurnedHit(File("/b/b.mp3"), isCut = true, startMs = 60_000, durationMs = 30_000),
        "a_clean" to BurnedHit(File("/b/a_clean.mp3"), isCut = false, startMs = null, durationMs = null),
    )
    private val resolver = BurnedRowResolver { burned[it] }
    private val manifest = RipManifestEntry(key = "rips/a.mp3")

    @Test fun analogWindowFromLedger() {
        val lf = resolver.localUrlForPlayback(QueueItem("a"))!!
        assertEquals(60_000L, lf.startMs); assertEquals(90_000L, lf.endMs)
    }

    @Test fun cutPlaysFromZero() {
        val lf = resolver.localUrlForPlayback(QueueItem("b"))!!
        assertNull(lf.startMs); assertNull(lf.endMs)
    }

    @Test fun resolvesByStorageIdForEditionVariants() {
        val item = QueueItem("a", resolveId = "a_clean")
        assertTrue(resolver.localUrlForPlayback(item)!!.url.endsWith("a_clean.mp3"))
        assertNull(resolver.localUrlForPlayback(QueueItem("zzz")))
    }

    private fun registry() = RowResolverRegistry(
        initial = listOf(resolver, ManifestRowResolver { if (it == "a" || it == "m") manifest else null }),
        manifestHit = { it == "a" || it == "m" },
    )

    @Test fun burnedBeatsManifestInCloudMode() = runBlocking {
        val src = registry().resolve(QueueItem("a"), PlaybackMode.CLOUD)
        assertTrue(src is LocalFileSource)
        assertEquals("burned", src.backend)
    }

    @Test fun cloudFallsThroughToManifestWhenNotBurned() = runBlocking {
        assertTrue(registry().resolve(QueueItem("m"), PlaybackMode.CLOUD) is StreamSource)
    }

    @Test fun deviceModeSkipsUnburnedEvenWithManifest() = runBlocking {
        val src = registry().resolve(QueueItem("m"), PlaybackMode.DEVICE)
        assertEquals(UnplayableSource(UnplayableSource.Reason.NOT_ON_DEVICE), src)
        assertTrue(registry().resolve(QueueItem("a"), PlaybackMode.DEVICE) is LocalFileSource)
    }

    @Test fun queuePlanSkipsUnburnedAndKeepsOrder() {
        val q = listOf(QueueItem("a"), QueueItem("m"), QueueItem("b"))
        val plan = DeviceQueuePlan.plan(q) { resolver.localUrlForPlayback(it) != null }
        plan as DeviceQueuePlan.Outcome.Plays
        assertEquals(listOf("a", "b"), plan.playable.map { it.id })
        assertEquals(listOf("m"), plan.skipped.map { it.id })
    }

    @Test fun queuePlanAllUnplayableWhenNothingBurned() {
        val plan = DeviceQueuePlan.plan(listOf(QueueItem("m"), QueueItem("n"))) { false }
        assertEquals(DeviceQueuePlan.Outcome.AllUnplayable, plan)
        assertEquals(DeviceQueuePlan.Outcome.AllUnplayable, DeviceQueuePlan.plan(emptyList()) { true })
    }
}

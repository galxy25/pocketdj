package com.levi.pocketdj.playback.sequencer

import com.levi.pocketdj.data.rips.AlbumFileTimeline
import com.levi.pocketdj.data.rips.PlayAction
import com.levi.pocketdj.data.rips.PlayResolver
import com.levi.pocketdj.data.rips.RipManifestEntry
import com.levi.pocketdj.data.rips.SegmentOverrides
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** P2-ALB-1 review: burned windows end at the timeline end (detected + grace), not the catalog length; stream starts honor edits. */
class BurnedTimelineEndTest {
    private val manifest = mapOf(
        "s1" to RipManifestEntry(key = "rips/alb.mp3", startMs = 0L, durationMs = 200_000L),
        "s2" to RipManifestEntry(key = "rips/alb.mp3", startMs = 300_000L, durationMs = 230_000L),
    )

    @Test fun windowEndsAtDetectedEndPlusGraceNotCatalogLength() {
        // Real length 4:30 (detected 255 s + 15 s grace), catalog says 3:50.
        val layout = SegmentOverrides.Snapshot(detectedEndMs = mapOf("s2" to 255_000L + 300_000L))
        val file = File("/b/alb.mp3")
        val r = BurnedRowResolver.from(
            playbackFile = { file }, startMs = { manifest[it]?.startMs }, durationMs = { 230_000L },
            endMs = { AlbumFileTimeline.forSong(it, manifest, layout)?.endMs(it) },
        )
        val lf = r.localUrlForPlayback(QueueItem("s2"))!!
        assertEquals(300_000L, lf.startMs)
        assertEquals(570_000L, lf.endMs) // detected 555 s + 15 s; the catalog length would give 530 s
    }

    @Test fun noTimelineEndFallsBackToStartPlusDuration() {
        val lf = burnedLocalFile(File("/b/x.mp3"), isCut = false, startMs = 60_000, durationMs = 30_000, endMs = null)
        assertEquals(90_000L, lf.endMs)
        assertEquals(120_000L, burnedLocalFile(File("/b/x.mp3"), false, 60_000, 30_000, endMs = 120_000).endMs)
        assertNull(burnedLocalFile(File("/b/x.mp3"), true, 60_000, 30_000, endMs = 120_000).endMs)
    }

    @Test fun streamStartHonorsEditedBoundary() {
        val e = manifest["s2"]!!
        val a = PlayResolver.resolve("s2", e, false, startOf = { _, _ -> 295_000L }) as PlayAction.Stream
        assertEquals(295_000L, a.clipStartMs)
    }

    @Test fun manifestRowResolverUsesStartOf() = runBlocking {
        val r = ManifestRowResolver(startOf = { _, _ -> 295_000L }, entry = { manifest[it] })
        val src = r.resolve(QueueItem("s2"), ResolveContext(com.levi.pocketdj.playback.PlaybackMode.CLOUD, false, false)) as StreamSource
        assertEquals(295_000L, src.action.clipStartMs)
    }
}

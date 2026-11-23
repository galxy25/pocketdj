package com.levi.pocketdj.data.rips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Port of the 7 iOS `AlbumFileTimelineTests` (same numbers) plus the sort/dup/previous/isLast contract. */
class AlbumFileTimelineTest {
    private val manifest = mapOf(
        "s2" to RipManifestEntry(key = "rips/alb.mp3", source = "analog", startMs = 200_000),
        "s1" to RipManifestEntry(key = "rips/alb.mp3", source = "analog", startMs = 1_500),
        "s3" to RipManifestEntry(key = "rips/alb.mp3", source = "analog", startMs = 410_000),
        "other" to RipManifestEntry(key = "rips/alb2.mp3", source = "analog", startMs = 0),
        "dig" to RipManifestEntry(key = "rips/dig.mp3", source = "digital"),
    )

    @Test fun segmentsSortedAndScopedToOneFile() {
        val tl = AlbumFileTimeline.forSong("s3", manifest)
        assertEquals(listOf("s1", "s2", "s3"), tl?.segments?.map { it.songId })
        assertNull(AlbumFileTimeline.forSong("dig", manifest))
        assertNull(AlbumFileTimeline.forSong("missing", manifest))
    }

    @Test fun eachSongEndsWhereTheNextStartsAndTheLastRunsToTheFileEnd() {
        val tl = AlbumFileTimeline.forSong("s1", manifest)!!
        assertEquals(200_000L, tl.endMs("s1"))
        assertEquals(410_000L, tl.endMs("s2"))
        assertNull(tl.endMs("s3"))
        assertEquals("s2", tl.next("s1")?.songId)
        assertNull(tl.next("s3"))
        assertEquals("s1", tl.previous("s2")?.songId)
        assertNull(tl.previous("s1"))
        assertEquals(true, tl.isLast("s3")); assertEquals(false, tl.isLast("s1"))
    }

    @Test fun positionMapsToItsSong() {
        val tl = AlbumFileTimeline.forSong("s1", manifest)!!
        assertEquals("s1", tl.segmentAt(0)?.songId) // lead-in groove belongs to the first song
        assertEquals("s1", tl.segmentAt(199_999)?.songId)
        assertEquals("s2", tl.segmentAt(200_000)?.songId)
        assertEquals("s3", tl.segmentAt(9_999_999)?.songId)
    }

    @Test fun overridesMoveStartsAndTheLastEnd() {
        val ov = SegmentOverrides.Snapshot(startMs = mapOf("s2" to 190_000L), endMs = mapOf("s3" to 600_000L))
        val tl = AlbumFileTimeline.forSong("s1", manifest, ov)!!
        assertEquals(190_000L, tl.endMs("s1"))
        assertEquals(190_000L, tl.segment("s2")?.startMs)
        assertEquals(600_000L, tl.endMs("s3"))
    }

    @Test fun detectedEndsGetTheFadeGraceCappedAtTheNextStart() {
        val layout = SegmentOverrides.Snapshot(
            detectedEndMs = mapOf("s1" to 150_000L, "s2" to 400_000L, "s3" to 500_000L),
        )
        val tl = AlbumFileTimeline.forSong("s1", manifest, layout)!!
        assertEquals(165_000L, tl.endMs("s1"))
        assertEquals(410_000L, tl.endMs("s2"))
        assertEquals(515_000L, tl.endMs("s3"))
        val edited = SegmentOverrides.Snapshot(endMs = mapOf("s1" to 170_000L), detectedEndMs = mapOf("s1" to 150_000L))
        assertEquals(170_000L, AlbumFileTimeline.forSong("s1", manifest, edited)?.endMs("s1"))
    }

    @Test fun nonMembersAreDroppedFromTheSide() {
        val m = manifest + ("stale" to RipManifestEntry(key = "rips/alb.mp3", source = "analog", startMs = 100_000))
        val layout = SegmentOverrides.Snapshot(
            albumOfSong = mapOf("s1" to "alb", "s2" to "alb", "s3" to "alb"),
            albumTracks = mapOf("alb" to setOf("s1", "s2", "s3")),
        )
        assertEquals(200_000L, AlbumFileTimeline.forSong("s1", m, layout)?.endMs("s1"))
        assertEquals(100_000L, AlbumFileTimeline.forSong("s1", m)?.endMs("s1"))
    }

    @Test fun duplicateStartKeepsTheFirstAndEndAtOrBeforeStartFallsToNext() {
        val tl = AlbumFileTimeline(
            "k",
            listOf(
                AlbumFileTimeline.Segment("b", 5_000), AlbumFileTimeline.Segment("a", 5_000),
                AlbumFileTimeline.Segment("c", 90_000),
            ),
            exactEndMs = mapOf("a" to 4_000L),
        )
        assertEquals(listOf("a", "c"), tl.segments.map { it.songId }) // sorted (startMs, songId); dup start keeps first
        assertEquals(90_000L, tl.endMs("a")) // own end at/before its start -> next start
        assertNull(tl.endMs("unknown"))
        assertEquals(15_000L, AlbumFileTimeline.FADE_GRACE_MS)
    }
}

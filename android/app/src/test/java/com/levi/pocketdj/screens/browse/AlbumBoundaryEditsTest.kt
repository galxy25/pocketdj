package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.AlbumEdit
import com.levi.pocketdj.data.catalog.AudioTrack
import com.levi.pocketdj.data.catalog.AudioTrackEdit
import com.levi.pocketdj.data.catalog.EditsStore
import com.levi.pocketdj.data.catalog.CatalogEdits
import com.levi.pocketdj.data.catalog.SongEdit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AlbumBoundaryEditsTest {
    private val raw = listOf(
        AudioTrack(trackNumber = 1, startMs = 0, endMs = 200_000),
        AudioTrack(trackNumber = 2, startMs = 210_000, endMs = 400_000),
        AudioTrack(trackNumber = 3, startMs = 410_000, endMs = 600_000),
    )
    private val ids = listOf("a", "b", "c")

    @Test fun startsPreferEffectiveThenSegmentsAndHideWhenUnknown() {
        assertEquals(listOf(0L, 215_000L, 410_000L), AlbumBoundaryEdits.starts(ids, raw) { if (it == "b") 215_000L else null })
        assertEquals(listOf(5L, 6L, 7L), AlbumBoundaryEdits.starts(ids, null) { mapOf("a" to 5L, "b" to 6L, "c" to 7L)[it] })
        // segments not 1:1 with the track list are not used
        assertNull(AlbumBoundaryEdits.starts(ids, raw.take(2)) { null })
        assertNull(AlbumBoundaryEdits.starts(emptyList(), raw) { 0L })
    }

    @Test fun totalFallsBackThroughDurationSegmentsAndRunOut() {
        val starts = listOf(0L, 210_000L, 410_000L)
        assertEquals(1_000_000L, AlbumBoundaryEdits.totalMs(starts, 1_000_000L, 700.0, raw))
        assertEquals(700_000L, AlbumBoundaryEdits.totalMs(starts, null, 700.0, raw))
        assertEquals(650_000L, AlbumBoundaryEdits.totalMs(starts, null, null, raw)) // last start + 240 s beats lastEnd
        assertEquals(650_000L, AlbumBoundaryEdits.totalMs(starts, null, null, null))
        assertEquals(700_000L, AlbumBoundaryEdits.totalMs(starts, null, null, listOf(AudioTrack(endMs = 700_000))))
    }

    @Test fun endUsesExactThenDetectedPlusGraceCappedAtNextStart() {
        val starts = listOf(0L, 210_000L, 410_000L)
        val total = 700_000L
        // detected end 200 s + 15 s grace = 215 s, capped at next start 210 s
        assertEquals(210_000L, AlbumBoundaryEdits.endMs(0, ids, starts, total, emptyMap(), mapOf("a" to 200_000L)))
        // detected end 190 s + grace 15 s = 205 s: gap stays
        assertEquals(205_000L, AlbumBoundaryEdits.endMs(0, ids, starts, total, emptyMap(), mapOf("a" to 190_000L)))
        // exact edit wins, no grace
        assertEquals(190_000L, AlbumBoundaryEdits.endMs(0, ids, starts, total, mapOf("a" to 190_000L), mapOf("a" to 200_000L)))
        // last song with nothing known runs to the total; with a detected end past total it is clamped
        assertEquals(total, AlbumBoundaryEdits.endMs(2, ids, starts, total, emptyMap(), emptyMap()))
        assertEquals(total, AlbumBoundaryEdits.endMs(2, ids, starts, total, emptyMap(), mapOf("c" to 690_000L)))
        assertEquals(total, AlbumBoundaryEdits.endMs(3, ids, starts, total, emptyMap(), emptyMap()))
    }

    @Test fun indexAtAndHitTesting() {
        val starts = listOf(10_000L, 210_000L, 410_000L)
        assertEquals(0, AlbumBoundaryEdits.indexAt(0, starts)) // lead-in belongs to the first
        assertEquals(1, AlbumBoundaryEdits.indexAt(210_000, starts))
        assertEquals(2, AlbumBoundaryEdits.indexAt(999_999, starts))
        // width 600 px over 600 s: 1 px per second
        assertEquals(1, AlbumBoundaryEdits.nearestHandle(215f, starts, 590_000, 600_000, 600f))
        assertEquals(3, AlbumBoundaryEdits.nearestHandle(580f, starts, 590_000, 600_000, 600f))
        assertNull(AlbumBoundaryEdits.nearestHandle(300f, starts, 590_000, 600_000, 600f)) // > 22 px from every handle
        assertEquals(2, AlbumBoundaryEdits.nearestHandle(410f + 22f, starts, 590_000, 600_000, 600f)) // exactly at reach
    }

    @Test fun clampKeepsOneSecondBetweenNeighbours() {
        val starts = listOf(0L, 210_000L, 410_000L)
        val end = 600_000L
        assertEquals(1_000L, AlbumBoundaryEdits.clamp(1, -50, starts, end, 700_000))     // lo = starts[0] + 1 s
        assertEquals(409_000L, AlbumBoundaryEdits.clamp(1, 500_000, starts, end, 700_000)) // hi = starts[2] - 1 s
        assertEquals(0L, AlbumBoundaryEdits.clamp(0, -5, starts, end, 700_000))
        assertEquals(209_000L, AlbumBoundaryEdits.clamp(0, 300_000, starts, end, 700_000))
        assertEquals(599_000L, AlbumBoundaryEdits.clamp(2, 650_000, starts, end, 700_000)) // last start vs the side's end
        assertEquals(411_000L, AlbumBoundaryEdits.clamp(3, 100_000, starts, end, 700_000)) // end handle >= last start + 1 s
        assertEquals(700_000L, AlbumBoundaryEdits.clamp(3, 900_000, starts, end, 700_000))
    }

    @Test fun verticalPanIsNeverAScrub() {
        assertTrue(AlbumBoundaryEdits.isVerticalPan(3f, -20f))
        assertFalse(AlbumBoundaryEdits.isVerticalPan(20f, 3f))
        assertFalse(AlbumBoundaryEdits.isVerticalPan(10f, 10f)) // a tie is horizontal, like iOS (strict >)
        assertEquals(300_000L, AlbumBoundaryEdits.msAt(300f, 600f, 600_000))
        assertEquals(600_000L, AlbumBoundaryEdits.msAt(900f, 600f, 600_000))
        assertEquals(0L, AlbumBoundaryEdits.msAt(-5f, 600f, 600_000))
    }

    // ---- save math goldens (iOS saveBoundary) ----------------------------------------------------------------------

    @Test fun movingAStartSetsItAndThePreviousEnd() {
        val e = AlbumBoundaryEdits.saveBoundary(null, raw, 1, 212_000)!!
        val d = e.audioTracks!!
        assertEquals(3, d.size)
        assertEquals(AudioTrackEdit(trackNumber = 1, endMs = 212_000), d[0])
        assertEquals(AudioTrackEdit(trackNumber = 2, startMs = 212_000), d[1])
        assertEquals(AudioTrackEdit(trackNumber = 3), d[2])
    }

    @Test fun firstBoundaryTouchesNoPreviousEndAndEndHandleSetsLastEnd() {
        val first = AlbumBoundaryEdits.saveBoundary(null, raw, 0, 5_000)!!.audioTracks!!
        assertEquals(5_000L, first[0].startMs)
        assertNull(first[0].endMs)
        val end = AlbumBoundaryEdits.saveBoundary(null, raw, 3, 590_000)!!.audioTracks!!
        assertEquals(590_000L, end[2].endMs)
        assertNull(end[2].startMs)
    }

    @Test fun valueEqualToRawClearsTheDeltaAndAllEmptyDropsAudioTracks() {
        val moved = AlbumBoundaryEdits.saveBoundary(null, raw, 1, 212_000)
        val back = AlbumBoundaryEdits.saveBoundary(moved, raw, 1, 210_000)!!
        assertNull(back.audioTracks) // every delta is empty again
        assertTrue(back.isEmpty)
    }

    @Test fun existingDeltasCarryByTrackNumberAndKeepOtherFields() {
        val existing = AlbumEdit(
            name = "Renamed",
            audioTracks = listOf(
                AudioTrackEdit(trackNumber = 3, bpm = 99.0),          // out of order: carried by number
                AudioTrackEdit(trackNumber = 1, startMs = 3_000),
            ),
        )
        val e = AlbumBoundaryEdits.saveBoundary(existing, raw, 2, 412_000)!!
        assertEquals("Renamed", e.name)
        val d = e.audioTracks!!
        assertEquals(AudioTrackEdit(trackNumber = 1, startMs = 3_000), d[0])
        assertEquals(AudioTrackEdit(trackNumber = 2, endMs = 412_000), d[1])
        assertEquals(AudioTrackEdit(trackNumber = 3, startMs = 412_000, bpm = 99.0), d[2])
    }

    @Test fun positionalDeltasWithoutTrackNumberAreCarriedAndNumbered() {
        val unnumbered = listOf(AudioTrack(startMs = 0, endMs = 100_000), AudioTrack(startMs = 110_000, endMs = 200_000))
        val existing = AlbumEdit(audioTracks = listOf(AudioTrackEdit(), AudioTrackEdit(startMs = 111_000)))
        val d = AlbumBoundaryEdits.saveBoundary(existing, unnumbered, 0, 1_000)!!.audioTracks!!
        assertEquals(AudioTrackEdit(startMs = 1_000), d[0])
        assertEquals(AudioTrackEdit(startMs = 111_000), d[1])
        // a numbered raw segment adopts its number onto a positional delta that had none
        val numbered = listOf(AudioTrack(trackNumber = 7, startMs = 0, endMs = 100_000))
        val n = AlbumBoundaryEdits.saveBoundary(AlbumEdit(audioTracks = listOf(AudioTrackEdit(endMs = 90_000))), numbered, 1, 95_000)!!
        assertEquals(AudioTrackEdit(trackNumber = 7, endMs = 95_000), n.audioTracks!![0])
    }

    @Test fun noRawSegmentsMeansNoEdit() {
        assertNull(AlbumBoundaryEdits.saveBoundary(null, emptyList(), 0, 1))
    }

    @Test fun savedEditRoundTripsInTheIosShape() {
        val e = AlbumBoundaryEdits.saveBoundary(null, raw, 1, 212_000)!!
        val doc = EditsStore.encode(CatalogEdits(mapOf("alb" to e), emptyMap()))
        // deltas only: no nulls, trackNumber kept, positionally one entry per raw segment
        assertTrue(doc.contains("\"audioTracks\":[{\"trackNumber\":1,\"endMs\":212000},{\"trackNumber\":2,\"startMs\":212000},{\"trackNumber\":3}]"), doc)
        assertFalse(doc.contains("null"))
    }

    @Test fun editableOnlyWhenRawSegmentsPairWithTracks() {
        assertTrue(AlbumBoundaryEdits.editable(3, 3))
        assertFalse(AlbumBoundaryEdits.editable(2, 3))
        assertFalse(AlbumBoundaryEdits.editable(0, 0))
    }

    @Test fun renameIsADeltaAgainstTheRawName() {
        assertEquals("New", AlbumBoundaryEdits.renamed(null, "Old", "  New ")!!.name)
        assertNull(AlbumBoundaryEdits.renamed(SongEdit(name = "X"), "Old", "Old")!!.name) // equal to raw -> cleared
        assertNull(AlbumBoundaryEdits.renamed(SongEdit(name = "X"), "Old", "   ")) // blank changes nothing
        assertEquals(120.0, AlbumBoundaryEdits.renamed(SongEdit(bpm = 120.0), "Old", "New")!!.bpm)
    }

    @Test fun stringsMatchIos() {
        assertEquals("0:00.0", AlbumBoundaryEdits.clock(-5))
        assertEquals("1:05.3", AlbumBoundaryEdits.clock(65_350))
        assertEquals("12:00.0", AlbumBoundaryEdits.clock(720_000))
        assertEquals("+1s", AlbumBoundaryEdits.nudgeLabel(1000))
        assertEquals("+0.1s", AlbumBoundaryEdits.nudgeLabel(100))
        assertEquals("−0.1s", AlbumBoundaryEdits.nudgeLabel(-100))
        assertEquals("−1s", AlbumBoundaryEdits.nudgeLabel(-1000))
        assertEquals("3 tracks · 10:00.0", AlbumBoundaryEdits.readout(null, null, 3, 600_000) { "x" })
        assertEquals("1:00.0 · Song", AlbumBoundaryEdits.readout(null, 60_000, 3, 600_000) { "Song" })
        assertEquals("Boundary 0:01.0", AlbumBoundaryEdits.readout(1 to 1_000L, 60_000, 3, 600_000) { "x" })
        assertEquals("End 0:02.0", AlbumBoundaryEdits.readout(3 to 2_000L, null, 3, 600_000) { "x" })
        assertEquals("End of side · 0:01.0", AlbumBoundaryEdits.nudgeLabelFor(true, "t", 1_000))
        assertEquals("Start of Hey · 0:01.0", AlbumBoundaryEdits.nudgeLabelFor(false, "Hey", 1_000))
        assertTrue(AlbumBoundaryEdits.hint(true).contains("drag a dot"))
        assertFalse(AlbumBoundaryEdits.hint(false).contains("drag a dot"))
    }
}

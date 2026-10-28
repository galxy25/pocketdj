package com.levi.pocketdj.screens.producer.demux

import androidx.compose.ui.graphics.Color
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.studio.demux.DemuxChordSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DemuxTimelineMathTest {
    private val M = DemuxTimelineMath

    @Test fun fitPxIsWidthOverSecondsAndFallsBackBeforeLayout() {
        assertEquals(3.0f, M.fitPx(900f, 300_000), 1e-4f)
        assertEquals(4f, M.fitPx(0f, 300_000), 0f)
        assertTrue(M.fitPx(100f, 0) > 0)     // a zero-length track never divides by zero
    }

    @Test fun zoomLadderWalksAndBottomsOutAtFitToWidth() {
        val fit = 3f
        assertEquals(25f, M.stepZoom(10f, +1, fit), 0f)
        assertEquals(60f, M.stepZoom(25f, +1, fit), 0f)
        assertEquals("ladder ceiling", 60f, M.stepZoom(60f, +1, fit), 0f)
        assertEquals(10f, M.stepZoom(25f, -1, fit), 0f)
        assertEquals(4f, M.stepZoom(10f, -1, fit), 0f)
        assertEquals("below the ladder floor lands on fit", 3f, M.stepZoom(4f, -1, fit), 0f)
        assertEquals("a fit above the floor is the first stop down", 12f, M.stepZoom(25f, -1, 12f), 0f)
        assertEquals("zooming in from fit returns to the ladder", 4f, M.stepZoom(3f, +1, fit), 0f)
    }

    @Test fun stripNeverNarrowerThanContainerAndEffectivePxFollows() {
        assertEquals(1000f, M.stripWidth(1000f, 60_000, 10f), 0f)          // 600 < 1000 -> widened
        assertEquals(6000f, M.stripWidth(1000f, 600_000, 10f), 0f)
        assertEquals(1000f / 60f, M.effectivePx(1000f, 60_000), 1e-4f)
    }

    @Test fun scrubClampsToTheTrack() {
        assertEquals(0, M.clampMs(-50f, 10f, 5000))
        assertEquals(2500, M.clampMs(25f, 10f, 5000))
        assertEquals(5000, M.clampMs(1e6f, 10f, 5000))
        assertEquals(0, M.clampMs(10f, 0f, 5000))
    }

    @Test fun followTargetUsesRealLayoutPositionsAtEveryZoom() {
        // 10 min track, viewport 400: second 300 sits at x = 300 * px regardless of zoom.
        for (px in listOf(4f, 10f, 25f, 60f)) {
            val strip = M.stripWidth(400f, 600_000, px)
            val target = M.followTarget(300, px, 400f, strip)
            assertEquals("centered at $px px/s", 300 * px + px / 2 - 200f, target.toFloat(), 1f)
        }
        // near the start/end the target clamps to the scrollable range
        assertEquals(0, M.followTarget(0, 10f, 400f, 6000f))
        assertEquals(5600, M.followTarget(599, 10f, 400f, 6000f))
        assertEquals("strip shorter than viewport never scrolls", 0, M.followTarget(3, 10f, 400f, 400f))
    }

    @Test fun chordColorsAreOneHuePerRootAndMinorIsDimmer() {
        val c = DemuxChordSegment(0, false, 0, 1); val cm = DemuxChordSegment(0, true, 0, 1); val g = DemuxChordSegment(7, false, 0, 1)
        assertNotEquals(M.chordColor(c), M.chordColor(g))
        assertNotEquals(M.chordColor(c), M.chordColor(cm))
        assertTrue(M.chordColor(cm) != Color.Unspecified)
        assertEquals(M.chordColor(DemuxChordSegment(12, false, 0, 1)), M.chordColor(c))   // pitch classes wrap
    }

    // ---- picker rules ----
    private fun song(id: String, name: String, artist: String) = IndexSong(id = id, artist = artist, name = name)

    @Test fun groupsAreCollapsedByDefaultPersistAndSearchForceExpands() {
        val none = DemuxPickerRules.parseExpanded("")
        assertFalse(DemuxPickerRules.isExpanded("", "tracks", none))
        val opened = DemuxPickerRules.toggled(none, "tracks")
        assertEquals("tracks", DemuxPickerRules.serializeExpanded(opened))
        assertTrue(DemuxPickerRules.isExpanded("", "tracks", DemuxPickerRules.parseExpanded("tracks,studio")))
        assertTrue(DemuxPickerRules.isExpanded("beat", "imported", none))          // search expands everything
        assertEquals(setOf("studio"), DemuxPickerRules.toggled(setOf("studio", "tracks"), "tracks"))
        assertEquals("imported,studio", DemuxPickerRules.serializeExpanded(setOf("studio", "imported")))
    }

    @Test fun trackBrowseShowsBurnedOnlyAndSearchSpansTheCatalogBurnedFirst() {
        val all = listOf(song("1", "Zebra", "Beta"), song("2", "Alpha", "Beta"), song("3", "Moon", "Aardvark"), song("4", "Moonlight", "Zed"))
        val burned = setOf("1", "4")
        assertEquals(listOf("1", "4"), DemuxPickerRules.trackMatches(all, "", burned).map { it.id })     // burned subset only, by artist: Beta, Zed
        assertEquals(listOf("4", "3"), DemuxPickerRules.trackMatches(all, "  MOON ", burned).map { it.id })
        assertEquals(listOf("1", "2"), DemuxPickerRules.trackMatches(all, "beta", burned).map { it.id })
        assertEquals(DemuxPickerRules.TRACK_LIMIT, DemuxPickerRules.trackMatches(List(200) { song("$it", "n$it", "a") }, "n", emptySet()).size)
    }

    @Test fun studioAndFileFilters() {
        val rows = List(40) { DemuxPickerRules.StudioRow("smp_$it", if (it == 35) "Snare loop" else "Item $it", "sample") }
        assertEquals(24, DemuxPickerRules.studioMatches(rows, "").size)
        assertEquals(listOf("smp_35"), DemuxPickerRules.studioMatches(rows, "SNARE").map { it.id })
        val files = listOf("a" to "Riff One", "b" to "Other")
        assertEquals(listOf("a"), DemuxPickerRules.fileMatches(files, "riff").map { it.first })
        assertEquals(2, DemuxPickerRules.fileMatches(files, "").size)
    }

    @Test fun stemCopyDiffersForSongsAndCustomAudio() {
        assertTrue(StemsCopy.creatable(false).contains("Uploads this audio"))
        assertTrue(StemsCopy.creatable(true).contains("Not stemmed yet"))
        assertTrue(StemsCopy.creating(false).startsWith("Uploading"))
        assertTrue(StemsCopy.creating(true).startsWith("Separating"))
    }
}

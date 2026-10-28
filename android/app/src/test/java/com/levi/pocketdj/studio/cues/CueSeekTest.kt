package com.levi.pocketdj.studio.cues

import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class CueSeekTest {
    @Test fun digitalSeekIsTheCueItself() {
        val p = CueSeek.plan(null, 200_000, 30_000)
        assertEquals(30_000L, p.clipRelativeMs); assertEquals(30_000L, p.absoluteMs); assertEquals(200_000L, p.endBoundaryMs)
    }

    @Test fun sharedAnalogAddsStartOnlyToTheAbsoluteSeekAndKeepsTheBoundary() {
        val p = CueSeek.plan(600_000, 180_000, 30_000)
        assertEquals(630_000L, p.absoluteMs)          // entry.startMs + cueMs
        assertEquals(30_000L, p.clipRelativeMs)        // ExoPlayer clip applies the start itself
        assertEquals(780_000L, p.endBoundaryMs)        // startMs + durationMs, NOT shifted by the cue
        assertEquals(p.endBoundaryMs, CueSeek.plan(600_000, 180_000, 100_000).endBoundaryMs)
    }

    @Test fun cuePastTheEndClampsToDurationAndNegativeToZero() {
        val p = CueSeek.plan(600_000, 180_000, 999_999)
        assertEquals(180_000L, p.cueMs); assertEquals(780_000L, p.absoluteMs)
        assertEquals(0L, CueSeek.plan(5, 100, -40).cueMs)
        assertEquals(500_000L, CueSeek.plan(null, null, 500_000).cueMs)    // unknown duration: no clamp
        assertNull(CueSeek.plan(null, null, 1).endBoundaryMs)
        assertNull(CueSeek.plan(null, 0, 1).durationMs)
    }

    @Test fun amSeekOnlyForTheCurrentPlayStillOwningAudio() {
        assertEquals(true, CueSeek.shouldSeekAfterAm(5, 5, true))
        assertEquals(false, CueSeek.shouldSeekAfterAm(5, 6, true))   // a newer tap superseded it
        assertEquals(false, CueSeek.shouldSeekAfterAm(5, 5, false))  // AM no longer owns audio
    }

    @Test fun architectureLedgerRowForStu6IsNoLongerPlanned() {
        val f = java.io.File("../docs/ARCHITECTURE-ANDROID.md").takeIf { it.exists() } ?: java.io.File("docs/ARCHITECTURE-ANDROID.md")
        if (!f.exists()) return
        val row = f.readLines().first { it.startsWith("| STU-6 ") }
        org.junit.Assert.assertFalse(row, row.contains("| Planned |"))
    }

    @Test fun availabilityGatesUnseekableRips() {
        assertEquals(CueSeek.Availability.PLAYABLE, CueSeek.availability(true, false, false, false))
        assertEquals(CueSeek.Availability.PLAYABLE, CueSeek.availability(false, true, false, false))
        assertEquals(CueSeek.Availability.PLAYABLE, CueSeek.availability(false, false, true, true))
        assertEquals(CueSeek.Availability.STILL_RIPPING, CueSeek.availability(false, false, true, false))   // AM not ready
        assertEquals(CueSeek.Availability.STILL_RIPPING, CueSeek.availability(false, false, false, false))  // live HLS
    }

    @Test fun stampAndFractions() {
        assertEquals("1:05.007", CueSeek.stamp(65_007)); assertEquals("0:00.000", CueSeek.stamp(-5))
        assertEquals(0.5f, CueSeek.fraction(50, 100), 0f); assertEquals(1f, CueSeek.fraction(500, 100), 0f)
        assertEquals(0f, CueSeek.fraction(5, 0), 5f)
        assertEquals(250, CueSeek.positionAt(0.25f, 1000)); assertEquals(1000, CueSeek.positionAt(2f, 1000))
    }

    private fun song(id: String, name: String, artist: String) = IndexSong(id = id, artist = artist, name = name)

    @Test fun searchIsBurnedFirstAndEmptyQueryBrowsesCuedPlusBurned() {
        val songs = listOf(song("a", "Alpha", "Zed"), song("b", "Beta", "Amy"), song("c", "Gamma", "Amy"), song("d", "Delta", "Bob"))
        val burned = setOf("c")
        assertEquals(listOf("c", "b"), CueSeek.search(songs, "amy", { it in burned }, emptySet()).map { it.id })
        assertEquals(listOf("c", "d"), CueSeek.search(songs, "", { it in burned }, setOf("d")).map { it.id })
        assertEquals(listOf("a"), CueSeek.search(songs, "alp zed", { false }, emptySet()).map { it.id })
        assertEquals(1, CueSeek.search(songs, "a", { false }, emptySet(), limit = 1).size)
    }

    @Test fun analogCropUsesTheLargestFileSpanAndNeverOverruns() {
        // song at 100s..160s of a 400 s side (sibling ends 160/400 s)
        val c = CueSeek.analogCrop(100_000, 60_000, listOf(160_000, 400_000), null)!!
        assertEquals(0.25f, c.start, 1e-6f); assertEquals(0.15f, c.width, 1e-6f)
        // measured album duration beats a shorter sibling span (trailing run-out)
        val d = CueSeek.analogCrop(100_000, 60_000, listOf(160_000), 500.0)!!
        assertEquals(0.2f, d.start, 1e-6f); assertEquals(0.12f, d.width, 1e-6f)
        // window can never overrun its own file
        val e = CueSeek.analogCrop(100_000, 60_000, emptyList(), null)!!
        assertEquals(100f / 160f, e.start, 1e-6f); assertEquals(60f / 160f, e.width, 1e-6f)
        assertNull(CueSeek.analogCrop(null, 60_000, emptyList(), null)); assertNull(CueSeek.analogCrop(0, 0, emptyList(), null))
        assertNotNull(CueSeek.analogCrop(0, 10, emptyList(), null))
    }
}

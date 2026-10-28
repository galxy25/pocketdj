package com.levi.pocketdj.data.burns

import com.levi.pocketdj.data.catalog.IndexSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnSidecarTest {
    private val s = IndexSong(
        id = "sng_1", artist = "Daft Punk", name = "One More Time", albumId = "alb_1", year = 2000,
        sentimentKeywords = listOf("happy", "dance"), bpm = 120.0, key = "A minor", camelot = "8A", length = 320000,
    )
    private val a = album("alb_1", artist = "Daft Punk", name = "Discovery", genre = "House")
    private val e = digital("sng_1", bpm = 123.0, camelot = "9A", key = "E minor")

    private fun text() = BurnSidecar.build("sng_1", bs("sng_1"), s, a, e)

    @Test fun headerOrderIsBpmKeySentimentAlbumWithManifestPrecedence() {
        val lines = text().lines()
        assertEquals("Daft Punk — One More Time", lines[0])
        assertEquals("=".repeat(60), lines[1])
        assertEquals("BPM:        123.0", lines[3])
        assertEquals("Key:        E minor  (Camelot 9A)", lines[4])
        assertEquals("Sentiment:  happy, dance", lines[5])
        assertEquals("Album:      Discovery", lines[6])
        assertEquals("-- Song metadata --", lines[8])
        val t = text()
        assertTrue(t.indexOf("-- Song metadata --") < t.indexOf("-- Album metadata --"))
        assertTrue(t.indexOf("-- Album metadata --") < t.indexOf("-- Raw JSON --"))
        assertTrue(t.endsWith("}\n"))
    }

    @Test fun missingEverythingUsesEmDashPlaceholders() {
        val t = BurnSidecar.build("sng_z", BurnSong("sng_z", "Title", "Artist"), null, null, null)
        val lines = t.lines()
        assertEquals("Artist — Title", lines[0])
        assertEquals("BPM:        —", lines[3])
        assertEquals("Key:        —  (Camelot —)", lines[4])
        assertEquals("Sentiment:  —", lines[5])
        assertEquals("Album:      —", lines[6])
        assertTrue(t.contains("  (song not found in index)"))
        assertTrue(t.contains("  (album not found in index)"))
        assertTrue(t.contains("-- Raw JSON --\n{\n\n}"))
    }

    @Test fun rawJsonIsSortedPrettyAndEscapesSlashesLikeFoundation() {
        val t = text()
        assertTrue(t.contains("\"key\" : \"rips\\/sng_1.mp3\""))
        // integral doubles lose the ".0" in Foundation output
        assertTrue(t.contains("\"bpm\" : 123,"))
        assertTrue(t.indexOf("\"album\"") < t.indexOf("\"manifestEntry\""))
        assertTrue(t.indexOf("\"manifestEntry\"") < t.indexOf("\"song\""))
    }

    @Test fun adoptionRoundTripRecoversArtistTitleAndManifestEntry() {
        val parsed = BurnSidecar.parseForAdoption(text())
        assertEquals("Daft Punk", parsed.artist)
        assertEquals("One More Time", parsed.title)
        assertEquals("rips/sng_1.mp3", parsed.entry!!.key)
        assertEquals(123.0, parsed.entry!!.bpm!!, 0.0)
        assertEquals("9A", parsed.entry!!.camelot)
        assertEquals("digital", parsed.entry!!.source)
    }

    @Test fun adoptionToleratesTitleWithEmDashAndMissingJson() {
        val p = BurnSidecar.parseForAdoption("Band — Part 1 — Reprise\n====\n")
        assertEquals("Band", p.artist)
        assertEquals("Part 1 — Reprise", p.title)
        assertNull(p.entry)
        assertNull(BurnSidecar.parseForAdoption("— — —\n").artist)
    }
}

package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RipsModelsStemsTest {
    private val json = PdjJson.lenient

    @Test
    fun entryWithStemsBeatgridLyrics_decodesIosShape_andIgnoresUnknown() {
        val e = json.decodeFromString<RipManifestEntry>(
            """{"key":"rips/sng_a.mp3","cutKey":"rips/sng_a.cut.mp3","cutBytes":123,
               "firstBeatMs":410,"firstDownbeatMs":820,"beatGridBpm":121.5,"beatsPerBar":4,
               "tempoConfidence":0.93,"steady":true,"beatgrid":"rips/analysis/sng_a.json",
               "stems":{"vocals":"rips/stems/sng_a/vocals.flac","drums":"rips/stems/sng_a/drums.flac",
                        "bass":"rips/stems/sng_a/bass.flac","other":"rips/stems/sng_a/other.flac"},
               "stemVersion":2,"stemFormat":"flac","stemModel":"htdemucs",
               "lyrics":"rips/lyrics/sng_a.json","futureThing":{"a":1}}""",
        )
        assertEquals(820L, e.firstDownbeatMs)
        assertEquals(121.5, e.beatGridBpm!!, 0.0)
        assertEquals(true, e.steady)
        assertEquals("rips/analysis/sng_a.json", e.beatgridKey)
        assertTrue(e.isStemmed)
        assertEquals("flac", e.stemFormat)
        val urls = e.stemUrls("https://rips.example/")!!
        assertEquals(listOf("vocals", "drums", "bass", "other"), urls.keys.toList())
        assertEquals("https://rips.example/rips/stems/sng_a/drums.flac", urls["drums"])
        assertEquals("https://rips.example/rips/lyrics/sng_a.json", e.lyricsUrl("https://rips.example"))
        assertEquals("https://rips.example/rips/analysis/sng_a.json", e.beatgridUrl("https://rips.example"))
    }

    @Test
    fun plainEntry_hasNoStemsNoBeatgrid() {
        val e = json.decodeFromString<RipManifestEntry>("""{"key":"rips/x.mp3","beatgrid":""}""")
        assertNull(e.stemUrls("https://b"))
        assertNull(e.beatgridKey)
        assertNull(e.lyricsKey)
        assertFalse(e.isStemmed)
    }

    @Test
    fun partialStems_decodeButYieldNoUrls() {
        val e = json.decodeFromString<RipManifestEntry>("""{"key":"k","stems":{"vocals":"v"}}""")
        assertNull(e.stemUrls("https://b"))
    }

    @Test
    fun batchStatusMapsPhases() {
        assertEquals("ready", RipPhases.batchStatus("ready"))
        assertEquals("queued", RipPhases.batchStatus("queued"))
        assertEquals("inflight", RipPhases.batchStatus("uploading"))
        assertEquals("inflight", RipPhases.batchStatus("ripping"))
        assertEquals("unknown", RipPhases.batchStatus("error"))
        assertEquals("unknown", RipPhases.batchStatus(null))
    }
}

package com.levi.pocketdj.data.rips

import com.levi.pocketdj.data.PdjJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lenient-decode contract for the rip-server wire types (specs/playback.md §2.2,
 * §4.3): the server adds fields continually — unknown keys must never break a
 * decode, and every field except `key`/`phase` is optional.
 */
class RipsModelsTest {

    private val json = PdjJson.lenient

    @Test
    fun manifestEntry_decodesWithUnknownAndFutureFields() {
        val text = """
            {
              "key": "rips/alb_aaa111bbb222.mp3",
              "ext": "mp3",
              "source": "analog",
              "albumId": "alb_aaa111bbb222",
              "startMs": 215000,
              "durationMs": null,
              "bpm": 118.2,
              "musicalKey": "G minor",
              "camelot": "6A",
              "analyzed": true,
              "rippedAt": 1750000000000,
              "cutKey": "rips/sng_000000000002.cut.mp3",
              "firstBeatMs": 120,
              "beatGridBpm": 118.19,
              "beatgrid": "rips/analysis/sng_000000000002.json",
              "stems": { "vocals": "rips/stems/x/vocals.mp3" },
              "stemVersion": 3,
              "lyrics": "rips/lyrics/sng_000000000002.json",
              "someFieldFromNextWeek": { "nested": [1, 2, 3] }
            }
        """.trimIndent()
        val entry = json.decodeFromString<RipManifestEntry>(text)
        assertEquals("rips/alb_aaa111bbb222.mp3", entry.key)
        assertEquals(215_000L, entry.startMs)
        assertNull(entry.durationMs) // explicit null → Kotlin null
        assertEquals("6A", entry.camelot)
    }

    @Test
    fun manifestDocument_isMapKeyedBySongId() {
        val text = """
            {
              "sng_a": { "key": "rips/sng_a.mp3", "source": "digital" },
              "sng_b": { "key": "rips/alb_1.mp3", "source": "analog", "startMs": 0 }
            }
        """.trimIndent()
        val manifest = json.decodeFromString<RipsManifest>(text)
        assertEquals(2, manifest.size)
        assertEquals("rips/sng_a.mp3", manifest["sng_a"]?.key)
    }

    @Test
    fun jobView_decodesWithOnlyPhase() {
        val job = json.decodeFromString<RipJob>("""{"phase":"queued"}""")
        assertEquals("queued", job.phase)
        assertNull(job.jobId)
        assertNull(job.url)
        assertTrue(!job.isReady)
    }

    @Test
    fun ripTrigger_alreadyRipped_isReadyWithNullJobId() {
        val job = json.decodeFromString<RipJob>(
            """{"jobId":null,"songId":"sng_x","phase":"ready","url":"https://bucket/rips/sng_x.mp3"}""",
        )
        assertTrue(job.isReady)
        assertNull(job.jobId)
        assertEquals("https://bucket/rips/sng_x.mp3", job.url)
    }

    @Test
    fun health_decodesMinimalAndRich() {
        val minimal = json.decodeFromString<RipServerHealth>("""{"ok":true,"version":2}""")
        assertTrue(minimal.ok)
        assertEquals(2, minimal.version)
        val rich = json.decodeFromString<RipServerHealth>(
            """{"ok":true,"host":"imac","version":2,"hls":true,"stems":true,
                "analogBase":"/Volumes/X","bucket":"pocketdj-rips",
                "catalog":{"songs":12345,"albums":678},"cached":9012,
                "auth":true,"public":true,"rateLimit":false}""",
        )
        assertEquals(12_345, rich.catalog?.songs)
        assertEquals(true, rich.hls)
    }
}

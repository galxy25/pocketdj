package com.levi.pocketdj.data.rips

import com.levi.pocketdj.screens.mix.MixWaveform
import com.levi.pocketdj.studio.cues.CueSeek
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AnalogWindowTest {
    private fun e(key: String, start: Long?) = RipManifestEntry(key = key, source = "analog", startMs = start)

    private val manifest = mapOf(
        "lo_1" to e("rips/sideL.mp3", 0),
        "lo_2" to e("rips/sideL.mp3", 240_000),
        "lo_x" to e("rips/other.mp3", 0),
        "dg_1" to RipManifestEntry(key = "rips/dg_1.mp3", source = "digital", durationMs = 200_000),
    )

    private fun tl(layout: SegmentOverrides.Snapshot, id: String = "lo_1") = AlbumFileTimeline.forSong(id, manifest, layout)

    /** iOS testLoneVinylSongEndsAtItsDetectedEndPlusGrace: detected 150 s + 15 s grace. */
    @Test fun loneSongEndsAtDetectedEndPlusGrace() {
        val t = tl(SegmentOverrides.Snapshot(detectedEndMs = mapOf("lo_1" to 150_000)))
        assertEquals(165_000L, AnalogWindow.endMs("lo_1", 0, t, run = null, lengthMs = 150_000))
    }

    @Test fun editedEndIsExactNoGrace() {
        val t = tl(SegmentOverrides.Snapshot(endMs = mapOf("lo_1" to 170_000), detectedEndMs = mapOf("lo_1" to 150_000)))
        assertEquals(170_000L, AnalogWindow.endMs("lo_1", 0, t, lengthMs = 150_000))
    }

    @Test fun cappedAtNextStart() {
        val t = tl(SegmentOverrides.Snapshot(detectedEndMs = mapOf("lo_1" to 238_000)))
        assertEquals(240_000L, AnalogWindow.endMs("lo_1", 0, t, lengthMs = 100_000))
    }

    @Test fun noDetectedEndUsesNextStartAndLastSongRunsToFileEnd() {
        val t = tl(SegmentOverrides.Snapshot())
        assertEquals(240_000L, AnalogWindow.endMs("lo_1", 0, t, lengthMs = 100_000))
        assertNull(AnalogWindow.endMs("lo_2", 240_000, t, lengthMs = 100_000))
    }

    @Test fun noTimelineFallsBackToStartPlusLength() {
        assertEquals(215_000L + 216_000L, AnalogWindow.endMs("x", 215_000, null, lengthMs = 216_000))
        assertNull(AnalogWindow.endMs("x", 215_000, null, lengthMs = null))
        assertNull(AnalogWindow.endMs("x", 215_000, null, lengthMs = 0))
    }

    @Test fun perSongDigitalFileNeverGetsAWindow() {
        assertNull(AnalogWindow.endMs("dg_1", null, null, lengthMs = 200_000))
        assertNull(AnalogWindow.endMs("dg_1", null, tl(SegmentOverrides.Snapshot(), "lo_1"), lengthMs = 200_000))
    }

    @Test fun startMismatchingTheTimelineUsesLength() {
        val t = tl(SegmentOverrides.Snapshot(detectedEndMs = mapOf("lo_2" to 400_000)))
        // a caller start that is not this timeline's segment start (stale / foreign) keeps the old behavior
        assertEquals(500_000L, AnalogWindow.endMs("lo_2", 300_000, t, lengthMs = 200_000))
    }

    @Test fun runRulesFromTheRecord() {
        val t = tl(SegmentOverrides.Snapshot(detectedEndMs = mapOf("lo_1" to 150_000, "lo_2" to 300_000)))!!
        val next = t.segment("lo_2")!!
        assertEquals(240_000L, AnalogWindow.endMs("lo_1", 0, t, AnalogWindow.Run(next = next), 150_000))
        assertNull(AnalogWindow.endMs("lo_2", 240_000, t, AnalogWindow.Run(fromPrevious = true), 100_000))
        assertEquals(315_000L, AnalogWindow.endMs("lo_2", 240_000, t, AnalogWindow.Run(), 100_000))
    }

    @Test fun variantIdResolvesToBase() {
        val t = tl(SegmentOverrides.Snapshot(detectedEndMs = mapOf("lo_1" to 150_000)))
        assertEquals(165_000L, AnalogWindow.endMs("lo_1", 0, t, lengthMs = 1))
    }

    @Test fun lengthMsIsEndMinusStartElseCatalog() {
        val t = tl(SegmentOverrides.Snapshot(detectedEndMs = mapOf("lo_2" to 400_000)))
        assertEquals(175_000L, AnalogWindow.lengthMs("lo_2", 240_000, t, 90_000))
        assertEquals(90_000L, AnalogWindow.lengthMs("lo_2", null, null, 90_000))
        assertEquals(0L, AnalogWindow.lengthMs("lo_2", null, null, null))
    }

    @Test fun playResolverUsesEndOfAndKeepsDefault() {
        val entry = RipManifestEntry(key = "rips/sideL.mp3", source = "analog", startMs = 0, durationMs = 150_000)
        val t = tl(SegmentOverrides.Snapshot(detectedEndMs = mapOf("lo_1" to 150_000)))
        val withEnd = PlayResolver.resolve("lo_1", entry, false, endOf = { id, s, len -> AnalogWindow.endMs(id, s, t, null, len) }) as PlayAction.Stream
        assertEquals(165_000L, withEnd.clipEndMs)
        val legacy = PlayResolver.resolve("lo_1", entry, false) as PlayAction.Stream
        assertEquals(150_000L, legacy.clipEndMs)
    }

    @Test fun cueSeekBoundsCueByEndOnTheRecord() {
        val p = CueSeek.plan(240_000, 90_000, 150_000, endMs = 400_000)
        assertEquals(160_000L, p.durationMs)
        assertEquals(150_000L, p.cueMs)
        assertEquals(400_000L, p.endBoundaryMs)
        // no end => legacy
        assertEquals(90_000L, CueSeek.plan(240_000, 90_000, 150_000).cueMs)
    }

    @Test fun waveformWindowLength() {
        assertEquals(175_000, MixWaveform.windowLengthMs(240_000, 90_000, 415_000))
        assertEquals(90_000, MixWaveform.windowLengthMs(240_000, 90_000, null))
        assertEquals(90_000, MixWaveform.windowLengthMs(240_000, 90_000, 240_000))
    }
}

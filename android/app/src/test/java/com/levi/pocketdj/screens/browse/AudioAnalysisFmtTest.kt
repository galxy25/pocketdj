package com.levi.pocketdj.screens.browse

import com.levi.pocketdj.data.catalog.AudioTrack
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioAnalysisFmtTest {
    @Test fun rowFormatting() {
        val seg = AudioTrack(trackNumber = null, startMs = 61_000, endMs = 185_000, keyStrength = 0.876)
        assertEquals(3, AudioAnalysisFmt.index(seg, 3))
        assertEquals(7, AudioAnalysisFmt.index(seg.copy(trackNumber = 7), 3))
        assertEquals("1:01 – 3:05", AudioAnalysisFmt.range(seg))
        assertEquals("87%", AudioAnalysisFmt.strength(seg))
        assertEquals("–", AudioAnalysisFmt.strength(seg.copy(keyStrength = null)))
    }

    @Test fun totalTruncates() {
        assertEquals("61:01 total", AudioAnalysisFmt.total(3661.9))
        assertEquals(null, AudioAnalysisFmt.total(null))
    }
}

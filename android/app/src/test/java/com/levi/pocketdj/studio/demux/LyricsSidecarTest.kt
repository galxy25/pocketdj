package com.levi.pocketdj.studio.demux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LyricsSidecarTest {
    @Test fun decodesAFullSidecar() {
        val s = TimedLyricsSidecar.parse("""{"version":2,"model":"large-v3","lang":"en","durationMs":181000,
            "words":[{"text":"Hello","startMs":1000,"endMs":1400},{"text":"world","startMs":1500,"endMs":2100}]}""")!!
        assertEquals(2, s.version); assertEquals("large-v3", s.model); assertEquals("en", s.lang); assertEquals(181000, s.durationMs)
        assertEquals(listOf(DemuxWord("Hello", 1000, 1400), DemuxWord("world", 1500, 2100)), s.words)
    }

    @Test fun oneMalformedWordDropsThatWordOnly() {
        val s = TimedLyricsSidecar.parse("""{"words":[
            {"text":"keep","startMs":0,"endMs":100},
            {"text":"no-times"},
            {"startMs":1,"endMs":2},
            {"text":"str-time","startMs":"x","endMs":2},
            7,
            {"text":"also keep","startMs":300.0,"endMs":400}
        ]}""")!!
        assertEquals(listOf("keep", "also keep"), s.words.map { it.text })
        assertEquals(300, s.words[1].startMs)
    }

    @Test fun missingOrWrongTypedWordsArrayIsAnEmptyInstrumentalNotAFailure() {
        assertTrue(TimedLyricsSidecar.parse("{}")!!.words.isEmpty())
        assertTrue(TimedLyricsSidecar.parse("""{"words":"nope","version":"x"}""")!!.words.isEmpty())
        assertNull(TimedLyricsSidecar.parse("""{"words":"nope","version":"x"}""")!!.version)
    }

    @Test fun nonObjectBodiesAreNotSidecars() {
        assertNull(TimedLyricsSidecar.parse("<html>502 Bad Gateway</html>"))
        assertNull(TimedLyricsSidecar.parse("""[{"text":"a","startMs":0,"endMs":1}]"""))
        assertNull(TimedLyricsSidecar.parse(""))
        assertNull(TimedLyricsSidecar.parse("""{"words":[{"text":"a""" ))   // truncated
    }

    @Test fun cloudTranscriptLandsWholesaleWithProvenance() {
        val doc = DemuxDocument(sourceKey = "k", displayName = "K", durationMs = 200_000, words = listOf(DemuxWord("device", 0, 10)), transcriptCoveredMs = 5)
        val out = doc.withCloudTranscript(TimedLyricsSidecar(model = "m", words = listOf(DemuxWord("b", 2000, 2100), DemuxWord("a", 1000, 1100))))
        assertEquals(listOf("a", "b"), out.words.map { it.text })       // sorted, device words replaced
        assertEquals(DemuxArtifactStatus.DONE, out.transcriptStatus)
        assertEquals("cloud", out.transcriptEngine)
        assertEquals(200_000, out.transcriptCoveredMs)
        assertEquals("Transcribed in the cloud (m).", out.transcriptDiag)
        // An empty sidecar is a DONE instrumental (the panel says so), not a failure.
        val inst = doc.withCloudTranscript(TimedLyricsSidecar())
        assertEquals(DemuxArtifactStatus.DONE, inst.transcriptStatus); assertTrue(inst.words.isEmpty()); assertNull(inst.transcriptDiag)
    }

    // ---- lines -----------------------------------------------------------------------------------

    private fun w(t: String, s: Int, e: Int = s + 200) = DemuxWord(t, s, e)

    @Test fun linesBreakAtSilenceGapsAndAtMaxWords() {
        val lines = DemuxLine.lines(listOf(w("a", 0), w("b", 300), w("c", 3_000), w("d", 3_300)))
        assertEquals(listOf("a b", "c d"), lines.map { it.text })
        assertEquals(0, lines[0].startMs); assertEquals(3_500, lines[1].endMs)
        val long = DemuxLine.lines((0 until 30).map { w("w$it", it * 250) }, maxWords = 12)
        assertEquals(listOf(12, 12, 6), long.map { it.words.size })
        assertTrue(DemuxLine.lines(emptyList()).isEmpty())
    }

    @Test fun currentLineAndKaraokeWindow() {
        val lines = DemuxLine.lines(listOf(w("a", 0), w("b", 300), w("c", 3_000), w("d", 3_300)))
        assertEquals(-1, DemuxLine.currentIndex(lines, -5))
        assertEquals(0, DemuxLine.currentIndex(lines, 1_000))
        assertEquals(1, DemuxLine.currentIndex(lines, 3_100))
        assertTrue(DemuxLine.isCurrent(lines[0], 600))
        assertTrue(DemuxLine.isCurrent(lines[0], 500 + 799))
        assertFalse(DemuxLine.isCurrent(lines[0], 500 + 800))   // line end 500 + 800 ms grace
        assertFalse(DemuxLine.isCurrent(lines[1], 1_000))
    }

    // ---- gate + panel state ----------------------------------------------------------------------

    private fun landed() = DemuxDocument(sourceKey = "k", displayName = "K", transcriptStatus = DemuxArtifactStatus.DONE, transcriptEngine = "cloud", words = listOf(w("a", 0)))

    @Test fun panelIsHiddenWhenTheGateIsOffAndThereIsNoCloudTranscript() {
        assertFalse(DemuxFeatures.lyricsPanelVisible(hasCloudSidecar = false, doc = null, gate = false))
        assertFalse(DemuxFeatures.lyricsPanelVisible(false, DemuxDocument(sourceKey = "k", displayName = "K", transcriptEngine = "device", words = listOf(w("a", 0))), gate = false))
        assertTrue(DemuxFeatures.lyricsPanelVisible(false, null, gate = true))
        assertTrue(DemuxFeatures.lyricsPanelVisible(true, null, gate = false))
        assertTrue(DemuxFeatures.lyricsPanelVisible(false, landed(), gate = false))   // offline case: already landed
        assertEquals(LyricsPanelState.Hidden, LyricsPanelState.of(visible = false, fetching = true, doc = landed(), hasCloudSidecar = true))
        assertFalse(DemuxFeatures.lyricsEnabled)    // shipped default
    }

    @Test fun panelStateProjection() {
        assertEquals(LyricsPanelState.Fetching, LyricsPanelState.of(true, true, null, true))
        val lyrics = LyricsPanelState.of(true, false, landed(), true) as LyricsPanelState.Lyrics
        assertEquals(1, lyrics.lines.size)
        assertEquals(LyricsPanelState.Instrumental, LyricsPanelState.of(true, false, landed().copy(words = emptyList()), true))
        assertEquals(LyricsPanelState.Retry, LyricsPanelState.of(true, false, null, true))
        assertEquals(LyricsPanelState.Hidden, LyricsPanelState.of(true, false, null, false))
    }
}

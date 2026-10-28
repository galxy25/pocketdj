package com.levi.pocketdj.screens.producer

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.data.catalog.IndexSong
import com.levi.pocketdj.screens.producer.common.StudioFmt
import com.levi.pocketdj.screens.producer.common.WaveformMath
import com.levi.pocketdj.screens.producer.samples.NewSampleLogic
import com.levi.pocketdj.screens.producer.samples.SampleEditMath
import com.levi.pocketdj.screens.producer.samples.SamplesCopy
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSampleEdit
import com.levi.pocketdj.studio.store.StudioReferrers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProducerLogicTest {
    // ---- sub-tabs -------------------------------------------------------------------------------

    @Test fun sevenSubTabsWithStableRawValues() {
        assertEquals(listOf("samples", "loops", "sequencer", "instruments", "cues", "demuxer", "tracks"), StudioSubTab.entries.map { it.raw })
        assertEquals(7, StudioSubTab.entries.size)
    }

    @Test fun lastSubTabRestoresAndUnknownFallsBackToSamples() {
        assertEquals(StudioSubTab.Cues, StudioSubTab.fromRaw("cues"))
        assertEquals(StudioSubTab.Samples, StudioSubTab.fromRaw("holograms"))
        assertEquals(StudioSubTab.Samples, StudioSubTab.fromRaw(null))
    }

    @Test fun segmentsAreIconOnlyUnder600dp() {
        assertTrue(StudioSubTab.iconOnly(599))
        assertTrue(StudioSubTab.iconOnly(360))
        assertFalse(StudioSubTab.iconOnly(600))
        assertFalse(StudioSubTab.iconOnly(840))
    }

    // ---- editor rules -----------------------------------------------------------------------------

    @Test fun trimStartKeepsFiftyMsOfWindow() {
        val e = StudioSampleEdit(trimEndMs = 0)
        assertEquals(950, SampleEditMath.setTrimStart(e, 5000, 1000).trimStartMs)          // end = file end (1000)
        assertEquals(400, SampleEditMath.setTrimStart(StudioSampleEdit(trimEndMs = 500), 400, 1000).trimStartMs)
        assertEquals(450, SampleEditMath.setTrimStart(StudioSampleEdit(trimEndMs = 500), 480, 1000).trimStartMs)
        assertEquals(0, SampleEditMath.setTrimStart(StudioSampleEdit(trimEndMs = 30), 10, 1000).trimStartMs)
    }

    @Test fun trimEndAtFileEndStoresNeutralZero() {
        assertEquals(0, SampleEditMath.setTrimEnd(StudioSampleEdit(), 1000, 1000).trimEndMs)
        assertEquals(0, SampleEditMath.setTrimEnd(StudioSampleEdit(), 2000, 1000).trimEndMs)
        assertEquals(300, SampleEditMath.setTrimEnd(StudioSampleEdit(trimStartMs = 100), 300, 1000).trimEndMs)
        assertEquals(150, SampleEditMath.setTrimEnd(StudioSampleEdit(trimStartMs = 100), 120, 1000).trimEndMs)   // floor start+50
        assertEquals(1000, SampleEditMath.endDisplayMs(StudioSampleEdit(), 1000))
        assertEquals(300, SampleEditMath.endDisplayMs(StudioSampleEdit(trimEndMs = 300), 1000))
    }

    @Test fun tapTempoNeedsFourTapsAndUsesMedian() {
        var t = SampleEditMath.Tap(emptyList(), null)
        val times = listOf(0.0, 0.5, 1.0, 1.5)
        for ((i, x) in times.withIndex()) {
            t = SampleEditMath.tap(t.taps, x)
            if (i < 3) assertNull(t.bpm)
        }
        assertEquals(120.0, t.bpm!!, 0.0)
        // one flubbed tap does not skew the tempo (median of 0.5,0.5,0.9,0.5,0.5 = 0.5)
        var u = SampleEditMath.Tap(emptyList(), null)
        for (x in listOf(0.0, 0.5, 1.0, 1.9, 2.4)) u = SampleEditMath.tap(u.taps, x)
        assertEquals(120.0, u.bpm!!, 0.0)
    }

    @Test fun tapGapOver2500msStartsAFreshRun() {
        var t = SampleEditMath.Tap(emptyList(), null)
        for (x in listOf(0.0, 0.5, 1.0)) t = SampleEditMath.tap(t.taps, x)
        t = SampleEditMath.tap(t.taps, 10.0)
        assertEquals(listOf(10.0), t.taps)
        assertNull(t.bpm)
    }

    @Test fun tapOutsideSanityWindowGivesNoBpm() {
        var t = SampleEditMath.Tap(emptyList(), null)
        for (x in listOf(0.0, 0.1, 0.2, 0.3)) t = SampleEditMath.tap(t.taps, x)        // 100 ms apart = 600 BPM
        assertNull(t.bpm)
    }

    @Test fun manualBpmParsing() {
        assertEquals(128.5, SampleEditMath.parseBpm("128,5")!!, 0.0)
        assertEquals(20.0, SampleEditMath.parseBpm(" 20 ")!!, 0.0)
        assertNull(SampleEditMath.parseBpm("19.9"))
        assertNull(SampleEditMath.parseBpm("301"))
        assertNull(SampleEditMath.parseBpm("abc"))
    }

    @Test fun measuredGridIsReadOnly() {
        assertTrue(SampleEditMath.isMeasured(StudioGrid(120.0, 0, listOf(0, 500))))
        assertFalse(SampleEditMath.isMeasured(StudioGrid(120.0)))
        assertFalse(SampleEditMath.isMeasured(null))
    }

    // ---- carve sheet --------------------------------------------------------------------------------

    private fun song(id: String, name: String, artist: String) = IndexSong(id = id, artist = artist, name = name)

    @Test fun songSearchBurnedFirstAndTokenMatch() {
        val songs = listOf(song("1", "Blue Monday", "New Order"), song("2", "Blue Jeans", "Lana"), song("3", "Monday Blues", "X"))
        val r = NewSampleLogic.search(songs, "blue", { it == "2" })
        assertEquals(listOf("2", "1", "3"), r.map { it.id })                                  // burned first, then catalog order
        assertEquals(listOf("1"), NewSampleLogic.search(songs, "blue order", { false }).map { it.id })   // every token, title+artist
        assertEquals(listOf("2"), NewSampleLogic.search(songs, "  ", { it == "2" }).map { it.id })       // empty query = burned subset only
        assertTrue(NewSampleLogic.search(songs, "zzz", { true }).isEmpty())
    }

    @Test fun markInOutRespectMinWindow() {
        assertEquals(950, NewSampleLogic.markIn(5000, 1000))
        assertEquals(0, NewSampleLogic.markIn(-5, 1000))
        assertEquals(2000, NewSampleLogic.markOut(5000, 100, 2000))
        assertEquals(150, NewSampleLogic.markOut(0, 100, 2000))
    }

    @Test fun nudgesStayInsideTheSongAndKeepFiftyMs() {
        assertEquals(990 to 2000, NewSampleLogic.nudge(true, -10, 1000, 2000, 5000))
        assertEquals(1010 to 2000, NewSampleLogic.nudge(true, 10, 1000, 2000, 5000))
        assertEquals(0 to 2000, NewSampleLogic.nudge(true, -10, 0, 2000, 5000))
        assertEquals(1950 to 2000, NewSampleLogic.nudge(true, 5000, 1000, 2000, 5000))
        assertEquals(1000 to 5000, NewSampleLogic.nudge(false, 99999, 1000, 2000, 5000))
        assertEquals(1000 to 1050, NewSampleLogic.nudge(false, -5000, 1000, 2000, 5000))
    }

    @Test fun beatNudgeUsesGridTempo() {
        assertEquals(500, NewSampleLogic.beatMs(120.0))
        assertEquals(469, NewSampleLogic.beatMs(128.0))
        assertNull(NewSampleLogic.beatMs(null)); assertNull(NewSampleLogic.beatMs(0.0))
        assertEquals(1500 to 2000, NewSampleLogic.nudge(true, 500, 1000, 2000, 5000))
    }

    @Test fun songLengthPrefersCatalogThenManifest() {
        assertEquals(1234, NewSampleLogic.songLengthMs(1234, 9999))
        assertEquals(9999, NewSampleLogic.songLengthMs(null, 9999))
        assertEquals(9999, NewSampleLogic.songLengthMs(0, 9999))
        assertEquals(1, NewSampleLogic.songLengthMs(null, null))
    }

    @Test fun defaultRegionAndCarveGate() {
        assertEquals(0 to 8000, NewSampleLogic.defaultRegion(200_000))
        assertEquals(0 to 3000, NewSampleLogic.defaultRegion(3000))
        assertTrue(NewSampleLogic.canCarve(0, 50)); assertFalse(NewSampleLogic.canCarve(0, 49))
    }

    // ---- waveform / fmt / copy -----------------------------------------------------------------------

    @Test fun peaksNormaliseToLoudestBucket() {
        val s = FloatArray(1000 * 2) { if (it / 2 in 500..509) 0.5f else 0.05f }
        val p = WaveformMath.peaks(PcmBuffer(44100, 2, s), 10)
        assertEquals(10, p.size)
        assertEquals(1f, p.max(), 0f)
        assertEquals(5, p.indices.maxByOrNull { p[it] })
        assertEquals(0.1f, p[0], 1e-6f)
        assertEquals(1, WaveformMath.peaks(PcmBuffer(44100, 2, FloatArray(0)), 1).size)
    }

    @Test fun handleGrabbingPicksNearestWithinSlop() {
        assertEquals(WaveformMath.Handle.Start, WaveformMath.grab(110f, 100f, 400f, 30f))
        assertEquals(WaveformMath.Handle.End, WaveformMath.grab(380f, 100f, 400f, 30f))
        assertNull(WaveformMath.grab(250f, 100f, 400f, 30f))
        assertEquals(0.25f, WaveformMath.fraction(250f, 1000f), 0f)
        assertEquals(1f, WaveformMath.fraction(5000f, 1000f), 0f)
    }

    @Test fun formatting() {
        assertEquals("1:23.4", StudioFmt.mmssTenths(83_450))
        assertEquals("0:00.0", StudioFmt.mmssTenths(-5))
        assertEquals("1:23", StudioFmt.mmss(83_450))
        assertEquals("120", StudioFmt.trim(120.0)); assertEquals("120.5", StudioFmt.trim(120.5))
        assertEquals(1.05, StudioFmt.snap(1.0489, 0.5, 0.05), 1e-9)
    }

    @Test fun deleteConfirmationListsReferrers() {
        assertTrue(SamplesCopy.deleteMessage("Kick", StudioReferrers(0, 0)).contains("removed from this device"))
        val m = SamplesCopy.deleteMessage("Kick", StudioReferrers(2, 1))
        assertTrue(m.contains("2 loops")); assertTrue(m.contains("1 sequencer row")); assertFalse(m.contains("1 sequencer rows"))
        assertTrue(m.contains("can’t be re-sliced")); assertTrue(m.contains("will be muted")); assertFalse(m.contains("removes those too"))
    }
}

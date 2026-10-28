package com.levi.pocketdj.studio.demux

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioSource
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.TestEnv
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DemuxExportsTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Codec : StudioCodec {
        val windows = ArrayList<String>()
        override fun decode(path: String) = PcmBuffer(44_100, 2, FloatArray(44_100 * 2 * 4) { 0.1f })
        override fun decodeNativeRate(path: String) = decode(path)
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText("m4a") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    private class FakePlayer : StemPlayer {
        val mix = StemMixState()
        override val version = kotlinx.coroutines.flow.MutableStateFlow(0)
        override val isPlaying = false; override val currentTimeSec = 0.0; override val durationSec = 0.0
        override val soloed: String? get() = mix.soloed
        override fun isAudible(name: String) = mix.isAudible(name)
        override fun load(id: String, files: Map<String, File>) = true
        override fun togglePlayPause() {}; override fun seek(sec: Double) {}; override fun stop() {}
        override fun solo(name: String) = mix.solo(name)
        override fun toggleMute(name: String) = mix.toggleMute(name)
    }

    @Test fun stemAuditionMatchesTheEnabledSetEvenWhenSoloedAndRestoresOnDismiss() {
        val p = FakePlayer(); p.solo("vocals")
        val snap = StemAudition.snapshot(p)
        assertEquals("vocals", p.soloed)                       // snapshot leaves the player as it found it
        assertEquals(DemuxStore.STEM_NAMES.toSet(), snap.audible)
        StemAudition.apply(p, DemuxStore.STEM_NAMES.toSet())   // all chips on
        assertNull(p.soloed)
        assertTrue(DemuxStore.STEM_NAMES.all { p.isAudible(it) })   // drums must NOT end up muted
        StemAudition.apply(p, setOf("drums", "bass"))
        assertEquals(setOf("drums", "bass"), DemuxStore.STEM_NAMES.filter { p.isAudible(it) }.toSet())
        StemAudition.restore(p, snap)
        assertEquals("vocals", p.soloed)
        val p2 = FakePlayer(); p2.toggleMute("drums")
        val s2 = StemAudition.snapshot(p2)
        StemAudition.apply(p2, setOf("vocals"))
        StemAudition.restore(p2, s2)
        assertFalse(p2.isAudible("drums")); assertTrue(p2.isAudible("bass"))
    }

    private fun kick(ms: Int, s: Double = 1.0) = DemuxDrumHit(ms, DemuxDrumKind.KICK, s)

    // ---- pure plan ------------------------------------------------------------------------------

    @Test fun hitRegionPicksTheStrongestHitAndCutsAtTheNextOne() {
        val hits = listOf(kick(1_000, 0.4), kick(3_000, 0.9), DemuxDrumHit(3_200, DemuxDrumKind.SNARE, 1.0), DemuxDrumHit(9_000, DemuxDrumKind.KICK, 0.2))
        assertEquals(3_000 to 3_200, DrumPatternExport.hitRegion(DemuxDrumKind.KICK, hits, 10_000))
        // Sparse groove: capped at 500 ms.
        assertEquals(9_000 to 9_500, DrumPatternExport.hitRegion(DemuxDrumKind.KICK, listOf(kick(9_000)), 10_000))
        // Flam: next hit 40 ms later is past the 30 ms flam guard but the region is floored at 60 ms.
        assertEquals(100 to 160, DrumPatternExport.hitRegion(DemuxDrumKind.KICK, listOf(kick(100), DemuxDrumHit(140, DemuxDrumKind.SNARE, 1.0)), 10_000))
        assertNull(DrumPatternExport.hitRegion(DemuxDrumKind.SNARE, listOf(kick(0)), 10_000))
        // Hit at the very end of the file leaves < 20 ms: unusable.
        assertNull(DrumPatternExport.hitRegion(DemuxDrumKind.KICK, listOf(kick(9_990)), 10_000))
    }

    @Test fun bassIsRegionedAgainstTheBassStemOnly() {
        val hits = listOf(DemuxDrumHit(1_000, DemuxDrumKind.BASS, 1.0), kick(1_050), DemuxDrumHit(1_400, DemuxDrumKind.BASS, 0.5))
        assertEquals(1_000 to 1_400, DrumPatternExport.hitRegion(DemuxDrumKind.BASS, hits, 10_000))   // the kick doesn't truncate the bass note
    }

    private fun laneOf(vararg on: Int) = List(16) { it in on }

    @Test fun planConcatenatesBarsPerLaneInLaneOrderAndUsesTheMedianBarForTempo() {
        val bars = listOf(DrumPatternDetector.Bar(0, 0, 2_000), DrumPatternDetector.Bar(1, 2_000, 4_000), DrumPatternDetector.Bar(2, 4_000, 7_000))
        val grid = listOf(
            mapOf(DemuxDrumKind.SNARE to laneOf(4, 12), DemuxDrumKind.KICK to laneOf(0, 8)),
            emptyMap(),
            mapOf(DemuxDrumKind.BASS to laneOf(2)),
        )
        val plan = DrumPatternExport.plan(grid, bars, listOf(0, 1, 2))!!
        assertEquals(listOf(DemuxDrumKind.KICK, DemuxDrumKind.SNARE, DemuxDrumKind.BASS), plan.kinds)
        assertEquals(48, plan.stepCount); assertEquals(3, plan.barCount)
        assertEquals(48, plan.steps.getValue(DemuxDrumKind.KICK).size)
        assertTrue(plan.steps.getValue(DemuxDrumKind.KICK)[0] && plan.steps.getValue(DemuxDrumKind.KICK)[8])
        assertTrue(plan.steps.getValue(DemuxDrumKind.BASS)[32 + 2])           // bar 3's step 2 lands at 34
        assertFalse(plan.steps.getValue(DemuxDrumKind.KICK).drop(16).any { it })   // the empty bar is 16 rests
        assertEquals(120.0, plan.bpm, 0.01)                                   // median bar = 2000 ms
        // One bar only covers just its lanes.
        val one = DrumPatternExport.plan(grid, bars, listOf(2))!!
        assertEquals(listOf(DemuxDrumKind.BASS), one.kinds); assertEquals(16, one.stepCount)
        assertEquals(240_000.0 / 3_000, one.bpm, 0.01)
    }

    @Test fun planIsNullWhenNothingHitAndClampsTempo() {
        val bars = listOf(DrumPatternDetector.Bar(0, 0, 2_000))
        assertNull(DrumPatternExport.plan(listOf(emptyMap()), bars, listOf(0)))
        assertNull(DrumPatternExport.plan(listOf(mapOf(DemuxDrumKind.KICK to laneOf(0))), bars, listOf(5)))   // out-of-range bar
        val fast = DrumPatternExport.plan(listOf(mapOf(DemuxDrumKind.KICK to laneOf(0))), listOf(DrumPatternDetector.Bar(0, 0, 400)), listOf(0))!!
        assertEquals(300.0, fast.bpm, 0.0)
        val slow = DrumPatternExport.plan(listOf(mapOf(DemuxDrumKind.KICK to laneOf(0))), listOf(DrumPatternDetector.Bar(0, 0, 20_000)), listOf(0))!!
        assertEquals(40.0, slow.bpm, 0.0)
    }

    @Test fun cutMathKeepsTheWindowAndNeverDisablesTheLastStem() {
        assertEquals(950, DemuxCutMath.setIn(5_000, 1_000))
        assertEquals(0, DemuxCutMath.setIn(-20, 1_000))
        assertEquals(1_050, DemuxCutMath.setOut(0, 1_000, 5_000))
        assertEquals(5_000, DemuxCutMath.setOut(9_999, 1_000, 5_000))
        assertEquals(setOf("drums"), DemuxCutMath.toggleStem(setOf("drums"), "drums"))
        assertEquals(setOf("drums"), DemuxCutMath.toggleStem(setOf("drums", "bass"), "bass"))
        assertEquals(setOf("drums", "vocals"), DemuxCutMath.toggleStem(setOf("drums"), "vocals"))
        val files = DemuxStore.STEM_NAMES.associateWith { File("/s/$it.mp3") }
        assertEquals(listOf("/s/vocals.mp3", "/s/drums.mp3"), DemuxCutMath.stemPaths(files, setOf("drums", "vocals")))
        val src = DemuxSource.Song("sng_1", "Title", "Artist")
        assertEquals("Artist — Title", DemuxCutMath.sampleName(src, false, emptySet()))
        assertEquals("Artist — Title · vocals+drums", DemuxCutMath.sampleName(src, true, setOf("drums", "vocals")))
    }

    // ---- exporter I/O ---------------------------------------------------------------------------

    private class Fixture(base: File, bank: File? = null) {
        val env = TestEnv(base)
        val store = env.store()
        val codec = Codec()
        val render = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { })
        val exporter = DemuxExporter(env.roots, store, render, takeRenderer = null, bankFor = { bank })
    }

    @Test fun sendBarCarvesAKitSamplePerLaneAndFilesAPatternWithRows() {
        val f = Fixture(tmp.newFolder())
        val src = DemuxSource.Song("sng_1", "Title", "Artist")
        val hits = listOf(kick(0), DemuxDrumHit(500, DemuxDrumKind.SNARE, 1.0), DemuxDrumHit(1_000, DemuxDrumKind.BASS, 1.0))
        val bars = listOf(DrumPatternDetector.Bar(0, 0, 2_000))
        val grid = DrumPatternDetector.stepGrid(hits, bars)
        val plan = DrumPatternExport.plan(grid, bars, listOf(0))!!
        val r = runBlocking { f.exporter.sendDrumPattern(src, hits, 4_000, plan, false, 0, "/d.mp3", "/b.mp3") }
        assertTrue(r.notice, r.ok)
        assertEquals(3, f.store.state.value.samples.size)
        val pattern = f.store.state.value.patterns.single()
        assertEquals("Artist — Title · bar 1", pattern.name)
        assertEquals(16, pattern.stepCount); assertEquals(3, pattern.rows.size)
        assertEquals(f.store.state.value.samples.map { it.id }.toSet(), pattern.rows.map { it.targetId }.toSet())
        val kickRow = pattern.rows[0]
        assertTrue(kickRow.steps[0]); assertEquals(1, kickRow.steps.count { it })
        val s = f.store.state.value.samples.first()
        assertTrue(s.source is StudioSource.Track && (s.source as StudioSource.Track).songId == "sng_1")
        assertEquals(120.0, pattern.bpm, 0.01)
        assertTrue(File(f.env.base, "app/${StudioFamily.SAMPLES.rawValue}").listFiles()!!.size >= 3)
    }

    @Test fun sendAllBarsRaisesTheStepCountToTheFullSongWithoutTruncation() {
        val f = Fixture(tmp.newFolder())
        val bars = (0 until 512).map { DrumPatternDetector.Bar(it, it * 2_000, (it + 1) * 2_000) }
        val hits = bars.map { kick(it.startMs) }
        val grid = DrumPatternDetector.stepGrid(hits, bars)
        val plan = DrumPatternExport.plan(grid, bars, bars.indices.toList())!!
        assertEquals(8_192, plan.stepCount)
        val r = runBlocking { f.exporter.sendDrumPattern(DemuxSource.ImportedFile("dmx_1", "Loop.wav"), hits, 1_100_000, plan, true, 0, "/d.mp3", null) }
        assertTrue(r.notice, r.ok)
        val p = f.store.state.value.patterns.single()
        assertEquals(StudioPattern.MAX_STEP_COUNT, 8_192)
        assertEquals(8_192, p.stepCount)
        assertEquals(8_192, p.rows.single().steps.size)
        assertEquals(512, p.rows.single().steps.count { it })
        assertEquals("Loop.wav · full (512 bars)", p.name)
        assertTrue(f.store.state.value.samples.single().source is StudioSource.File)   // custom source -> file provenance
    }

    @Test fun sendWithoutStemsOrWithUncarvableStemsFilesNothing() {
        val f = Fixture(tmp.newFolder())
        val bars = listOf(DrumPatternDetector.Bar(0, 0, 2_000))
        val plan = DrumPatternExport.plan(DrumPatternDetector.stepGrid(listOf(kick(0)), bars), bars, listOf(0))!!
        val r = runBlocking { f.exporter.sendDrumPattern(DemuxSource.Song("s", "T", ""), listOf(kick(0)), 4_000, plan, false, 0, null, null) }
        assertFalse(r.ok); assertTrue(f.store.state.value.patterns.isEmpty())
        // Bass-only plan with no bass stem: the lane is skipped, nothing to file.
        val bassHits = listOf(DemuxDrumHit(0, DemuxDrumKind.BASS, 1.0))
        val bassPlan = DrumPatternExport.plan(DrumPatternDetector.stepGrid(bassHits, bars), bars, listOf(0))!!
        val r2 = runBlocking { f.exporter.sendDrumPattern(DemuxSource.Song("s", "T", ""), bassHits, 4_000, bassPlan, false, 0, "/d.mp3", null) }
        assertFalse(r2.ok); assertTrue(f.store.state.value.patterns.isEmpty())
    }

    @Test fun savedInstrumentalTakeCarriesTheDemuxProvenanceAndAStaleRenderWhenThePackIsMissing() {
        val f = Fixture(tmp.newFolder())
        val src = DemuxSource.Song("sng_9", "Title", "Artist")
        val content = DemuxInstrumentalContent.Comping(listOf(DemuxChordSegment(0, false, 0, 2_000, 0.9)))
        val r = runBlocking { f.exporter.saveInstrumental(src, content, DemuxInstrumental.Grid(120.0, 0)) }
        assertTrue(r.ok)
        val t = f.store.state.value.takes.single()
        assertEquals("sng_9", t.demuxSourceKey); assertEquals("comping", t.demuxMode)
        assertEquals("Artist — Title · instrumental", t.name)
        assertEquals(120.0, t.bpm, 0.0); assertEquals(3, t.events.size)
        assertEquals(1, t.renderRevision)       // no pack on hand: first play must re-render, never replay silence
        assertNull(t.renderedFileName)
        val mel = runBlocking { f.exporter.saveInstrumental(src, DemuxInstrumentalContent.Melody(listOf(DemuxMelodyNote(60, 0, 500))), DemuxInstrumental.Grid(120.0, 0)) }
        assertTrue(mel.ok)
        assertEquals(listOf("comping", "melody"), f.store.state.value.takes.map { it.demuxMode })
        assertTrue(f.store.state.value.takes[1].name.endsWith("· melody"))
    }

    @Test fun emptyInstrumentalIsRefusedWithCopy() {
        val f = Fixture(tmp.newFolder())
        val src = DemuxSource.Song("s", "T", "A")
        val a = runBlocking { f.exporter.saveInstrumental(src, DemuxInstrumentalContent.Comping(emptyList()), DemuxInstrumental.Grid(120.0, 0)) }
        val b = runBlocking { f.exporter.saveInstrumental(src, DemuxInstrumentalContent.Melody(emptyList()), DemuxInstrumental.Grid(120.0, 0)) }
        assertFalse(a.ok); assertEquals("No chords to build an instrumental from.", a.notice)
        assertFalse(b.ok); assertEquals("No melody to build from.", b.notice)
        assertTrue(f.store.state.value.takes.isEmpty())
    }

    @Test fun cutSampleFilesAFullMixOrAStemMixSampleWithProvenance() {
        val f = Fixture(tmp.newFolder())
        val song = DemuxSource.Song("sng_1", "T", "A")
        val full = runBlocking { f.exporter.cutSample(song, "/audio.m4a", null, "A — T", 1_000, 2_000) }
        assertTrue(full.ok)
        val mixed = runBlocking { f.exporter.cutSample(DemuxSource.ImportedFile("dmx_1", "x.wav"), "/audio.m4a", listOf("/d.mp3", "/b.mp3"), "x.wav · drums+bass", 0, 1_000) }
        assertTrue(mixed.ok)
        val samples = f.store.state.value.samples
        assertEquals(2, samples.size)
        assertEquals(StudioSource.Track("sng_1", 1_000, 2_000), samples[0].source)
        assertEquals(StudioSource.File("x.wav"), samples[1].source)
        assertEquals("x.wav · drums+bass", samples[1].name)
        val bad = runBlocking { f.exporter.cutSample(song, "/audio.m4a", null, "bad", 2_000, 1_000) }   // empty window
        assertFalse(bad.ok); assertEquals(2, f.store.state.value.samples.size)
    }

    @Test fun sendStemsFailsCleanlyForAMissingArrangementAndAddsNothing() {
        val f = Fixture(tmp.newFolder())
        val r = runBlocking { f.exporter.sendStemsToArrangement(ArrangementTarget.Existing("arr_nope"), "X", emptyMap()) }
        assertFalse(r.ok); assertEquals("That arrangement is gone.", r.notice)
        assertNotNull(f.store.state.value)
        assertTrue(f.store.state.value.arrangements.isEmpty())
    }

    @Test fun laneOrderAndLabels() {
        assertEquals(listOf("Kick", "Snare", "Perc", "Other", "Bass"), DrumLanes.ORDER.map { DrumLanes.label(it) })
        assertEquals(listOf(DemuxDrumKind.SNARE, DemuxDrumKind.BASS), DrumLanes.present(listOf(DemuxDrumHit(0, DemuxDrumKind.BASS, 1.0), DemuxDrumHit(1, DemuxDrumKind.SNARE, 1.0))))
    }
}

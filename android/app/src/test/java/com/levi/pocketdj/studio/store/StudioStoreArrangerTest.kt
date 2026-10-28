package com.levi.pocketdj.studio.store

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioArrangementArtifact
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioClipSource
import com.levi.pocketdj.studio.model.StudioDocument
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSample
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class StudioStoreArrangerTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Codec(val ms: Int = 2_000) : StudioCodec {
        override fun decode(path: String) = PcmBuffer(44_100, 2, FloatArray(44_100 * 2 * ms / 1000) { 0.1f })
        override fun decodeNativeRate(path: String) = decode(path)
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText("m4a") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    private fun render(c: StudioCodec = Codec()) = StudioRender(c, ResampleStretcher, Dispatchers.Unconfined, { })

    // ---- ids -----------------------------------------------------------------------------------

    @Test fun arrangerIdsAreNeverStudioIds() {
        for (id in listOf(StudioFactory.newArrangementId(), StudioFactory.newTrackId(), StudioFactory.newClipId())) {
            assertTrue(isArrangerId(id)); assertFalse("$id leaked into studioPrefixes", StudioFactory.isStudioId(id))
        }
        assertTrue(StudioFactory.isStudioId(StudioFactory.newSampleId()))
        assertFalse(isArrangerId(StudioFactory.newSampleId()))
        assertEquals(setOf("smp_", "lp_", "ptn_", "tk_"), StudioFactory.studioPrefixes.toSet())
    }

    // ---- store: file round trips -----------------------------------------------------------------

    @Test fun duplicateTrackCopiesEveryClipFileAndDeleteRemovesOnlyItsOwn() {
        val env = TestEnv(tmp.newFolder()); val s = env.store()
        val a = s.createArrangement("A"); val t = s.addTrack(a.id)!!
        val dir = env.roots.arrangementsDir()
        for (i in 1..3) {
            File(dir, "clip-c$i.m4a").writeText("audio$i")
            s.addClip(a.id, t.id, StudioClip("clip_c$i", "C$i", "clip-c$i.m4a", startMs = i * 1000, durationMs = 900))
        }
        val dup = s.duplicateTrack(a.id, t.id)!!
        val srcFiles = s.arrangement(a.id)!!.tracks[0].clips.map { it.fileName }.toSet()
        val dupFiles = dup.clips.map { it.fileName }.toSet()
        assertEquals(3, dupFiles.size); assertTrue("no shared file", srcFiles.intersect(dupFiles).isEmpty())
        dup.clips.forEachIndexed { i, c -> assertEquals("audio${i + 1}", File(dir, c.fileName).readText()) }
        assertTrue(s.deleteTrack(a.id, t.id))
        assertTrue(srcFiles.none { File(dir, it).exists() })
        assertTrue(dupFiles.all { File(dir, it).exists() })           // the copy survives its original
    }

    @Test fun seedBpmHappensOnceFromTheFirstClipOnly() {
        val env = TestEnv(tmp.newFolder()); val s = env.store()
        s.addSample(StudioSample("smp_a", "A", "a.m4a", false, grid = StudioGrid(128.0)))
        s.addSample(StudioSample("smp_b", "B", "b.m4a", false, grid = StudioGrid(90.0)))
        val a = s.createArrangement("A"); val t = s.addTrack(a.id)!!
        s.addClip(a.id, t.id, StudioClip("clip_1", "1", "clip-1.m4a", source = StudioClipSource.SAMPLE, sourceId = "smp_a"))
        assertEquals(128.0, s.arrangement(a.id)!!.bpm, 0.0)
        s.addClip(a.id, t.id, StudioClip("clip_2", "2", "clip-2.m4a", source = StudioClipSource.SAMPLE, sourceId = "smp_b"))
        assertEquals(128.0, s.arrangement(a.id)!!.bpm, 0.0)
        // A user-set tempo is never overwritten by a seed.
        val b = s.createArrangement("B"); val tb = s.addTrack(b.id)!!
        s.setArrangementBpm(b.id, 100.0)
        s.addClip(b.id, tb.id, StudioClip("clip_3", "3", "clip-3.m4a", source = StudioClipSource.SAMPLE, sourceId = "smp_a"))
        assertEquals(100.0, s.arrangement(b.id)!!.bpm, 0.0)
    }

    @Test fun arrangementsDecodeLeniently() {
        val json = """{"version":1,"arrangements":[
            {"id":"arr_ok","name":"Ok","futureField":{"x":1},"tracks":[
                {"id":"trk_1","name":"T","clips":[{"id":"clip_1","name":"c","fileName":"clip-1.m4a","durationMs":500,"source":"hologram"},42],"colorIndex":3},
                "garbage"]},
            7,
            {"name":"No id"}],
          "arrangementArtifacts":[{"id":"art_1","arrangementId":"arr_ok","kind":"weird","name":"B","fileName":"b.m4a"},"x"]}"""
        val d = StudioDocument.decode(json)!!
        assertEquals(2, d.arrangements.size)                      // the bare number is dropped, the id-less one is minted
        val a = d.arrangements[0]
        assertEquals(1, a.tracks.size); assertEquals(1, a.tracks[0].clips.size)
        assertEquals(StudioClipSource.RECORDING, a.tracks[0].clips[0].source)   // unknown source => recording
        assertEquals(3, a.tracks[0].colorIndex)
        assertTrue(d.arrangements[1].id.startsWith("arr_"))
        assertEquals(StudioArrangementArtifact.Kind.BOUNCE, d.arrangementArtifacts.single().kind)
    }

    @Test fun folderLifecycleRehomesArrangementsAndNeverDeletesThem() {
        val env = TestEnv(tmp.newFolder()); val s = env.store()
        val f = s.createFolder(StudioFolderKind.ARRANGEMENT, "Set 1")
        val a = s.createArrangement("A")
        s.setItemFolder(StudioFolderKind.ARRANGEMENT, a.id, f.id)
        assertEquals(listOf(a.id), s.arrangements(f.id).map { it.id }); assertTrue(s.arrangements(null).isEmpty())
        s.deleteFolder(StudioFolderKind.ARRANGEMENT, f.id)
        assertEquals(listOf(a.id), s.arrangements(null).map { it.id })
        assertTrue(s.arrangementFoldersOrdered().isEmpty())
    }

    // ---- artifacts ---------------------------------------------------------------------------------

    private fun artifact(s: StudioStore, env: TestEnv, id: String, kind: StudioArrangementArtifact.Kind, at: Double): StudioArrangementArtifact {
        val a = s.arrangements.firstOrNull() ?: s.createArrangement("A")
        File(env.roots.arrangementsDir(), "$id.m4a").writeText("bounce-$id")
        return s.addArrangementArtifact(StudioArrangementArtifact(id, a.id, kind, "Bounce $id", "$id.m4a", 2000, at))
    }

    @Test fun artifactCrudNewestFirstAndLookup() {
        val env = TestEnv(tmp.newFolder()); val s = env.store()
        artifact(s, env, "art_1", StudioArrangementArtifact.Kind.BOUNCE, 1.0)
        artifact(s, env, "art_2", StudioArrangementArtifact.Kind.BOUNCE, 2.0)
        artifact(s, env, "art_3", StudioArrangementArtifact.Kind.RECORDING, 3.0)
        val arr = s.arrangements.first().id
        assertEquals(listOf("art_2", "art_1"), s.artifacts(arr, StudioArrangementArtifact.Kind.BOUNCE).map { it.id })
        assertEquals("art_3", s.artifact("art_3")!!.id); assertNull(s.artifact("nope"))
        assertNotNull(s.artifactFile("art_1.m4a"))
        s.deleteArrangementArtifact("art_1")
        assertNull(s.artifact("art_1")); assertNull(s.artifactFile("art_1.m4a"))
    }

    @Test fun createSampleFromArtifactIsAnIndependentSmpCopy() = runBlocking {
        val env = TestEnv(tmp.newFolder()); val s = env.store()
        val art = artifact(s, env, "art_1", StudioArrangementArtifact.Kind.BOUNCE, 1.0)
        val conv = ArtifactSampleConverter(env.roots, s, render(Codec(2_000)), now = { 9.0 })
        val smp = conv.createSampleFromArtifact(art)!!
        assertTrue(smp.id.startsWith("smp_")); assertEquals("Bounce art_1", smp.name); assertEquals(2_000, smp.durationMs)
        val smpFile = env.appFile(StudioFamily.SAMPLES, smp.fileName)
        assertTrue(smpFile.isFile)
        assertNotEquals(File(env.roots.arrangementsDir(), art.fileName).canonicalPath, smpFile.canonicalPath)
        assertNotNull(s.sample(smp.id))
        // Deleting the artifact (or the whole arrangement) leaves the sample and its audio alone.
        s.deleteArrangementArtifact(art.id)
        s.deleteArrangement(art.arrangementId)
        assertTrue(smpFile.isFile); assertNotNull(s.sample(smp.id))
        // A second conversion mints a different sample (no dedupe).
        val art2 = artifact(s, env, "art_2", StudioArrangementArtifact.Kind.RECORDING, 2.0)
        assertNotEquals(smp.id, conv.createSampleFromArtifact(art2)!!.id)
    }

    @Test fun createSampleFromArtifactFailsCleanlyWhenFileGoneOrUnreadable() = runBlocking {
        val env = TestEnv(tmp.newFolder()); val s = env.store()
        val art = artifact(s, env, "art_1", StudioArrangementArtifact.Kind.BOUNCE, 1.0)
        val unreadable = object : StudioCodec {
            override fun decode(path: String): PcmBuffer? = null
            override fun decodeNativeRate(path: String): PcmBuffer? = null
            override fun isProtected(path: String) = false
            override fun writeM4a(pcm: PcmBuffer, file: File) {}
            override fun writeWav(pcm: PcmBuffer, file: File) {}
        }
        assertNull(ArtifactSampleConverter(env.roots, s, render(unreadable)).createSampleFromArtifact(art))
        assertTrue(s.samples.isEmpty()); assertEquals(0, File(env.base, "app/samples").list()?.size ?: 0)
        File(env.roots.arrangementsDir(), art.fileName).delete()
        assertNull(ArtifactSampleConverter(env.roots, s, render()).createSampleFromArtifact(art))
    }

    // ---- pure timeline math --------------------------------------------------------------------------

    @Test fun zoomLadderStepsAndFitFloor() {
        val fit = ArrangerMath.fitPx(lengthMs = 120_000, viewport = 360f)       // (360-28)/120 = 2.77
        assertEquals(332f / 120f, fit, 0.001f)
        assertEquals(72f, ArrangerMath.stepZoom(+1, 48f, fit), 0f)
        assertEquals(240f, ArrangerMath.stepZoom(+1, 240f, fit), 0f)           // clamps at the top
        assertFalse(ArrangerMath.canZoomIn(240f)); assertTrue(ArrangerMath.canZoomIn(48f))
        // Zooming out walks the ladder, then drops to fit (below the ladder floor), then is disabled.
        assertEquals(36f, ArrangerMath.stepZoom(-1, 48f, fit), 0f)
        assertEquals(16f, ArrangerMath.stepZoom(-1, 24f, fit), 0f)
        assertEquals(fit, ArrangerMath.stepZoom(-1, 16f, fit), 0.0001f)
        assertFalse(ArrangerMath.canZoomOut(fit, fit))
        // A short arrangement fits ABOVE the ladder floor: zoom-out lands on the ladder stop, never below fit.
        val shortFit = ArrangerMath.fitPx(5_000, 360f)                        // 66.4
        assertEquals(shortFit, ArrangerMath.stepZoom(-1, 72f, shortFit), 0.0001f)
        assertEquals(16f, ArrangerMath.fitPx(1000, 0f), 0f)                     // unmeasured viewport => floor
    }

    @Test fun anchorsAreBoundedAndCursorAnchorStaysInRange() {
        assertEquals(3, ArrangerMath.anchorSecondsCount(0))                 // never empty: max(1, 0 + 2)
        assertEquals(12, ArrangerMath.anchorSecondsCount(10_000))
        assertEquals(ArrangerMath.MAX_ANCHORS, ArrangerMath.anchorSecondsCount(99_999_999))
    }

    @Test fun followScrollTargetCentersOnlyPastTheFirstScreenful() {
        val px = 48f; val viewport = 400f; val content = ArrangerMath.timelineWidth(60_000, px)
        // Within the first half-screen: no scroll yet.
        assertEquals(0, ArrangerMath.followScrollTarget(2_000, px, viewport, content))
        // Past it: the cursor x sits exactly at the viewport centre.
        val ms = 20_000
        val scroll = ArrangerMath.followScrollTarget(ms, px, viewport, content)
        assertEquals(ms / 1000f * px, scroll + viewport / 2f, 1f)
        // Near the end: clamped so we never scroll past the content.
        assertEquals((content - viewport).toDouble(), ArrangerMath.followScrollTarget(59_000, px, viewport, content).toDouble(), 1.0)
        // Shorter-than-viewport content never scrolls.
        assertEquals(0, ArrangerMath.followScrollTarget(500, px, 5_000f, 560f))
    }

    @Test fun seekCursorAndDropMath() {
        assertEquals(2_500, ArrangerMath.seekMsForX(120f, 48f, 10_000))
        assertEquals(10_000, ArrangerMath.seekMsForX(9_999f, 48f, 10_000))      // clamped to the end
        assertEquals(0, ArrangerMath.seekMsForX(-5f, 48f, 10_000))
        assertEquals(4_000, ArrangerMath.effectiveCursorMs(9_000, 4_000))
        assertEquals(3, ArrangerMath.cursorAnchorSec(3_900, 60_000))
        assertEquals(ArrangerMath.anchorSecondsCount(1_000), ArrangerMath.cursorAnchorSec(999_999, 1_000))
        // Drag drop: free vs beat-snapped (120 bpm => 500 ms beats), never negative.
        assertEquals(1_000, ArrangerMath.dropMs(0, 48f, 48f, false, 120.0))
        assertEquals(1_000, ArrangerMath.dropMs(0, 55f, 48f, true, 120.0))      // 1146 ms -> 1000
        assertEquals(0, ArrangerMath.dropMs(100, -500f, 48f, false, 120.0))
        assertEquals(300, ArrangerMath.snapMs(300, 0.0))                       // no tempo => unchanged
        assertEquals(500, ArrangerMath.snapMs(260, 120.0)); assertEquals(0, ArrangerMath.snapMs(240, 120.0))
        assertEquals(240.0, ArrangerMath.clipX(5_000, 48f).toDouble(), 0.001); assertEquals(0.0, ArrangerMath.clipX(0, 48f, -30f).toDouble(), 0.0)
        assertEquals(10f, ArrangerMath.clipWidth(10, 48f), 0f); assertEquals(96f, ArrangerMath.clipWidth(2_000, 48f), 0f)
    }

    @Test fun beatRulerTicks() {
        // 120 bpm @ 48 px/s => 24 px/beat, 96 px/bar.
        val ticks = ArrangerMath.beatTicks(120.0, 48f, 200f)
        assertEquals(listOf(0f, 24f, 48f, 72f, 96f, 120f, 144f, 168f, 192f), ticks.map { it.x })
        assertEquals(listOf(1, 2, 3), ticks.mapNotNull { it.barNumber })
        assertTrue(ticks[0].isBar && !ticks[1].isBar && ticks[4].isBar)
        // Too dense (< 4 px per beat) or no tempo => no ticks; bar numbers hide when a bar is under 22 px.
        assertTrue(ArrangerMath.beatTicks(300.0, 16f, 500f).isEmpty())          // 3.2 px
        assertTrue(ArrangerMath.beatTicks(0.0, 48f, 500f).isEmpty())
        assertTrue(ArrangerMath.showBarNumbers(120.0, 48f)); assertFalse(ArrangerMath.showBarNumbers(120.0, 8f))
    }

    @Test fun labelsAndPalette() {
        assertEquals("0:00", ArrangerMath.mmss(0.0)); assertEquals("1:05", ArrangerMath.mmss(65.2)); assertEquals("0:00", ArrangerMath.mmss(-3.0))
        val env = TestEnv(tmp.newFolder()); val s = env.store()
        val a = s.createArrangement("A"); s.addTrack(a.id)
        assertEquals("1 track · 0:00", ArrangerMath.summary(s.arrangement(a.id)!!))
        s.addTrack(a.id); assertEquals("2 tracks · 0:00", ArrangerMath.summary(s.arrangement(a.id)!!))
        assertEquals(8, TrackPalette.size); assertEquals("Yellow", TrackPalette.name(8)); assertEquals("Mint", TrackPalette.name(-1))
        assertEquals(StudioStore.TRACK_PALETTE_SIZE, TrackPalette.size)
        assertEquals(0, ArrangerMath.appendStartMs(null))
        assertTrue(Regex("""\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}""").matches(ArrangerMath.artifactStamp()))
    }
}

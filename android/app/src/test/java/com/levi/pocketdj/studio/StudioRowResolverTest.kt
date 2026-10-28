package com.levi.pocketdj.studio

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.playback.PlaybackMode
import com.levi.pocketdj.playback.sequencer.LocalFileSource
import com.levi.pocketdj.playback.sequencer.ManifestRowResolver
import com.levi.pocketdj.playback.sequencer.QueueItem
import com.levi.pocketdj.playback.sequencer.RowResolverRegistry
import com.levi.pocketdj.playback.sequencer.UnplayableSource
import com.levi.pocketdj.studio.engine.StudioStretchKey
import com.levi.pocketdj.studio.model.StudioLoop
import com.levi.pocketdj.studio.model.StudioNoteEvent
import com.levi.pocketdj.studio.model.StudioPattern
import com.levi.pocketdj.studio.model.StudioPatternRow
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StudioRowResolverTest {
    @get:Rule val tmp = TemporaryFolder()
    private val env by lazy { TestEnv(tmp.newFolder("studio")) }
    private val store by lazy { env.store() }

    private class FakeBackend(val env: TestEnv, val onBounce: () -> Unit = {}) : StudioPrepareBackend {
        var bounces = 0
        override suspend fun ensureSampleRendered(sampleId: String) = true
        override suspend fun targetBuffer(targetId: String) = PcmBuffer(44100, 2, FloatArray(8) { 0.1f })
        override suspend fun stretchSpans(pattern: StudioPattern, natural: Map<String, PcmBuffer>) = emptyMap<StudioStretchKey, PcmBuffer>()
        override suspend fun bouncePattern(pattern: StudioPattern, buffers: Map<String, PcmBuffer>, spans: Map<StudioStretchKey, PcmBuffer>): BouncedFile {
            bounces++
            onBounce()
            return BouncedFile(env.write(StudioFamily.SEQUENCES, pattern.id), false)
        }
    }

    private fun addSample(id: String): StudioSample {
        val n = env.write(StudioFamily.SAMPLES, id)
        return store.addSample(StudioSample(id, "Kick", n, durationMs = 500))
    }

    private fun dirtyPattern(id: String, target: String) =
        store.addPattern(StudioPattern.of(id, "Groove", rows = listOf(StudioPatternRow.of(target, steps = List(16) { it % 4 == 0 }))))

    private fun registry(pb: StudioPlayback) = RowResolverRegistry(
        listOf(StudioRowResolver(prepare = { pb.prepare(it) }), ManifestRowResolver { null }),
    )

    @Test fun sampleRowResolvesToItsLocalFileAndNeverReachesTheManifest() = runTest {
        addSample("smp_a")
        val pb = StudioPlayback(store, FakeBackend(env))
        val src = registry(pb).resolve(QueueItem("smp_a"), PlaybackMode.CLOUD)
        val local = (src as LocalFileSource).file
        assertTrue(local.url.startsWith("file:"))
        assertTrue(local.url.endsWith("sample-smp_a.m4a"))
        assertNull(local.startMs); assertNull(local.endMs)
    }

    @Test fun deviceModeStillPlaysStudioRowsButUnknownOnesAreUnplayable() = runTest {
        addSample("smp_a")
        val reg = registry(StudioPlayback(store, FakeBackend(env)))
        assertTrue(reg.resolve(QueueItem("smp_a"), PlaybackMode.DEVICE) is LocalFileSource)
        val gone = reg.resolve(QueueItem("smp_missing"), PlaybackMode.CLOUD)
        assertEquals(UnplayableSource.Reason.STUDIO_LOCAL, (gone as UnplayableSource).reason)
    }

    @Test fun nonStudioRowsPassThroughTheStudioRung() = runTest {
        val r = StudioRowResolver(prepare = { error("must not be asked") })
        assertNull(r.resolve(QueueItem("sng_1"), com.levi.pocketdj.playback.sequencer.ResolveContext(PlaybackMode.CLOUD, false, false)))
    }

    @Test fun dirtyPatternIsBouncedOnDemandThenPlays() = runTest {
        addSample("smp_a"); dirtyPattern("ptn_a", "smp_a")
        assertNull(store.localUrlForPlayback("ptn_a"))
        val be = FakeBackend(env)
        val pb = StudioPlayback(store, be)
        assertTrue(pb.isPlayable("ptn_a"))
        val got = pb.prepare("ptn_a")
        assertNotNull(got)
        assertEquals(1, be.bounces)
        assertFalse(store.pattern("ptn_a")!!.bounceDirty)
        pb.prepare("ptn_a")
        assertEquals(1, be.bounces)   // fresh bounce: no rework
    }

    @Test fun bounceIsNotBlessedWhenThePatternChangedMidRender() = runTest {
        addSample("smp_a"); dirtyPattern("ptn_a", "smp_a")
        val be = FakeBackend(env, onBounce = { store.setPatternBpm("ptn_a", 90.0) })
        val pb = StudioPlayback(store, be)
        assertNull(pb.prepare("ptn_a"))
        assertTrue(store.pattern("ptn_a")!!.bounceDirty)
    }

    @Test fun emptyPatternHasNothingToPrepare() = runTest {
        store.addPattern(StudioPattern.of("ptn_e", "Empty"))
        val pb = StudioPlayback(store, FakeBackend(env))
        assertFalse(pb.isPlayable("ptn_e"))
        assertNull(pb.prepare("ptn_e"))
    }

    @Test fun infoForCarriesRealLengthBpmKindAndKey() {
        val n = env.write(StudioFamily.LOOPS, "lp_a")
        store.addLoop(StudioLoop("lp_a", "Beat", "smp_a", bpm = 100.0, lengthMs = 4000, frames = 176400, fileName = n))
        store.setCamelot("9A", "lp_a")
        val i = StudioPlayback(store, FakeBackend(env)).infoFor("lp_a")!!
        assertEquals(4000, i.lengthMs); assertEquals(100.0, i.bpm!!, 0.0); assertEquals("Loop", i.kindLabel); assertEquals("9A", i.camelot)
        assertNull(StudioPlayback(store, FakeBackend(env)).infoFor("sng_1"))
    }

    @Test fun keyDetectorFindsCMajorFromNotesAndFromSyntheticAudio() {
        fun ev(note: Int) = StudioNoteEvent(onMs = 0, offMs = 1000, note = note, velocity = 90)
        val cMajor = listOf(60, 62, 64, 65, 67, 69, 71, 60, 64, 67).map(::ev)
        assertEquals("8B", KeyDetector.detect(cMajor)!!.camelot)
        assertNull(KeyDetector.detect(emptyList<StudioNoteEvent>()))
        // A-minor triad tone (A3 C4 E4) 3 s mono.
        val sr = 44100
        val s = FloatArray(sr * 3) { i -> listOf(220.0, 261.63, 329.63).sumOf { kotlin.math.sin(2 * Math.PI * it * i / sr) }.toFloat() * 0.2f }
        val k = KeyDetector.detect(PcmBuffer(sr, 1, s))
        assertEquals("8A", k!!.camelot)
        assertNull(KeyDetector.detect(PcmBuffer(sr, 1, FloatArray(100))))
    }

    @Test fun analyzerStoresKeyOnceFromTakeNotes() = runTest {
        val n = env.write(StudioFamily.TAKES, "tk_a")
        val ev = listOf(60, 64, 67).map { StudioNoteEvent(0, 500, it, 90) }
        store.addTake(com.levi.pocketdj.studio.model.StudioTake("tk_a", "T", fileName = n, events = ev, durationMs = 500))
        val an = StudioAnalyzer(store, StudioPlayback(store, FakeBackend(env))) { null }
        an.ensureKey("tk_a")
        assertEquals("8B", store.camelot("tk_a"))
        store.setCamelot("1A", "tk_a"); an.ensureKey("tk_a")
        assertEquals("1A", store.camelot("tk_a"))   // idempotent
    }

    @Test fun rowOnDeviceProbeIsCheapAndHonest() = runTest {
        // A record whose file was deleted outside the app is NOT on the device (no hop target).
        val n = env.write(StudioFamily.SAMPLES, "smp_gone")
        store.addSample(StudioSample("smp_gone", "Gone", n, durationMs = 500))
        java.io.File(tmp.root, "studio").walkTopDown().filter { it.name == n }.forEach { it.delete() }
        addSample("smp_here"); addSample("smp_t"); dirtyPattern("ptn_d", "smp_t")
        val be = FakeBackend(env)
        val pb = StudioPlayback(store, be)
        assertFalse(pb.isOnDeviceNow("smp_gone"))
        assertTrue(pb.isOnDeviceNow("smp_here"))
        assertFalse(pb.isOnDeviceNow("ptn_d"))   // dirty pattern would block on a bounce: never a stall-hop target
        assertEquals(0, be.bounces)              // the probe never prepares
        pb.prepare("ptn_d")
        assertTrue(pb.isOnDeviceNow("ptn_d"))
    }

    @Test fun addingAStudioIdFiresTheAnalyzerSeamOncePerStudioId() {
        val f = tmp.newFile("c.json")
        val cs = com.levi.pocketdj.data.collections.CollectionsStore(f)
        val p = cs.createPocket("P")
        val seen = ArrayList<List<String>>()
        cs.onStudioIdsAdded = { seen += it }
        val t = com.levi.pocketdj.data.collections.AddTarget(com.levi.pocketdj.data.collections.AddTarget.Kind.POCKET, p.id)
        cs.addSong("smp_a", t)
        cs.addSongs(listOf("sng_1", "lp_b", "lp_b"), t)
        assertEquals(listOf(listOf("smp_a"), listOf("lp_b")), seen)
    }

    @Test fun analyzerPrepareStoresAKeyForATake() = runTest {
        val n = env.write(StudioFamily.TAKES, "tk_k")
        val ev = listOf(60, 64, 67).map { StudioNoteEvent(0, 500, it, 90) }
        store.addTake(com.levi.pocketdj.studio.model.StudioTake("tk_k", "T", fileName = n, events = ev, durationMs = 500))
        StudioAnalyzer(store, StudioPlayback(store, FakeBackend(env))) { null }.prepare("tk_k")
        assertEquals("8B", store.camelot("tk_k"))
    }
}

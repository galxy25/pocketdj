package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.OfflineRenderer
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioCodec
import com.levi.pocketdj.studio.audio.StudioRender
import com.levi.pocketdj.studio.model.StudioFactory
import com.levi.pocketdj.studio.model.StudioSample
import com.levi.pocketdj.studio.model.StudioSampleEdit
import com.levi.pocketdj.studio.store.StudioFamily
import com.levi.pocketdj.studio.store.StudioFolders
import com.levi.pocketdj.studio.store.TestEnv
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.math.abs
import kotlin.math.max

class StudioEngineTest {
    @get:Rule val tmp = TemporaryFolder()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @After fun tearDown() { AudioFocusPolicy.endMicCapture(); scope.cancel() }

    /** 1 s constant-amplitude stereo buffer: every frame is `v`, so position/gain are directly readable. */
    private fun flat(frames: Int, v: Float = 0.5f) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { v })

    /** Frames whose value encodes their index (ramp), to prove WHICH frames play. */
    private fun ramp(frames: Int) = PcmBuffer(44_100, 2, FloatArray(frames * 2) { (it / 2) / frames.toFloat() })

    private fun pullAll(src: SampleAuditionSource, frames: Int): FloatArray {
        val out = FloatArray(frames * 2); var done = 0
        val block = FloatArray(512 * 2)
        while (done < frames) {
            java.util.Arrays.fill(block, 0f)
            val n = src.pull(block, minOf(512, frames - done))
            if (n <= 0) break
            System.arraycopy(block, 0, out, done * 2, n * 2); done += n
        }
        return out.copyOf(done * 2)
    }

    @Test fun playsOnlyTheTrimWindowThenReportsEnd() {
        val raw = ramp(44100)                                   // 1 s
        val src = SampleAuditionSource(raw, StudioSampleEdit(trimStartMs = 250, trimEndMs = 750))
        val out = pullAll(src, 44100)
        assertEquals(22050, out.size / 2)                       // exactly 500 ms
        assertEquals(raw.samples[11025 * 2], out[0], 1e-6f)     // starts at 250 ms
        assertTrue(src.reachedEnd)
        assertEquals(0.25 to 0.75, src.windowSeconds().let { (a, b) -> Math.round(a * 1000) / 1000.0 to Math.round(b * 1000) / 1000.0 })
    }

    @Test fun trimEndZeroMeansEndOfFile() {
        val src = SampleAuditionSource(flat(1000), StudioSampleEdit(trimStartMs = 0, trimEndMs = 0))
        assertEquals(1000, pullAll(src, 5000).size / 2)
    }

    @Test fun gainIsAppliedLive() {
        val src = SampleAuditionSource(flat(44100, 0.5f), StudioSampleEdit())
        val a = FloatArray(512 * 2); src.pull(a, 512)
        assertEquals(0.5f, a[10], 1e-6f)
        src.applyEdit(StudioSampleEdit(gainDb = -6.0206))
        val b = FloatArray(512 * 2); src.pull(b, 512)
        assertEquals(0.25f, b[10], 1e-3f)
    }

    @Test fun tighteningOutPointMidAuditionEndsAtNewMark() {
        val src = SampleAuditionSource(flat(44100), StudioSampleEdit())
        pullAll(src, 2000)
        src.applyEdit(StudioSampleEdit(trimEndMs = 100))        // 4410 frames
        val rest = pullAll(src, 44100)
        assertEquals(4410 - 2000 - 0, rest.size / 2 + 0)
        assertTrue(src.reachedEnd)
    }

    @Test fun rateReshapeShortensWindowAndKeepsSourcePosition() {
        val src = SampleAuditionSource(flat(44100), StudioSampleEdit())
        pullAll(src, 11025)                                      // 250 ms into the source
        assertTrue(src.applyEdit(StudioSampleEdit(rate = 2.0)))  // needs a reshape
        src.reshape()
        assertEquals(0.25, src.playheadSeconds(), 0.001)         // same place in the SOURCE
        val rest = pullAll(src, 44100)
        assertEquals(16538.0, (rest.size / 2).toDouble(), 1.0)   // 750 ms of source at 2x = 375 ms (+-1 frame rounding)
        assertFalse(src.applyEdit(StudioSampleEdit(rate = 2.0, gainDb = -3.0)))  // gain alone needs no reshape
    }

    @Test fun playheadAdvancesInSourceSecondsAtRate() {
        val src = SampleAuditionSource(flat(88200), StudioSampleEdit(rate = 2.0))
        pullAll(src, 22050)                                      // 0.5 s of output at 2x = 1.0 s of source
        assertEquals(1.0, src.playheadSeconds(), 0.001)
    }

    @Test fun loopWrapsAtWindowEdges() {
        val src = SampleAuditionSource(ramp(1000), StudioSampleEdit(trimStartMs = 0, trimEndMs = 0))
        src.loop = true
        val out = pullAll(src, 2500)
        assertEquals(2500, out.size / 2)
        assertFalse(src.reachedEnd)
        assertEquals(out[0], out[1000 * 2], 1e-6f)               // seam: frame 1000 == frame 0
        src.loop = false
        assertTrue(pullAll(src, 5000).size / 2 <= 1000)
    }

    @Test fun sliceIsSelfContainedAndNeverMovesTheTrimWindow() {
        val raw = ramp(44100)
        val src = SampleAuditionSource(raw, StudioSampleEdit(trimStartMs = 500, trimEndMs = 900))
        val before = src.windowSeconds()
        assertTrue(src.playSlice(100, 200))
        val out = pullAll(src, 44100)
        assertEquals(4410, out.size / 2)
        assertEquals(raw.samples[4410 * 2], out[0], 1e-6f)
        assertEquals(before, src.windowSeconds())
        assertTrue(src.reachedEnd)
        src.rewind()                                             // transport returns to the trim window head
        assertEquals(0.5, src.playheadSeconds(), 0.001)
        assertFalse(src.isSlice)
    }

    @Test fun zeroFrameSliceIsRefused() {
        val src = SampleAuditionSource(flat(1000), StudioSampleEdit())
        assertFalse(src.playSlice(10, 10))
        assertFalse(src.playSlice(20, 10))
        assertFalse(src.playSlice(5000, 6000))                   // past the end of a 1000-frame file
    }

    @Test fun reverbTailRingsOutThenFinishes() {
        val src = SampleAuditionSource(flat(2000, 0.5f), StudioSampleEdit(reverbWet = 0.8))
        val body = pullAll(src, 2000)
        assertEquals(2000, body.size / 2)
        val tail = FloatArray(512 * 2); src.pull(tail, 512)
        assertTrue("reverb tail should still be audible", tail.any { abs(it) > 1e-4f })
        var guard = 0
        while (!src.finished && guard++ < 400) src.pull(FloatArray(512 * 2), 512)
        assertTrue(src.finished)
        assertEquals(0, src.pull(FloatArray(1024), 512))
    }

    @Test fun neutralEditHasNoTail() {
        val src = SampleAuditionSource(flat(100), StudioSampleEdit())
        pullAll(src, 5000)
        src.pull(FloatArray(1024), 512)
        assertTrue(src.finished)
    }

    @Test fun seekClampsIntoTheWindow() {
        val src = SampleAuditionSource(flat(44100), StudioSampleEdit(trimStartMs = 200, trimEndMs = 600))
        src.seek(0.0); assertEquals(0.2, src.playheadSeconds(), 0.001)
        src.seek(5.0); assertEquals(0.6, src.playheadSeconds(), 0.001)
    }

    // ---- engine ---------------------------------------------------------------------------------

    private fun sample(id: String = StudioFactory.newSampleId(), edit: StudioSampleEdit = StudioSampleEdit()) =
        StudioSample(id = id, name = "s", fileName = StudioFolders.fileName(StudioFamily.SAMPLES, id), edit = edit)

    private fun engine(sink: OfflineRenderer = OfflineRenderer(), focus: (() -> Boolean)? = null) =
        StudioEngine({ sink }, ResampleStretcher, scope, focus)

    private fun waitFor(ms: Long = 3000, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) { if (cond()) return true; Thread.sleep(10) }
        return cond()
    }

    @Test fun playbackCannotStartWhileMicCaptureActive() {
        val sink = OfflineRenderer(); val e = engine(sink)
        e.loadSample(sample(), flat(44100))
        AudioFocusPolicy.beginMicCapture()
        assertFalse(e.playSample())
        assertEquals("mic-capture-active", e.lastRefusal)
        assertFalse(e.isPlayingSample.value)
        assertFalse(sink.isRendering)
        assertFalse(e.playSlice(0, 100))
        AudioFocusPolicy.endMicCapture()
        assertTrue(e.playSample())
        assertNull(e.lastRefusal)
        assertTrue(sink.isRendering)
        e.release()
    }

    @Test fun focusDeniedRefusesPlay() {
        val e = engine(focus = { false })
        e.loadSample(sample(), flat(44100))
        assertFalse(e.playSample()); assertEquals("no-focus", e.lastRefusal)
        e.release()
    }

    @Test fun playRefusedWithoutASample() {
        val e = engine()
        assertFalse(e.playSample()); assertEquals("no-sample", e.lastRefusal)
    }

    @Test fun audibleOutputThenAutoStopAtTheOutPoint() {
        val sink = OfflineRenderer(); val e = engine(sink)
        e.loadSample(sample(edit = StudioSampleEdit(trimEndMs = 100)), flat(44100, 0.5f))
        assertTrue(e.playSample())
        val pcm = sink.renderFrames(2000)
        assertEquals(0.5f, pcm[100], 1e-3f)
        sink.renderFrames(10000)                                 // run past the 100 ms window
        assertTrue(waitFor { !e.isPlayingSample.value })
        assertTrue(waitFor { !sink.isRendering })                // sink parked after the tail
        e.release()
    }

    @Test fun liveEditChangesHitTheNextBlockWithoutReload() {
        val sink = OfflineRenderer(); val e = engine(sink)
        e.loadSample(sample(), flat(44100, 0.5f))
        e.playSample()
        assertEquals(0.5f, sink.renderFrames(600)[500], 1e-3f)
        e.applyEdit(StudioSampleEdit(gainDb = -6.0206))
        assertEquals(0.25f, sink.renderFrames(600)[500], 2e-3f)
        e.release()
    }

    @Test fun rateEditReshapesAsyncWithoutMovingTheSourcePlayhead() {
        val sink = OfflineRenderer(); val e = engine(sink)
        e.loadSample(sample(), flat(88200))
        e.playSample()
        sink.renderFrames(4410)
        e.applyEdit(StudioSampleEdit(rate = 2.0))
        assertTrue(waitFor { abs(e.samplePlayheadSeconds() - 0.1) < 0.01 })
        // After the reshape the output keeps flowing (2x: window is half as long)
        assertNotNull(e.sampleWindowSeconds())
        e.release()
    }

    @Test fun loadingAnotherSampleReplacesTheFirst() {
        val e = engine()
        val a = sample(); val b = sample()
        e.loadSample(a, flat(1000)); assertEquals(a.id, e.loadedSampleId.value)
        e.loadSample(b, flat(2000)); assertEquals(b.id, e.loadedSampleId.value)
        assertEquals(2000 / 44100.0, e.sampleDurationSeconds, 1e-9)
        e.unloadSample(); assertNull(e.loadedSampleId.value)
        e.release()
    }

    @Test fun loopAuditionTogglePropagates() {
        val e = engine()
        e.loadSample(sample(), flat(1000))
        e.setSampleLoopAudition(true); assertTrue(e.sampleLooping.value)
        e.unloadSample(); assertFalse(e.sampleLooping.value)
        e.release()
    }

    // ---- render cache ---------------------------------------------------------------------------

    private class CountingCodec(val pcm: PcmBuffer) : StudioCodec {
        var writes = 0
        override fun decode(path: String) = pcm
        override fun decodeNativeRate(path: String) = pcm
        override fun isProtected(path: String) = false
        override fun writeM4a(pcm: PcmBuffer, file: File) { writes++; file.writeText("m4a$writes") }
        override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("wav") }
    }

    @Test fun renderCacheRegeneratesOnlyWhenRevisionMoved() = runBlocking {
        val env = TestEnv(tmp.newFolder("env"))
        val store = env.store()
        val id = "smp_cache-1"
        val raw = env.write(StudioFamily.SAMPLES, id)
        store.addSample(sample(id).copy(fileName = raw, durationMs = 1000))
        val codec = CountingCodec(flat(44100))
        val cache = SampleRenderCache(env.roots, store, StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { }))

        // neutral edit: raw file plays as-is, nothing rendered
        assertEquals(raw, cache.playableFile(id)!!.name)
        assertEquals(0, codec.writes)

        store.updateSampleEdit(id, StudioSampleEdit(gainDb = -3.0))
        assertEquals(1, store.sample(id)!!.renderRevision)
        val f1 = cache.playableFile(id)!!
        assertEquals(StudioFolders.renderedSampleFileName(id, 1), f1.name)
        assertEquals(1, codec.writes)

        // Save with nothing changed -> no re-render
        store.updateSampleEdit(id, StudioSampleEdit(gainDb = -3.0))
        cache.playableFile(id); cache.playableFile(id)
        assertEquals(1, codec.writes)

        // edit again -> exactly one new render, stale revision file removed
        store.updateSampleEdit(id, StudioSampleEdit(gainDb = -6.0))
        val f2 = cache.playableFile(id)!!
        assertEquals(StudioFolders.renderedSampleFileName(id, 2), f2.name)
        assertEquals(2, codec.writes)
        assertFalse(f1.exists())

        // cache file vanished -> re-render even though revision is unchanged
        f2.delete()
        cache.playableFile(id)
        assertEquals(3, codec.writes)
        assertTrue(cache.needsRender(store.sample(id)!!).not())

        // back to neutral: raw plays, cache no longer needed
        store.updateSampleEdit(id, StudioSampleEdit())
        assertEquals(raw, cache.playableFile(id)!!.name)
        assertEquals(3, codec.writes)
    }
}

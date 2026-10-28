package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.dsp.MasterFxKernel
import com.levi.pocketdj.studio.dsp.MasterFxParams
import com.levi.pocketdj.studio.dsp.TrackFx
import com.levi.pocketdj.studio.dsp.TrackFxKernel
import com.levi.pocketdj.studio.dsp.TrackFxParams
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioChannelStrip
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioMasterFX
import com.levi.pocketdj.studio.model.StudioTrack
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

private const val SR = 44_100

/** Constant-value stereo PCM (L, R) of [frames] frames. */
private fun const(frames: Int, l: Float, r: Float = l): PcmBuffer =
    PcmBuffer(SR, 2, FloatArray(frames * 2) { if (it % 2 == 0) l else r })

private fun ctx(master: MasterFxKernel? = null, fx: () -> TrackFx = { TrackFxKernel(SR.toDouble(), 2) }) =
    MultitrackRenderContext(newTrackFx = fx, master = master ?: MasterFxKernel(SR.toDouble(), 2))

class MultitrackRenderTest {
    private fun clip(ti: Int, start: Int, len: Int, v: Float, srcStart: Int = 0) =
        MultitrackRenderContext.Clip(ti, start, len, srcStart, const(len + srcStart, v).samples)

    private fun pull(c: MultitrackRenderContext, frames: Int) = FloatArray(frames * 2).also { c.render(it, frames) }

    @Test fun gainAndCentreUnityPanLaw() {
        val c = ctx()
        c.load(listOf(clip(0, 0, 100, 0.5f)), 1, 0, false, 0, 0)
        c.setTrackMix(0, 0.5f, 0.6f) // pan right: left attenuated to 1-0.6, right stays unity
        val o = pull(c, 10)
        assertEquals(0.5f * 0.5f * 0.4f, o[0], 1e-6f)
        assertEquals(0.5f * 0.5f * 1.0f, o[1], 1e-6f)
        c.setTrackMix(0, 1f, -0.25f) // pan left: right = 1 + p
        val o2 = pull(c, 10)
        assertEquals(0.5f, o2[0], 1e-6f)
        assertEquals(0.5f * 0.75f, o2[1], 1e-6f)
    }

    @Test fun fileStartWindowPlaysFromSrcStartNotZero() {
        // Source: first 50 frames = 0.1, next 50 = 0.9. Window starts at file frame 50.
        val src = FloatArray(200) { if (it / 2 < 50) 0.1f else 0.9f }
        val w = MultitrackPlayer.clipWindow(bufFrames = 100, fileStartMs = 1, durationMs = 0, rate = 50_000)
        assertEquals(50, w.srcStart); assertEquals(50, w.frameLength)
        val c = ctx()
        c.load(listOf(MultitrackRenderContext.Clip(0, 10, w.frameLength, w.srcStart, src)), 1, 0, false, 0, 0)
        c.setTrackMix(0, 1f, 0f)
        val o = pull(c, 70)
        assertEquals(0f, o[2 * 9], 0f)          // before the clip
        assertEquals(0.9f, o[2 * 10], 1e-6f)    // first clip frame = file frame 50
        assertEquals(0.9f, o[2 * 59], 1e-6f)
        assertEquals(0f, o[2 * 60], 0f)         // clip ended
    }

    @Test fun clipWindowClampsToBuffer() {
        val w = MultitrackPlayer.clipWindow(bufFrames = 1000, fileStartMs = 5_000, durationMs = 100, rate = SR)
        assertEquals(1000, w.srcStart); assertEquals(0, w.frameLength)
        val w2 = MultitrackPlayer.clipWindow(bufFrames = 44_100, fileStartMs = 0, durationMs = 5_000, rate = SR)
        assertEquals(44_100, w2.frameLength)
    }

    @Test fun loopWrapIsContinuousAcrossBlocks() {
        // Ramp clip: frame index as value; loop 100..200.
        val n = 400
        val ramp = FloatArray(n * 2) { (it / 2) / 1000f }
        val c = ctx()
        c.load(listOf(MultitrackRenderContext.Clip(0, 0, n, 0, ramp)), 1, 100, true, 100, 200)
        c.setTrackMix(0, 1f, 0f)
        val all = FloatArray(0).toMutableList()
        repeat(7) { all += pull(c, 37).toList() } // 259 frames, odd block size crossing the wrap
        for (i in 0 until 259) {
            val expectFrame = 100 + i % 100
            assertEquals("frame $i", expectFrame / 1000f, all[2 * i], 1e-6f)
        }
        assertEquals(100 + 259 % 100, c.cursorFrame)
    }

    @Test fun seekHeadTrimsAStraddlingClip() {
        val ramp = FloatArray(400) { (it / 2) / 1000f }
        val c = ctx()
        c.load(listOf(MultitrackRenderContext.Clip(0, 0, 200, 0, ramp)), 1, 150, false, 0, 0) // seek mid-clip
        c.setTrackMix(0, 1f, 0f)
        val o = pull(c, 100)
        assertEquals(0.150f, o[0], 1e-6f)      // plays from the in-clip offset, not the clip head
        assertEquals(0.199f, o[2 * 49], 1e-6f)
        assertEquals(0f, o[2 * 50], 0f)
    }

    private class Identity : TrackFx {
        override var active = false
        override fun update(p: TrackFxParams) { active = p.active }
        override fun reset() {}
        override fun process(data: Array<FloatArray>, frames: Int) {}
    }

    @Test fun fxNeutralFastPathEqualsKernelPathAtUnity() {
        val clips = listOf(clip(0, 0, 500, 0.3f), clip(0, 200, 500, 0.2f))
        val fast = ctx { Identity() }
        fast.load(clips, 1, 0, false, 0, 0); fast.setTrackMix(0, 0.8f, 0.3f)
        val slow = ctx { Identity() }
        slow.load(clips, 1, 0, false, 0, 0); slow.setTrackMix(0, 0.8f, 0.3f)
        slow.setTrackFx(0, TrackFxParams(eqLowDb = 6.0)) // forces the scratch path; identity kernel = unity
        val a = pull(fast, 700); val b = pull(slow, 700)
        for (i in a.indices) assertEquals("i=$i", a[i], b[i], 1e-6f)
    }

    @Test fun activeTrackFxChangesAudioNeutralDoesNot() {
        val c = ctx()
        c.load(listOf(clip(0, 0, 2000, 0.4f)), 1, 0, false, 0, 0); c.setTrackMix(0, 1f, 0f)
        val dry = pull(c, 1000)
        val c2 = ctx()
        c2.load(listOf(clip(0, 0, 2000, 0.4f)), 1, 0, false, 0, 0); c2.setTrackMix(0, 1f, 0f)
        c2.setTrackFx(0, TrackFxParams(eqHighDb = 12.0, eqLowDb = -12.0))
        val wet = pull(c2, 1000)
        assertTrue(dry.indices.any { Math.abs(dry[it] - wet[it]) > 1e-3f })
    }

    @Test fun staleFreezeNeverSilencesPlayback() {
        val stale = StudioMasterFX(freezeEnabled = true)
        assertFalse(stale.anyEffectEnabled)
        val p = stale.toKernelParams(120.0, allowFreeze = false)
        assertFalse(p.freeze); assertFalse(p.active)
        val c = ctx()
        c.load(listOf(clip(0, 0, 1000, 0.5f)), 1, 0, false, 0, 0); c.setTrackMix(0, 1f, 0f)
        c.setMasterFx(p)
        val o = pull(c, 500)
        assertEquals(0.5f, o[0], 1e-6f); assertEquals(0.5f, o[2 * 499], 1e-6f)
        // The iOS-shaped opt-in still works for callers that own a Freezer.
        assertTrue(stale.toKernelParams(120.0, allowFreeze = true).freeze)
    }

    @Test fun masterGainAppliesLive() {
        val c = ctx()
        c.load(listOf(clip(0, 0, 1000, 0.25f)), 1, 0, false, 0, 0); c.setTrackMix(0, 1f, 0f)
        c.setMasterFx(StudioMasterFX(masterGainDb = 6.0).toKernelParams(120.0, false))
        val o = pull(c, 100)
        assertEquals(0.25f * Math.pow(10.0, 6 / 20.0).toFloat(), o[40], 5e-3f)
    }

    @Test fun peakLimiterKeepsOutputInRange() {
        val c = ctx()
        c.load(listOf(clip(0, 0, 1000, 0.9f), clip(1, 0, 1000, 0.9f)), 2, 0, false, 0, 0)
        c.setTrackMix(0, 1f, 0f); c.setTrackMix(1, 1f, 0f)
        val o = pull(c, 500)
        assertTrue(o.all { Math.abs(it) <= 1f })
        assertTrue(o[0] > 0.9f) // instant attack, not a hard mute
    }

    @Test fun beatSyncedBassPhaseStartsAtTheSeekCursor() {
        val total = 12 * SR
        val tone = FloatArray(total * 2) { 0.4f }
        val brazil = MasterFxParams(brazil = true, brazilAmount = 0.9, bpm = 120.0)
        fun make(cursor: Int): MultitrackRenderContext {
            val c = ctx()
            c.load(listOf(MultitrackRenderContext.Clip(0, 0, total, 0, tone)), 1, cursor, false, 0, 0)
            c.setTrackMix(0, 1f, 0f); c.setMasterFx(brazil)
            return c
        }
        val seekAt = 10 * SR + 5000 // mid-beat, so a wrong phase base cannot coincide
        val seek = make(seekAt)
        assertEquals(seekAt.toLong(), seek.totalRendered)
        val fromSeek = pull(seek, 4096)
        val linear = make(0)
        var left = seekAt
        while (left > 0) { val n = minOf(left, 4096); pull(linear, n); left -= n }
        val atTen = pull(linear, 4096)
        // The sub low-pass starts cold on a seek: compare once it has settled (beat-envelope phase is what matters).
        for (i in 2 * 2048 until fromSeek.size) assertEquals("i=$i", atTen[i], fromSeek[i], 2e-3f)
        // And the pump is audible (not a flat tone), so the equality above is meaningful.
        assertTrue(fromSeek.any { Math.abs(it - 0.4f) > 1e-3f })
    }

    @Test fun offlinePullMatchesLiveBlockByBlock() {
        val clips = listOf(clip(0, 0, 3000, 0.3f), clip(1, 1000, 3000, 0.2f))
        fun build() = ctx().also { it.load(clips, 2, 0, false, 0, 0); it.setTrackMix(0, 1f, -0.5f); it.setTrackMix(1, 0.7f, 0.5f) }
        val off = build().renderOffline(4000, block = 333)
        val live = build().let { c -> FloatArray(8000).also { var d = 0; while (d < 4000) { val n = minOf(512, 4000 - d); val t = FloatArray(n * 2); c.render(t, n); System.arraycopy(t, 0, it, d * 2, n * 2); d += n } } }
        for (i in off.indices) assertEquals("i=$i", off[i], live[i], 1e-6f)
    }
}

class MultitrackPlayerTest {
    private val scope = CoroutineScope(Dispatchers.Default)
    @After fun tearDown() { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel() }

    private class Loader(val files: Map<String, PcmBuffer>) : MultitrackClipLoader {
        val decodes = AtomicInteger(0)
        val transforms = AtomicInteger(0)
        @Volatile var firstGate: CompletableDeferred<Unit>? = null
        override suspend fun decode(fileName: String): PcmBuffer? {
            val n = decodes.incrementAndGet()
            if (n == 1) firstGate?.await()
            return files[fileName]
        }
        override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? {
            transforms.incrementAndGet()
            return null // fall back to the raw window
        }
    }

    private fun track(id: String, file: String, gainDb: Double = 0.0, strip: StudioChannelStrip = StudioChannelStrip(), muted: Boolean = false, soloed: Boolean = false) =
        StudioTrack(id, id, listOf(StudioClip("c-$id", id, file, startMs = 0, durationMs = 1000)), gainDb = gainDb, muted = muted, soloed = soloed, strip = strip)

    private fun arr(vararg t: StudioTrack, fx: StudioMasterFX = StudioMasterFX()) =
        StudioArrangement("A", "arr", t.toList(), masterFX = fx)

    private val files = mapOf("a" to const(SR, 0.1f), "b" to const(SR, 0.2f))

    private fun player(loader: Loader, sinks: MutableList<com.levi.pocketdj.studio.engine.FakeSink>, debounce: Long = 30) =
        MultitrackPlayer(loader, { FakeSink().also { sinks += it } }, scope, reprimeDebounceMs = debounce)

    @Test fun doubleTapPlayNeverDoubleStarts() = runBlocking {
        val loader = Loader(files).also { it.firstGate = CompletableDeferred() }
        val sinks = mutableListOf<FakeSink>()
        val p = player(loader, sinks)
        val a = arr(track("t1", "a"))
        val first = async(Dispatchers.Default) { p.play(a) }
        while (loader.decodes.get() < 1) Thread.sleep(2) // first play parked inside decode
        assertTrue(p.play(a)) // second tap starts
        loader.firstGate!!.complete(Unit)
        assertFalse(first.await()) // the stale load bails after its await
        assertEquals(1, sinks.size)
        assertEquals(1, sinks[0].starts)
        assertTrue(p.isPlaying.value)
        p.stop()
    }

    @Test fun stopDuringDecodeWins() = runBlocking {
        val loader = Loader(files).also { it.firstGate = CompletableDeferred() }
        val sinks = mutableListOf<FakeSink>()
        val p = player(loader, sinks)
        val first = async(Dispatchers.Default) { p.play(arr(track("t1", "a"))) }
        while (loader.decodes.get() < 1) Thread.sleep(2)
        p.stop()
        loader.firstGate!!.complete(Unit)
        assertFalse(first.await())
        assertTrue(sinks.isEmpty())
        assertFalse(p.isPlaying.value)
    }

    @Test fun nothingToPlayReturnsFalse() = runBlocking {
        val p = player(Loader(emptyMap()), mutableListOf())
        assertFalse(p.play(arr(track("t1", "missing"))))
    }

    @Test fun deleteTrackMidPlayKeepsOtherTracksMixById() = runBlocking {
        val sinks = mutableListOf<FakeSink>()
        val p = player(Loader(files), sinks)
        val t1 = track("t1", "a"); val t2 = track("t2", "b", gainDb = -6.0)
        assertTrue(p.play(arr(t1, t2)))
        val both = sinks[0].pull(64)
        assertEquals(0.1f + 0.2f * Math.pow(10.0, -6 / 20.0).toFloat(), both[0], 1e-4f)
        // Delete t1: t2 is now index 0 in the document but index 1 in the render context.
        p.applyMix(listOf(t2.copy(gainDb = -12.0)), 120.0)
        val after = sinks[0].pull(64)
        // t1 keeps its last scalars (it is gone from the doc, never touched); t2 moved by ID, not by position.
        assertEquals(0.1f + 0.2f * Math.pow(10.0, -12 / 20.0).toFloat(), after[0], 1e-4f)
        p.stop()
    }

    @Test fun muteAndSoloWinLive() = runBlocking {
        val sinks = mutableListOf<FakeSink>()
        val p = player(Loader(files), sinks)
        val t1 = track("t1", "a"); val t2 = track("t2", "b")
        assertTrue(p.play(arr(t1, t2)))
        p.applyMix(listOf(t1.copy(muted = true), t2), 120.0)
        assertEquals(0.2f, sinks[0].pull(32)[0], 1e-4f)
        p.applyMix(listOf(t1.copy(soloed = true), t2), 120.0) // solo wins over not-muted
        assertEquals(0.1f, sinks[0].pull(32)[0], 1e-4f)
        p.stop()
    }

    @Test fun stopReleasesSinkAndClock() = runBlocking {
        val sinks = mutableListOf<FakeSink>()
        val p = player(Loader(files), sinks)
        p.play(arr(track("t1", "a")))
        assertTrue(p.clock.isRunning)
        p.stop()
        assertEquals(1, sinks[0].stops)
        assertFalse(p.clock.isRunning)
        assertEquals(null, p.playingArrangementId.value)
    }

    @Test fun seekStartsMidArrangementAndRecordsOffset() = runBlocking {
        val sinks = mutableListOf<FakeSink>()
        val loader = Loader(mapOf("a" to PcmBuffer(SR, 2, FloatArray(SR * 2) { (it / 2) / SR.toFloat() })))
        val p = player(loader, sinks)
        assertTrue(p.play(arr(track("t1", "a")), fromMs = 500))
        assertEquals(500, p.startOffsetMs)
        assertEquals(0.5f, sinks[0].pull(8)[0], 1e-4f) // first frame is frame 22050 of the clip
        p.stop()
    }

    @Test fun bakeAffectingChangeRepromesAfterDebounceMixChangeDoesNot() = runBlocking {
        val sinks = mutableListOf<FakeSink>()
        val loader = Loader(files)
        val p = player(loader, sinks, debounce = 40)
        val t1 = track("t1", "a")
        val a = arr(t1)
        assertTrue(p.play(a))
        p.onArrangementChanged(arr(t1.copy(gainDb = -3.0, muted = true)))
        Thread.sleep(200)
        assertEquals(1, sinks.size) // live-mix only: no re-prime
        // Tempo change alters the baked buffer: debounce then restart; rapid edits coalesce.
        p.onArrangementChanged(arr(t1.copy(strip = StudioChannelStrip(tempoRatio = 1.1))))
        p.onArrangementChanged(arr(t1.copy(strip = StudioChannelStrip(tempoRatio = 1.2))))
        assertEquals(1, sinks.size)
        val deadline = System.currentTimeMillis() + 3000
        while (sinks.size < 2 && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertEquals(2, sinks.size)
        Thread.sleep(150)
        assertEquals(2, sinks.size) // coalesced into ONE re-prime
        assertTrue(loader.transforms.get() >= 1)
        assertTrue(p.isPlaying.value)
        p.stop()
    }

    @Test fun bakeSignatureIgnoresMixButSeesBakeInputs() {
        val t = track("t1", "a")
        val base = MultitrackPlayer.bakeSignature(arr(t))
        assertEquals(base, MultitrackPlayer.bakeSignature(arr(t.copy(gainDb = -9.0, muted = true, soloed = true, pan = 0.5,
            strip = StudioChannelStrip(eqLowDb = 6.0, reverb = 0.5)))))
        assertTrue(base != MultitrackPlayer.bakeSignature(arr(t.copy(strip = StudioChannelStrip(pitchSemitones = 2.0)))))
        assertTrue(base != MultitrackPlayer.bakeSignature(arr(t.copy(clips = emptyList()))))
        // bpm matters only under Beat Match.
        assertEquals(base, MultitrackPlayer.bakeSignature(arr(t).copy(bpm = 99.0)))
        assertTrue(MultitrackPlayer.bakeSignature(arr(t).copy(beatMatchEnabled = true)) != MultitrackPlayer.bakeSignature(arr(t).copy(beatMatchEnabled = true, bpm = 99.0)))
    }

    @Test fun autoStopsAtNaturalEnd() = runBlocking {
        val sinks = mutableListOf<FakeSink>()
        val short = StudioTrack("t1", "t1", listOf(StudioClip("c", "c", "a", durationMs = 50)))
        val p = player(Loader(files), sinks)
        assertTrue(p.play(arr(short)))
        val deadline = System.currentTimeMillis() + 3000
        while (p.isPlaying.value && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertFalse(p.isPlaying.value)
    }
}

class ArrangerBeatMatchTest {
    @Test fun rateIsWarpTimesTempoClamped() {
        assertEquals(1.0, ArrangerBeatMatch.rate(0.0, 120.0, 1.0, true), 0.0)
        assertEquals(1.25, ArrangerBeatMatch.rate(96.0, 120.0, 1.0, true), 1e-9)
        assertEquals(2.5, ArrangerBeatMatch.rate(96.0, 120.0, 2.0, true), 1e-9)
        assertEquals(2.0, ArrangerBeatMatch.rate(96.0, 120.0, 2.0, false), 1e-9)
        assertEquals(32.0, ArrangerBeatMatch.rate(1.0, 300.0, 10.0, true), 0.0)
    }

    @Test fun startSnapsToNearestMasterBeatOnlyWhenBeatMatching() {
        val beat = 22_050.0
        assertEquals(22_050, ArrangerBeatMatch.snappedStartFrame(20_000, beat, true))
        assertEquals(20_000, ArrangerBeatMatch.snappedStartFrame(20_000, beat, false))
        assertEquals(20_000, ArrangerBeatMatch.snappedStartFrame(20_000, 0.0, true))
    }
}

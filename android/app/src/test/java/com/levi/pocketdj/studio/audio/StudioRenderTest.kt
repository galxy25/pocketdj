package com.levi.pocketdj.studio.audio

import com.levi.pocketdj.audio.core.AudioDiag
import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.model.LoopBeats
import com.levi.pocketdj.studio.model.StudioGrid
import com.levi.pocketdj.studio.model.StudioSampleEdit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sin

class StudioRenderTest {
    @get:Rule val tmp = TemporaryFolder()

    private class FakeCodec(val sources: MutableMap<String, PcmBuffer> = mutableMapOf()) : StudioCodec {
        var protectedPaths = setOf<String>()
        var failWrite = false
        override fun decode(path: String) = sources[path]?.toCanonical()
        override fun decodeNativeRate(path: String) = sources[path]
        override fun isProtected(path: String) = path in protectedPaths
        override fun writeM4a(pcm: PcmBuffer, file: File) = write(pcm, file)
        override fun writeWav(pcm: PcmBuffer, file: File) = write(pcm, file)
        private fun write(pcm: PcmBuffer, file: File) {
            file.writeText("x")
            if (failWrite) throw java.io.IOException("encoder died")
            lastWritten = pcm
        }
        var lastWritten: PcmBuffer? = null
    }

    @Before fun quiet() { AudioDiag.emit = { } }
    @After fun reset() { AudioDiag.reset() }

    /** 441 Hz (period exactly 100 frames) stereo tone. */
    private fun tone(frames: Int, amp: Float = 0.5f) =
        PcmBuffer(44_100, 2, FloatArray(frames * 2) { (amp * sin(2 * PI * 441.0 * (it / 2) / 44_100)).toFloat() })

    private fun render(codec: FakeCodec) = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { })
    private fun codecWith(vararg src: Pair<String, PcmBuffer>) = FakeCodec(src.toMap().toMutableMap())
    private fun dest(name: String) = File(tmp.root, name)

    // ---- sample render -------------------------------------------------------------------------

    @Test fun dryRenderIsNominalPlusOneSilentTailWindow() = runBlocking {
        val codec = codecWith("s" to tone(44_100))
        val r = render(codec).renderSample(StudioSampleEdit.NEUTRAL, "s", dest("a.m4a"))
        // length = ceil(src/rate) + the single 512-frame window that proves silence (dry never runs to the cap)
        assertEquals(44_100L + StudioAudio.TAIL_WINDOW_FRAMES, r.frames)
        assertEquals(Math.round((44_100 + 512) / 44_100.0 * 1000).toInt(), r.durationMs)
        assertTrue(dest("a.m4a").exists())
    }

    @Test fun rateHalvesTheNominalLengthWithCeil() = runBlocking {
        val codec = codecWith("s" to tone(44_101))
        val r = render(codec).renderSample(StudioSampleEdit(rate = 2.0), "s", dest("b.m4a"))
        assertEquals(StudioAudio.nominalSampleFrames(44_101, 44_100.0, 2.0) + 512, r.frames) // ceil(44101/2)=22051
        assertEquals(22_051L + 512, r.frames)
    }

    @Test fun trimWindowSelectsTheSourceRange() = runBlocking {
        val codec = codecWith("s" to tone(88_200))
        val r = render(codec).renderSample(StudioSampleEdit(trimStartMs = 100, trimEndMs = 600), "s", dest("c.m4a"))
        assertEquals(22_050L + 512, r.frames)
        // first body frame is source frame 4410, not 0
        val out = codec.lastWritten!!
        assertEquals(tone(88_200).samples[4410 * 2], out.samples[0], 1e-6f)
    }

    @Test fun trimPastTheEndIsEmptyWindowAndLeavesNoFile() = runBlocking {
        val codec = codecWith("s" to tone(4410))
        try { render(codec).renderSample(StudioSampleEdit(trimStartMs = 5000), "s", dest("d.m4a")); fail() }
        catch (e: StudioRenderException.EmptyWindow) { }
        assertFalse(dest("d.m4a").exists())
        assertEquals(emptyList<String>(), tmp.root.list()!!.toList())
    }

    @Test fun gainIsBakedIntoTheSamples() = runBlocking {
        val codec = codecWith("s" to tone(8820, amp = 0.8f))
        render(codec).renderSample(StudioSampleEdit(gainDb = -6.0206), "s", dest("g.m4a"))
        val peak = codec.lastWritten!!.samples.take(8820 * 2).maxOf { abs(it) }
        assertEquals(0.4f, peak, 0.01f)
    }

    @Test fun reverbTailDrainsUntilBelowFloorOrCap() = runBlocking {
        val codec = codecWith("s" to tone(8820))
        val r = render(codec).renderSample(StudioSampleEdit(reverbWet = 1.0), "s", dest("r.m4a"))
        val nominal = 8820L
        assertTrue("tail was drained: ${r.frames}", r.frames > nominal + StudioAudio.TAIL_WINDOW_FRAMES)
        assertTrue("never beyond the cap + one window: ${r.frames}", r.frames <= nominal + StudioAudio.tailCapFrames + StudioAudio.TAIL_WINDOW_FRAMES)
        // the file ends in a below-floor window
        val s = codec.lastWritten!!.samples
        assertTrue(StudioAudio.isBelowFloor(s, s.size - 512 * 2, 512 * 2) || r.frames >= nominal + StudioAudio.tailCapFrames)
    }

    @Test fun delayTailIsCapturedAndRingsAfterTheNominalEnd() = runBlocking {
        val codec = codecWith("s" to tone(4410))
        render(codec).renderSample(StudioSampleEdit(delayWet = 1.0), "s", dest("dl.m4a"))
        val out = codec.lastWritten!!.samples
        // wet=1 -> the dry is gone; the 0.3 s slap shows up after the source ended (frame 4410 + 13230 region)
        var e = 0.0
        for (i in (4410 + 100) * 2 until (4410 + 13_230) * 2) e += out[i] * out[i].toDouble()
        assertTrue(e > 0.1)
    }

    @Test fun filterDarkensTheSignal() = runBlocking {
        val hf = PcmBuffer(44_100, 2, FloatArray(8820 * 2) { if ((it / 2) % 2 == 0) 0.5f else -0.5f }) // Nyquist square
        val codec = codecWith("s" to hf)
        render(codec).renderSample(StudioSampleEdit(filterAmt = 1.0), "s", dest("f.m4a"))
        val peak = codec.lastWritten!!.samples.drop(2000).take(4000).maxOf { abs(it) }
        assertTrue("LP at 250 Hz should crush Nyquist content: $peak", peak < 0.05f)
    }

    @Test fun compressorLevelsAHotSignalAndAddsMakeup() {
        val quiet = tone(8820, amp = 0.02f).samples.copyOf()
        val loud = tone(8820, amp = 0.9f).samples.copyOf()
        StudioRenderCore.SampleFx(StudioSampleEdit(compWet = 1.0)).process(quiet, 0, 8820)
        StudioRenderCore.SampleFx(StudioSampleEdit(compWet = 1.0)).process(loud, 0, 8820)
        val q = quiet.drop(4000).maxOf { abs(it) }; val l = loud.drop(4000).maxOf { abs(it) }
        // 45x input ratio is squeezed (4:1 above the -30 dB threshold) -> well under 45x out
        assertTrue("ratio ${l / q}", l / q < 45f / 2f)
    }

    @Test fun neutralChainIsRecognised() {
        assertTrue(StudioRenderCore.SampleFx(StudioSampleEdit.NEUTRAL).isNeutral)
        assertFalse(StudioRenderCore.SampleFx(StudioSampleEdit(gainDb = 3.0)).isNeutral)
        assertFalse(StudioRenderCore.SampleFx(StudioSampleEdit(reverbWet = 0.3)).isNeutral)
    }

    // ---- loops ---------------------------------------------------------------------------------

    private val grid120 = StudioGrid(bpm = 120.0)

    @Test fun loopHasExactlyTheBeatWindowFramesAndPositiveBpm() = runBlocking {
        val codec = codecWith("s" to tone(5 * 44_100))
        val r = render(codec).renderLoop(StudioSampleEdit.NEUTRAL, "s", 0, LoopBeats.FOUR, grid120, dest("l.wav"))
        assertEquals(88_200L, r.frames) // 4 beats @120 = 2000 ms
        assertEquals(2000, r.lengthMs)
        assertEquals(120.0, r.bpm, 1e-9)
        assertEquals(88_200, codec.lastWritten!!.frames)
    }

    @Test fun loopRateBakesIntoFramesAndBpm() = runBlocking {
        val codec = codecWith("s" to tone(5 * 44_100))
        val r = render(codec).renderLoop(StudioSampleEdit(rate = 2.0), "s", 0, LoopBeats.FOUR, grid120, dest("l2.wav"))
        assertEquals(44_100L, r.frames)
        assertEquals(240.0, r.bpm, 1e-9) // standalone tempo of the RENDERED audio
        assertEquals(44_100, codec.lastWritten!!.frames)
    }

    @Test fun loopFrameZeroIsMusicalFrameZeroWithNoPrimingHead() = runBlocking {
        val src = PcmBuffer(44_100, 2, FloatArray(5 * 44_100 * 2))
        val start = 22_050 // 500 ms = beat 1 @120
        src.samples[start * 2] = 1f; src.samples[start * 2 + 1] = 1f
        val codec = codecWith("s" to src)
        render(codec).renderLoop(StudioSampleEdit.NEUTRAL, "s", 500, LoopBeats.TWO, grid120, dest("l3.wav"))
        val out = codec.lastWritten!!.samples
        assertEquals(1f, out[0], 0f)
        assertEquals(0, com.levi.pocketdj.audio.core.OfflineRenderer.firstNonZeroFrame(out))
    }

    @Test fun loopedAuditionHasNoClickAtTheSeam() = runBlocking {
        val codec = codecWith("s" to tone(5 * 44_100))
        render(codec).renderLoop(StudioSampleEdit.NEUTRAL, "s", 0, LoopBeats.TWO, grid120, dest("l4.wav")) // 1000 ms = 441 periods
        val loop = codec.lastWritten!!
        assertEquals(44_100, loop.frames)
        // play it twice end to end (what a looped player does)
        val s = loop.samples
        val two = s + s
        var maxStep = 0f; var seamStep = 0f
        for (i in 1 until two.size / 2) {
            val step = abs(two[2 * i] - two[2 * (i - 1)])
            if (i == loop.frames) seamStep = step else maxStep = max(maxStep, step)
        }
        assertTrue("seam step $seamStep vs max in-body step $maxStep", seamStep <= maxStep * 1.01f)
        // RMS continuity: 10 ms either side of the seam match
        fun rms(from: Int) = kotlin.math.sqrt((from until from + 441).sumOf { two[2 * it].toDouble() * two[2 * it] } / 441)
        assertEquals(rms(loop.frames - 441), rms(loop.frames), 0.01)
    }

    @Test fun loopWindowStartsExactlyAtTheAnchorFrame() = runBlocking {
        // unique-valued source: any off-by-one in the window start/end shows up as a shifted value
        val src = PcmBuffer(44_100, 2, FloatArray(5 * 44_100 * 2) { (it / 2) / 300_000f })
        val codec = codecWith("s" to src)
        render(codec).renderLoop(StudioSampleEdit.NEUTRAL, "s", 13, LoopBeats.TWO, grid120, dest("l6.wav"))
        val loop = codec.lastWritten!!
        assertEquals(44_100, loop.frames)
        val start = Math.round(loop.samples[0] * 300_000f)
        assertTrue("window lies inside the source (start=$start)", start in 0..(5 * 44_100 - 44_100))
        // contiguous, unstretched, exact: first AND last frame of the window are the source frames start / start+43999+1-1
        for (k in 0 until 44_100) assertEquals("frame $k", (start + k) / 300_000f, loop.samples[2 * k], 2e-6f)
    }

    @Test fun loopSourceShortOfTheWindowIsZeroPaddedToExactFrames() = runBlocking {
        val codec = codecWith("s" to tone(60_000))
        val r = render(codec).renderLoop(StudioSampleEdit.NEUTRAL, "s", 0, LoopBeats.FOUR, grid120, dest("l5.wav"))
        assertEquals(88_200L, r.frames)
        val out = codec.lastWritten!!.samples
        assertEquals(0f, out[2 * 70_000], 0f)
        assertTrue(abs(out[2 * 50_025]) > 0.1f || abs(out[2 * 50_026]) > 0.1f)
    }

    @Test fun loopWindowPastEofIsEmptyAndGridlessIsNoGrid() = runBlocking {
        val codec = codecWith("s" to tone(10_000))
        try { render(codec).renderLoop(StudioSampleEdit.NEUTRAL, "s", 0, LoopBeats.FOUR, StudioGrid(bpm = 0.0), dest("n.wav")); fail() }
        catch (e: StudioRenderException.NoGrid) { }
        try { render(codec).renderLoop(StudioSampleEdit.NEUTRAL, "s", 60_000, LoopBeats.ONE, grid120, dest("n.wav")); fail() }
        catch (e: StudioRenderException.EmptyWindow) { }
        assertEquals(emptyList<String>(), tmp.root.list()!!.toList())
    }

    @Test fun loopEffectsBakeWithoutATail() = runBlocking {
        val codec = codecWith("s" to tone(5 * 44_100))
        val r = render(codec).renderLoop(StudioSampleEdit(reverbWet = 1.0, delayWet = 0.5), "s", 0, LoopBeats.ONE, grid120, dest("l6.wav"))
        assertEquals(22_050L, r.frames) // tails truncated: exact frames regardless of FX
    }

    // ---- carve / import / stems ----------------------------------------------------------------

    @Test fun carveRegionIsFrameExactAndClampedToTheFile() = runBlocking {
        val codec = codecWith("s" to tone(44_100))
        val r = render(codec).carveTrackRegion("s", 100, 600, dest("cv.m4a"))
        assertEquals(22_050L, r.frames)
        assertEquals(500, r.durationMs)
        val clamped = render(codec).carveTrackRegion("s", 900, 5000, dest("cv2.m4a"))
        assertEquals(4_410L, clamped.frames)
        try { render(codec).carveTrackRegion("s", 5000, 6000, dest("cv3.m4a")); fail() } catch (e: StudioRenderException.EmptyWindow) { }
        try { render(codec).carveTrackRegion("s", 600, 100, dest("cv3.m4a")); fail() } catch (e: StudioRenderException.EmptyWindow) { }
    }

    @Test fun stemMixDecodesOnlyTheWindowNeverTheWholeStem() = runBlocking {
        val calls = ArrayList<Triple<String, Int, Int>>()
        val codec = object : StudioCodec {
            override fun decode(path: String): PcmBuffer? = throw AssertionError("whole-file decode")
            override fun decodeNativeRate(path: String): PcmBuffer? = null
            override fun decodeRange(path: String, startMs: Int, lenMs: Int): PcmBuffer? {
                calls.add(Triple(path, startMs, lenMs)); return PcmBuffer(44_100, 2, FloatArray(4_410 * 2) { 0.25f })
            }
            override fun isProtected(path: String) = false
            override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText("x") }
            override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("x") }
        }
        val r = StudioRender(codec, ResampleStretcher, Dispatchers.Unconfined, { }).carveStemMix(listOf("a", "b"), 3_000, 3_100, dest("win.m4a"))
        assertEquals(listOf(Triple("a", 3_000, 100), Triple("b", 3_000, 100)), calls)
        assertEquals(4_410L, r.frames)
    }

    @Test fun stemMixSumsWindowsWithoutAttenuationAndAShortStemJustGoesQuiet() = runBlocking {
        val a = PcmBuffer(44_100, 2, FloatArray(44_100 * 2) { 0.25f })
        val b = PcmBuffer(44_100, 2, FloatArray(22_050 * 2) { 0.5f }) // half a second only
        val codec = codecWith("a" to a, "b" to b)
        val r = render(codec).carveStemMix(listOf("a", "b"), 0, 1000, dest("sm.m4a"))
        assertEquals(44_100L, r.frames)
        val out = codec.lastWritten!!.samples
        assertEquals(0.75f, out[100], 1e-6f)
        assertEquals(0.25f, out[2 * 30_000], 1e-6f)
        try { render(codec).carveStemMix(listOf("a", "missing"), 0, 1000, dest("sm2.m4a")); fail() }
        catch (e: StudioRenderException.UnreadableSource) { assertEquals("missing", e.path) }
        try { render(codec).carveStemMix(emptyList(), 0, 1000, dest("sm3.m4a")); fail() } catch (e: StudioRenderException.EmptyWindow) { }
    }

    @Test fun drmProtectedImportIsRejectedBeforeAnyDecode() = runBlocking {
        val codec = codecWith("p" to tone(1000))
        codec.protectedPaths = setOf("p")
        try { render(codec).importAudioFile("p", dest("p.m4a")); fail() } catch (e: StudioRenderException.ProtectedSource) { }
        assertFalse(dest("p.m4a").exists())
    }

    @Test fun importWritesTheWholeFileAtCanonicalFormat() = runBlocking {
        val codec = codecWith("m" to PcmBuffer(48_000, 1, FloatArray(48_000) { 0.1f }))
        val r = render(codec).importAudioFile("m", dest("i.m4a"))
        assertEquals(44_100L, r.frames)
        assertTrue(StudioAudio.isCanonical(codec.lastWritten!!))
    }

    @Test fun relabeledImportKeepsFrameCountAndIsLongerThanResampled() = runBlocking {
        val codec = codecWith("m" to PcmBuffer(48_000, 2, FloatArray(48_000 * 2) { 0.1f }))
        val r = render(codec).importAudioFileRelabeled("m", dest("rl.m4a"))
        assertEquals(48_000L, r.frames) // not 44100: varispeed, no SRC
        assertEquals(1088, r.durationMs)
    }

    @Test fun unreadableSourceIsReportedAndNothingIsLeftBehind() = runBlocking {
        val codec = codecWith()
        try { render(codec).renderSample(StudioSampleEdit.NEUTRAL, "nope", dest("u.m4a")); fail() }
        catch (e: StudioRenderException.UnreadableSource) { }
        assertEquals(emptyList<String>(), tmp.root.list()!!.toList())
    }

    @Test fun aThrowingEncoderNeverLeavesAPartialFileOrATemp() = runBlocking {
        val codec = codecWith("s" to tone(4410))
        codec.failWrite = true
        val d = dest("t.m4a")
        d.writeText("older render")
        try { render(codec).renderSample(StudioSampleEdit.NEUTRAL, "s", d); fail() } catch (e: java.io.IOException) { }
        assertEquals("the previous render survives a failed bake", "older render", d.readText())
        assertEquals(listOf("t.m4a"), tmp.root.list()!!.toList())
    }

    @Test fun successfulRenderReplacesOlderFileAtomically() = runBlocking {
        val codec = codecWith("s" to tone(4410))
        val d = dest("x.m4a"); d.writeText("old")
        render(codec).renderSample(StudioSampleEdit.NEUTRAL, "s", d)
        assertEquals("x", d.readText())
        assertEquals(listOf("x.m4a"), tmp.root.list()!!.toList()) // no temp siblings
    }

    // ---- stretch / transform -------------------------------------------------------------------

    @Test fun stretchBufferLandsOnTheExactTargetFrames() = runBlocking {
        val r = render(codecWith())
        val src = tone(10_000)
        assertEquals(7_777, r.stretchBuffer(src, 7_777).frames)
        assertEquals(40_000, r.stretchBuffer(src, 40_000).frames)
        assertTrue(r.stretchBuffer(src, 10_000) === src) // identity short-circuit
        try { r.stretchBuffer(src, 0); fail() } catch (e: StudioRenderException.EmptyWindow) { }
        try { r.stretchBuffer(PcmBuffer(48_000, 2, FloatArray(100)), 50); fail() } catch (e: StudioRenderException.CannotCreateBuffer) { }
    }

    @Test fun stretchRateClampStillHitsTheExactFrames() = runBlocking {
        // 100 frames -> 100000 is far past 1/32: clamped stretch then zero-padded to the exact target
        val out = render(codecWith()).stretchBuffer(tone(100), 100_000)
        assertEquals(100_000, out.frames)
        assertEquals(0f, out.samples[2 * 99_999], 0f)
    }

    @Test fun transformNeutralIsAPlainSliceAndRateScalesLength() = runBlocking {
        val r = render(codecWith())
        val src = tone(20_000)
        val neutral = r.transformBuffer(src, 1_000, 5_000, 1.0, 0.0)
        assertEquals(5_000, neutral.frames)
        assertEquals(src.samples[2_000], neutral.samples[0], 0f)
        assertEquals(2_500, r.transformBuffer(src, 0, 5_000, 2.0, 0.0).frames)
        assertEquals(10_000, r.transformBuffer(src, 0, 5_000, 0.5, 300.0).frames)
        try { r.transformBuffer(src, 19_000, 5_000, 1.0, 0.0); fail() } catch (e: StudioRenderException.EmptyWindow) { }
    }

    @Test fun resampleStretcherPreservesEndpointsAndLength() {
        val src = PcmBuffer(44_100, 2, FloatArray(200) { it / 200f })
        val out = ResampleStretcher.stretch(src, 300, 0.0)
        assertEquals(300, out.frames)
        assertEquals(src.samples[0], out.samples[0], 1e-6f)
        assertNull(runCatching { ResampleStretcher.stretch(PcmBuffer(44_100, 2, FloatArray(0)), 10, 0.0) }.exceptionOrNull())
    }

    // ---- serialization -------------------------------------------------------------------------

    @Test fun rendersAreSerializedOnTheSinglePermitMutex() = runBlocking {
        val active = AtomicInteger(); val maxActive = AtomicInteger()
        val codec = object : StudioCodec {
            override fun decode(path: String): PcmBuffer {
                val n = active.incrementAndGet()
                maxActive.updateAndGet { max(it, n) }
                Thread.sleep(30)
                active.decrementAndGet()
                return tone(4410)
            }
            override fun decodeNativeRate(path: String) = null
            override fun isProtected(path: String) = false
            override fun writeM4a(pcm: PcmBuffer, file: File) { file.writeText("x") }
            override fun writeWav(pcm: PcmBuffer, file: File) { file.writeText("x") }
        }
        val r = StudioRender(codec, ResampleStretcher, Dispatchers.Default, { })
        (0 until 6).map { i -> async(Dispatchers.Default) { r.carveTrackRegion("s", 0, 100, dest("par$i.m4a")) } }.awaitAll()
        assertEquals(1, maxActive.get())
    }
}

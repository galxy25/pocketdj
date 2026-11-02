package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.audio.ResampleStretcher
import com.levi.pocketdj.studio.audio.StudioRenderCore
import com.levi.pocketdj.studio.model.StudioChannelStrip
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioTrack
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.sin

/** Q109: warped long clips stream through the stretcher in chunks; seams must be continuous and heap O(chunk). */
class ChunkedStretchFeedTest {
    private val rate = 44_100

    /** Smooth deterministic source: L/R sines of different frequency (window-relative frame index). */
    private fun src(f: Long, ch: Int) = (sin(f * (if (ch == 0) 0.004 else 0.0065)) * 0.6).toFloat()
    private fun window(start: Int, len: Int) = PcmBuffer(rate, 2, FloatArray(len * 2) { i -> src(start + i / 2L, i % 2) })

    private fun resample(r: Double) = { pcm: PcmBuffer -> StudioRenderCore.transform(pcm, 0, pcm.frames.toLong(), r, 0.0, ResampleStretcher) }

    private fun drain(feed: ChunkedStretchFeed, block: Int = 4410): FloatArray {
        val out = FloatArray(feed.outTotal * 2); val b = FloatArray(block * 2); var at = 0
        while (at < feed.outTotal) { val n = minOf(block, feed.outTotal - at); feed.fill(b, at, n); System.arraycopy(b, 0, out, at * 2, n * 2); at += n }
        return out
    }

    private fun maxStep(y: FloatArray): Float { var m = 0f; for (i in 2 until y.size) m = maxOf(m, abs(y[i] - y[i - 2])); return m }

    @Test fun chunkedStretchMatchesTheWholeWindowBakeAcrossEverySeam() {
        val win = rate * 12; val r = 1.25
        val outTotal = ChunkedStretchFeed.outFrames(win, r)
        val whole = StudioRenderCore.transform(window(0, win), 0, win.toLong(), r, 0.0, ResampleStretcher).samples
        val feed = ChunkedStretchFeed(win, outTotal, ChunkedStretchFeed.coreFrames(rate, r), 4410,
            fetch = { s, len -> window(s, len) }, stretch = resample(r))
        val y = drain(feed)
        assertEquals(whole.size, y.size)
        assertTrue("several seams exercised", feed.chunksRendered >= 10)
        var maxDiff = 0f
        for (i in y.indices) maxDiff = maxOf(maxDiff, abs(y[i] - whole[i]))
        assertTrue("chunked == whole within interpolation error, was $maxDiff", maxDiff < 0.01f)
        // No discontinuity anywhere: the largest frame-to-frame step is the signal's own slope.
        assertTrue("step ${maxStep(y)} vs ${maxStep(whole)}", maxStep(y) <= maxStep(whole) * 1.05f + 1e-4f)
    }

    @Test fun slowedDownAndPitchedWindowsKeepTheExactBakeLength() {
        for (r in listOf(0.5, 0.8, 1.0 / 32, 2.0, 32.0)) {
            val win = rate * 3 + 17
            val feed = ChunkedStretchFeed(win, ChunkedStretchFeed.outFrames(win, r), ChunkedStretchFeed.coreFrames(rate / 2, r), 441,
                fetch = { s, len -> window(s, len) }, stretch = resample(r))
            val y = drain(feed, 441)
            val whole = StudioRenderCore.transform(window(0, win), 0, win.toLong(), r, 0.0, ResampleStretcher)
            assertEquals("r=$r length", whole.frames, y.size / 2)
            assertTrue("r=$r source excerpt bounded", feed.maxFetchFrames <= rate / 2 + 2 * ChunkedStretchFeed.PAD_FRAMES + (ChunkedStretchFeed.XF_FRAMES * maxOf(1.0, r)).toInt() + 64)
        }
    }

    @Test fun stretchEdgeArtifactsArePaddedAwayInsideTheWindow() {
        // A phase vocoder smears the first/last windows of every call: model it as 2000 zeroed output frames at each edge.
        val win = rate * 8; val r = 0.9
        val smear = { pcm: PcmBuffer ->
            val y = resample(r)(pcm); val s = y.samples.copyOf()
            for (f in 0 until minOf(2000, y.frames)) { s[2 * f] = 0f; s[2 * f + 1] = 0f; val e = y.frames - 1 - f; s[2 * e] = 0f; s[2 * e + 1] = 0f }
            PcmBuffer(rate, 2, s)
        }
        val outTotal = ChunkedStretchFeed.outFrames(win, r)
        val feed = ChunkedStretchFeed(win, outTotal, rate, 4410, fetch = { s, len -> window(s, len) }, stretch = smear)
        val y = drain(feed)
        val whole = smear(window(0, win)).samples
        var maxDiff = 0f
        for (f in 2000 until outTotal - 2000) for (c in 0..1) maxDiff = maxOf(maxDiff, abs(y[2 * f + c] - whole[2 * f + c]))
        assertTrue("interior free of per-chunk edge artifacts, diff $maxDiff", maxDiff < 0.01f)
        assertTrue(feed.chunksRendered >= 7)
    }

    @Test fun independentStretchCallsAreCrossfadedNotStepped() {
        // Each stretch call lands at a different DC level (worst-case phase mismatch); the seam must ramp, never jump.
        val calls = AtomicInteger(0)
        val win = rate * 6
        val outTotal = ChunkedStretchFeed.outFrames(win, 1.1)
        val dc = { pcm: PcmBuffer ->
            val lvl = 0.1f * calls.incrementAndGet(); val n = Math.round(pcm.frames / 1.1).toInt()
            PcmBuffer(rate, 2, FloatArray(n * 2) { lvl })
        }
        val feed = ChunkedStretchFeed(win, outTotal, rate, 4410, fetch = { _, len -> PcmBuffer(rate, 2, FloatArray(len * 2)) }, stretch = dc)
        val y = drain(feed)
        assertTrue(calls.get() >= 5)
        val step = maxStep(y)
        assertTrue("seam step $step must be a ${ChunkedStretchFeed.XF_FRAMES}-frame ramp of 0.1", step < 0.1f / ChunkedStretchFeed.XF_FRAMES * 2)
    }

    @Test fun cancellationIsPolledPerChunk() {
        var polls = 0
        val feed = ChunkedStretchFeed(rate * 10, rate * 10, rate, 4410, fetch = { s, len -> window(s, len) }, stretch = resample(1.0001),
            stop = { ++polls > 2 })
        val threw = runCatching { drain(feed) }.exceptionOrNull()
        assertTrue(threw is java.util.concurrent.CancellationException)
        assertEquals(2, feed.chunksRendered)
    }

    // ---- planner integration -----------------------------------------------------------------------------

    private lateinit var dir: File
    @Before fun setUp() { dir = java.nio.file.Files.createTempDirectory("stretch-paging").toFile() }
    @After fun tearDown() { dir.deleteRecursively() }

    /** File = the smooth source at absolute frames; whole decode is a test failure (that is the OOM path). */
    private inner class WarpLoader(val fileFrames: Int, val probe: Boolean = true) : MultitrackClipLoader {
        val wholeDecodes = AtomicInteger(0); val transforms = AtomicInteger(0)
        var maxWindowMs = 0; var maxTransformFrames = 0L
        override suspend fun decode(fileName: String): PcmBuffer? { wholeDecodes.incrementAndGet(); return window(0, fileFrames) }
        override suspend fun decodeWindow(fileName: String, startMs: Int, lenMs: Int): PcmBuffer? {
            maxWindowMs = maxOf(maxWindowMs, lenMs)
            val from = MultitrackRenderContext.msToFrames(startMs, rate)
            val n = minOf(MultitrackRenderContext.msToFrames(lenMs, rate), fileFrames - from).coerceAtLeast(0)
            return window(from, n)
        }
        override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? {
            transforms.incrementAndGet(); maxTransformFrames = maxOf(maxTransformFrames, frames)
            return StudioRenderCore.transform(source, from, frames, rate, pitchCents, ResampleStretcher)
        }
        override fun sourceStamp(fileName: String) = "v1"
        override fun sourceFrames(fileName: String): Int? = if (probe) fileFrames else null
    }

    private fun warpedTrack(ms: Int, fileStartMs: Int = 0, tempo: Double = 1.25) =
        StudioTrack("t", "t", listOf(StudioClip("c", "t", "song.m4a", startMs = 0, durationMs = ms, fileStartMs = fileStartMs)),
            strip = StudioChannelStrip(tempoRatio = tempo))

    @Test fun warpedLongClipStreamsThroughTheStretcherWithoutAWholeDecode() = runBlocking {
        val loader = WarpLoader(rate * 600) // a 10-minute source
        val store = ClipPageStore(dir)
        val clips = ArrangerClipPlan.build(listOf(warpedTrack(90_000, fileStartMs = 3_000)), 120.0, false, loader,
            pager = store, shortClipFrames = rate, stretchChunkFrames = rate * 10)!!
        assertEquals("never a whole-file decode", 0, loader.wholeDecodes.get())
        assertTrue("one stretch per chunk", loader.transforms.get() >= 9)
        assertTrue("heap O(chunk): transform excerpt ${loader.maxTransformFrames}", loader.maxTransformFrames < rate * 12)
        assertTrue("decode window ${loader.maxWindowMs} ms", loader.maxWindowMs < 12_000)
        val reader = clips[0].reader!!
        val win = rate * 90
        assertEquals(ChunkedStretchFeed.outFrames(win, 1.25), reader.frameCount)
        // Content == the whole-window bake (on the PCM16 grid), including every seam.
        val whole = StudioRenderCore.transform(window(rate * 3, win), 0, win.toLong(), 1.25, 0.0, ResampleStretcher).samples
        val buf = FloatArray(reader.frameCount * 2)
        reader.read(buf, 0, 0, reader.frameCount)
        var maxDiff = 0f
        for (i in buf.indices) maxDiff = maxOf(maxDiff, abs(buf[i] - whole[i]))
        assertTrue("paged warped == whole-window bake, diff $maxDiff", maxDiff < 0.01f)
        reader.close()
    }

    @Test fun durationZeroClipUsesTheProbedLengthAndStreams() = runBlocking {
        val loader = WarpLoader(rate * 45)
        val clips = ArrangerClipPlan.build(listOf(warpedTrack(0, fileStartMs = 5_000)), 120.0, false, loader,
            pager = ClipPageStore(dir), shortClipFrames = rate, stretchChunkFrames = rate * 10)!!
        assertEquals(0, loader.wholeDecodes.get())
        assertEquals(ChunkedStretchFeed.outFrames(rate * 40, 1.25), clips[0].reader!!.frameCount)
        clips.forEach { it.reader?.close() }
        // Unwarped durationMs-0 clip streams too (raw 30 s chunks).
        val raw = ArrangerClipPlan.build(listOf(warpedTrack(0, tempo = 1.0)), 120.0, false, loader, pager = ClipPageStore(dir), shortClipFrames = rate)!!
        assertEquals(0, loader.wholeDecodes.get())
        assertEquals(rate * 45, raw[0].reader!!.frameCount)
        raw.forEach { it.reader?.close() }
    }

    @Test fun durationZeroWithoutAProbeKeepsTheLegacyWholeDecode() = runBlocking {
        val loader = WarpLoader(rate * 3, probe = false)
        val clips = ArrangerClipPlan.build(listOf(warpedTrack(0)), 120.0, false, loader, pager = ClipPageStore(dir), shortClipFrames = rate)!!
        assertEquals(1, loader.wholeDecodes.get())
        assertEquals(ChunkedStretchFeed.outFrames(rate * 3, 1.25), clips[0].frameLength)
        clips.forEach { it.reader?.close() }
    }

    @Test fun failedChunkStretchFallsBackToTheRawWindowUnderTheUnwarpedKey() = runBlocking {
        val loader = object : MultitrackClipLoader by WarpLoader(rate * 120) {
            override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? = null
        }
        val store = ClipPageStore(dir)
        val clips = ArrangerClipPlan.build(listOf(warpedTrack(60_000)), 120.0, false, loader, pager = store, shortClipFrames = rate)!!
        assertEquals("raw window length", rate * 60, clips[0].reader!!.frameCount)
        assertTrue("warped key never written", !store.has(ClipPageStore.Key("song.m4a", "v1", 0, 60_000, 1.25, 0.0, rate)))
        clips.forEach { it.reader?.close() }
    }

    @Test fun cancelledWarpedStreamLeavesNoPage() = runBlocking {
        val store = ClipPageStore(dir)
        var polls = 0
        val r = ArrangerClipPlan.build(listOf(warpedTrack(90_000)), 120.0, false, WarpLoader(rate * 120), pager = store,
            shortClipFrames = rate, stretchChunkFrames = rate * 10, isCancelled = { ++polls > 4 })
        assertNull(r)
        assertEquals(0L, store.sizeBytes)
    }
}

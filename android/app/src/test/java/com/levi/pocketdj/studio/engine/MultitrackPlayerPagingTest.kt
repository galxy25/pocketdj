package com.levi.pocketdj.studio.engine

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.studio.dsp.MasterFxKernel
import com.levi.pocketdj.studio.dsp.TrackFxKernel
import com.levi.pocketdj.studio.model.StudioArrangement
import com.levi.pocketdj.studio.model.StudioClip
import com.levi.pocketdj.studio.model.StudioTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.sin

private const val RATE = 44_100
private fun ramp(frame: Long) = ((frame % 20_000).toFloat() / 20_000f) * 0.5f

private fun newCtx() = MultitrackRenderContext(newTrackFx = { TrackFxKernel(RATE.toDouble(), 2) }, master = MasterFxKernel(RATE.toDouble(), 2))
    .also { it.startFeeder = false }

class MultitrackPlayerPagingTest {
    private lateinit var dir: File
    private lateinit var store: ClipPageStore
    @Before fun setUp() { dir = java.nio.file.Files.createTempDirectory("paging").toFile(); store = ClipPageStore(dir) }
    @After fun tearDown() { dir.deleteRecursively() }

    private fun tone(frames: Int, f: Double) = FloatArray(frames * 2) { sin((it / 2) * f).toFloat() * 0.7f * (if (it % 2 == 0) 1f else 0.6f) }

    private fun pagedClip(ti: Int, start: Int, samples: FloatArray, tag: String): MultitrackRenderContext.Clip {
        val k = ClipPageStore.Key(tag, "s", 0, 0, 1.0, 0.0, RATE)
        store.write(k, samples)
        return MultitrackRenderContext.Clip(ti, start, samples.size / 2, 0, null, store.open(k)!!)
    }

    private fun pull(c: MultitrackRenderContext, frames: Int, block: Int = 1000): FloatArray {
        val out = FloatArray(frames * 2); val tmp = FloatArray(block * 2); var at = 0
        while (at < frames) { val n = minOf(block, frames - at); c.render(tmp, n); System.arraycopy(tmp, 0, out, at * 2, n * 2); at += n }
        return out
    }

    private fun both(build: (Boolean) -> Pair<MultitrackRenderContext, Int>): Pair<FloatArray, FloatArray> {
        val (m, n) = build(false); val (p, _) = build(true)
        val a = pull(m, n); val b = pull(p, n)
        m.release(); p.release()
        return a to b
    }

    @Test fun pagedRenderEqualsInMemoryRenderBitExactOnThePcm16Grid() {
        val a = tone(30_000, 0.013); val b = tone(20_000, 0.031)
        val (mem, paged) = both { isPaged ->
            val c = newCtx()
            val clips = if (isPaged) listOf(pagedClip(0, 100, a, "a"), pagedClip(1, 10_000, b, "b"))
            else listOf(MultitrackRenderContext.Clip(0, 100, 30_000, 0, ClipPageStore.snap(a)), MultitrackRenderContext.Clip(1, 10_000, 20_000, 0, ClipPageStore.snap(b)))
            c.load(clips, 2, 0, false, 0, 0)
            c.setTrackMix(0, 0.8f, -0.3f); c.setTrackMix(1, 0.5f, 0.2f)
            c to 45_000
        }
        assertArrayEquals(mem, paged, 0f)
        assertTrue(mem.any { it != 0f })
    }

    @Test fun pagedRenderMatchesWithTrackFxLoopAndMidClipSeek() {
        val a = tone(40_000, 0.02)
        val (mem, paged) = both { isPaged ->
            val c = newCtx()
            val clip = if (isPaged) pagedClip(0, 0, a, "fx") else MultitrackRenderContext.Clip(0, 0, 40_000, 0, ClipPageStore.snap(a))
            c.load(listOf(clip), 1, 12_345, true, 5_000, 25_000) // seek 12_345 inside a loop region
            c.setTrackMix(0, 1f, 0f)
            c.setTrackFx(0, com.levi.pocketdj.studio.dsp.TrackFxParams(eqLowDb = 6.0, reverb = 0.0, delay = 0.0, chorus = 0.0, bpm = 120.0))
            c to 60_000
        }
        assertArrayEquals(mem, paged, 0f)
    }

    @Test fun srcStartWindowOffsetsIntoThePage() {
        val a = tone(10_000, 0.05)
        val k = ClipPageStore.Key("w", "s", 0, 0, 1.0, 0.0, RATE); store.write(k, a)
        val c = newCtx()
        c.load(listOf(MultitrackRenderContext.Clip(0, 50, 4_000, 3_000, null, store.open(k)!!)), 1, 0, false, 0, 0)
        c.setTrackMix(0, 1f, 0f)
        val out = pull(c, 100)
        val snapped = ClipPageStore.snap(a)
        assertEquals(snapped[3_000 * 2], out[50 * 2], 1e-6f)
        assertEquals(snapped[(3_000 + 10) * 2 + 1], out[60 * 2 + 1], 1e-6f)
        c.release()
    }

    @Test fun prefetchAheadWrapsThroughTheLoopAndFollowsASeek() {
        val reads = ArrayList<Pair<Int, Int>>()
        val spy = object : ClipReader {
            override val frameCount = 100_000
            override fun read(dst: FloatArray, dstOff: Int, srcFrame: Int, frames: Int) {}
            override fun prefetch(srcFrame: Int, frames: Int) { synchronized(reads) { reads += srcFrame to frames } }
        }
        val c = newCtx()
        c.load(listOf(MultitrackRenderContext.Clip(0, 0, 100_000, 0, null, spy)), 1, 90_000, true, 10_000, 95_000)
        c.setTrackMix(0, 1f, 0f)
        reads.clear()
        c.prefetchAhead(10_000)
        // 90_000..95_000 then wraps to loop start 10_000..15_000
        assertEquals(listOf(90_000 to 5_000, 10_000 to 5_000), reads.toList())
        // advancing the cursor moves the window (re-prime follows the playhead)
        pull(c, 2_000); reads.clear(); c.prefetchAhead(1_000)
        assertEquals(listOf(92_000 to 1_000), reads.toList())
        c.release()
    }

    // --- planner integration: ArrangerClipPlan routes long windows to pages and honours the cache -------------

    private class CountingLoader(val files: Map<String, PcmBuffer>, var stamp: String = "v1") : MultitrackClipLoader {
        val decodes = AtomicInteger(0)
        override suspend fun decode(fileName: String): PcmBuffer? { decodes.incrementAndGet(); return files[fileName] }
        override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? = null
        override fun sourceStamp(fileName: String) = stamp
    }

    private fun track(id: String, file: String, ms: Int = 4000, fileStartMs: Int = 0) =
        StudioTrack(id, id, listOf(StudioClip("c-$id", id, file, startMs = 0, durationMs = ms, fileStartMs = fileStartMs)))

    @Test fun planKeepsShortClipsInMemoryAndPagesLongOnes() = runBlocking {
        val loader = CountingLoader(mapOf("short" to PcmBuffer(RATE, 2, tone(RATE, 0.01)), "long" to PcmBuffer(RATE, 2, tone(RATE * 4, 0.01))))
        val clips = ArrangerClipPlan.build(listOf(track("s", "short", 1000), track("l", "long")), 120.0, false, loader, pager = store, shortClipFrames = RATE * 2)!!
        assertNotNull(clips[0].samples); assertNull(clips[0].reader)
        assertNull(clips[1].samples); assertNotNull(clips[1].reader)
        assertEquals(RATE * 4, clips[1].reader!!.frameCount)
        clips.forEach { it.reader?.close() }
    }

    @Test fun secondPlanHitsThePageCacheWithoutDecodingAndAnEditInvalidatesIt() = runBlocking {
        val loader = CountingLoader(mapOf("long" to PcmBuffer(RATE, 2, tone(RATE * 4, 0.01))))
        suspend fun plan(t: StudioTrack) = ArrangerClipPlan.build(listOf(t), 120.0, false, loader, pager = store, shortClipFrames = RATE)!!
        plan(track("l", "long")).forEach { it.reader?.close() }
        assertEquals(1, loader.decodes.get())
        plan(track("l", "long")).forEach { it.reader?.close() }
        assertEquals("cache hit must skip decode", 1, loader.decodes.get())
        plan(track("l", "long", fileStartMs = 500)).forEach { it.reader?.close() }   // scissor edit
        assertEquals(2, loader.decodes.get())
        loader.stamp = "v2"                                                           // source re-recorded
        plan(track("l", "long")).forEach { it.reader?.close() }
        assertEquals(3, loader.decodes.get())
    }

    @Test fun pagedPlanRendersIdenticallyToTheInMemoryPlanOnTheGrid() = runBlocking {
        val loader = CountingLoader(mapOf("long" to PcmBuffer(RATE, 2, tone(RATE * 4, 0.011))))
        val t = listOf(track("l", "long", 3000, fileStartMs = 250))
        val mem = ArrangerClipPlan.build(t, 120.0, false, loader)!!
        val pg = ArrangerClipPlan.build(t, 120.0, false, loader, pager = store, shortClipFrames = RATE)!!
        assertTrue(pg[0].isPaged && !mem[0].isPaged)
        val ref = MultitrackRenderContext.Clip(0, mem[0].startFrame, mem[0].frameLength, 0, ClipPageStore.snap(mem[0].samples!!))
        val a = newCtx(); a.load(listOf(ref), 1, 0, false, 0, 0); a.setTrackMix(0, 1f, 0f)
        val b = newCtx(); b.load(pg, 1, 0, false, 0, 0); b.setTrackMix(0, 1f, 0f)
        assertArrayEquals(pull(a, RATE * 3), pull(b, RATE * 3), 0f)
        a.release(); b.release()
    }

    @Test fun playerPlaysAPagedArrangementWithoutHoldingClipFloats() = runBlocking {
        val loader = CountingLoader(mapOf("long" to PcmBuffer(RATE, 2, tone(RATE * 4, 0.01))))
        val ctxs = ArrayList<MultitrackRenderContext>()
        val scope = CoroutineScope(Dispatchers.Default)
        val p = MultitrackPlayer(loader, { FakeSink() }, scope, newContext = { newCtx().also { ctxs += it } }, reprimeDebounceMs = 20,
            pageStore = store, shortClipFrames = RATE)
        val a = StudioArrangement("A", "arr", listOf(track("l", "long")))
        assertEquals(PlayOutcome.STARTED, p.playOutcome(a))
        assertTrue(dir.listFiles()!!.any { it.name.endsWith(ClipPageStore.EXT) })
        p.stop()
        scope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
        Unit
    }

    // ---- review fixes ----

    /** Records which threads touched paging I/O and how many readers were opened vs closed. */
    private inner class TrackingStore : ClipPageStore(dir) {
        val writeThreads = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val trimThreads = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val opened = AtomicInteger(0); val closed = AtomicInteger(0)
        override fun writeStream(key: Key, frames: Int, blockFrames: Int, fill: (FloatArray, Int, Int) -> Unit): Int {
            writeThreads += Thread.currentThread().name; return super.writeStream(key, frames, blockFrames, fill)
        }
        override fun trim(keep: Set<Key>): Long { trimThreads += Thread.currentThread().name; return super.trim(keep) }
        override fun open(key: Key): ClipReader? = super.open(key)?.let { r ->
            opened.incrementAndGet()
            object : ClipReader by r { override fun close() { closed.incrementAndGet(); r.close() } }
        }
    }

    private class RangedLoader(val frames: Int, val stamp: String = "v1") : MultitrackClipLoader {
        val wholeDecodes = AtomicInteger(0); val windowDecodes = AtomicInteger(0)
        val stampThreads = java.util.concurrent.ConcurrentLinkedQueue<String>()
        override suspend fun decode(fileName: String): PcmBuffer? { wholeDecodes.incrementAndGet(); return PcmBuffer(RATE, 2, FloatArray(frames * 2) { 0.1f }) }
        override suspend fun decodeWindow(fileName: String, startMs: Int, lenMs: Int): PcmBuffer? {
            windowDecodes.incrementAndGet(); val n = (lenMs.toLong() * RATE / 1000).toInt()
            return PcmBuffer(RATE, 2, FloatArray(n * 2) { 0.1f })
        }
        override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? = null
        override fun sourceStamp(fileName: String): String { stampThreads += Thread.currentThread().name; return stamp }
    }

    @Test fun pagingIoRunsOnTheIoDispatcherNeverTheCallersThread() {
        val ts = TrackingStore()
        val loader = RangedLoader(RATE * 4)
        val ex = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it, "pdj-test-io") }
        val callerName = "pdj-test-caller"
        try {
            val t = Thread({
                runBlocking {
                    ArrangerClipPlan.build(listOf(track("l", "long")), 120.0, false, loader, pager = ts, shortClipFrames = RATE, io = ex.asCoroutineDispatcher())!!.forEach { it.reader?.close() }
                }
            }, callerName)
            t.start(); t.join()
        } finally { ex.shutdown() }
        assertTrue("writes=${ts.writeThreads}", ts.writeThreads.isNotEmpty() && ts.writeThreads.all { it.startsWith("pdj-test-io") })
        assertTrue(ts.trimThreads.all { it.startsWith("pdj-test-io") })
        assertTrue(loader.stampThreads.all { it.startsWith("pdj-test-io") })
    }

    @Test fun longMissDecodesOnlyItsWindowAndStreamsIntoThePage() = runBlocking {
        val ts = TrackingStore()
        val loader = RangedLoader(RATE * 600) // whole-file decode would be a 10 min buffer
        val clips = ArrangerClipPlan.build(listOf(track("l", "long", ms = 30_000, fileStartMs = 5_000)), 120.0, false, loader, pager = ts, shortClipFrames = RATE)!!
        assertEquals(0, loader.wholeDecodes.get()); assertEquals(1, loader.windowDecodes.get())
        assertTrue(clips[0].isPaged); assertNull(clips[0].samples); assertEquals(RATE * 30, clips[0].frameLength)
        clips.forEach { it.reader?.close() }
    }

    /** Deterministic per-frame signal so chunk seams are checkable: L = ramp(frame), R = -ramp(frame). */

    private class ChunkingLoader(val fileFrames: Int) : MultitrackClipLoader {
        val wholeDecodes = AtomicInteger(0)
        val windowLens = java.util.concurrent.ConcurrentLinkedQueue<Int>()
        override suspend fun decode(fileName: String): PcmBuffer? { wholeDecodes.incrementAndGet(); error("whole decode of a long unwarped clip") }
        override suspend fun decodeWindow(fileName: String, startMs: Int, lenMs: Int): PcmBuffer? {
            windowLens += lenMs
            val from = (startMs.toLong() * RATE / 1000)
            val n = minOf((lenMs.toLong() * RATE / 1000).toInt().toLong(), fileFrames - from).toInt().coerceAtLeast(0)
            return PcmBuffer(RATE, 2, FloatArray(n * 2) { i -> val f = from + i / 2; if (i % 2 == 0) ramp(f) else -ramp(f) })
        }
        override suspend fun transform(source: PcmBuffer, from: Long, frames: Long, rate: Double, pitchCents: Double): PcmBuffer? = null
        override fun sourceStamp(fileName: String) = "v1"
    }

    @Test fun longUnwarpedClipStreamsInThirtySecondChunksWithSeamlessContent() = runBlocking {
        val loader = ChunkingLoader(RATE * 600)
        val clips = ArrangerClipPlan.build(listOf(track("l", "long", ms = 95_000, fileStartMs = 7_000)), 120.0, false, loader, pager = store, shortClipFrames = RATE)!!
        assertEquals("never a whole-file decode", 0, loader.wholeDecodes.get())
        assertEquals(listOf(30_000, 30_000, 30_000, 5_001), loader.windowLens.toList())
        val r = clips[0].reader!!
        assertEquals(RATE * 95, r.frameCount)
        // Compare across every chunk seam (30 s, 60 s, 90 s) against the source signal at fileStart + frame.
        val buf = FloatArray(8)
        for (seam in listOf(0, RATE * 30, RATE * 60, RATE * 90, r.frameCount - 4)) {
            val at = if (seam == 0 || seam >= r.frameCount - 4) seam else seam - 2
            r.read(buf, 0, at, 4)
            for (i in 0 until 4) {
                val f = RATE.toLong() * 7 + at + i
                assertEquals("L @${at + i}", ramp(f), buf[i * 2], 1e-3f)
                assertEquals("R @${at + i}", -ramp(f), buf[i * 2 + 1], 1e-3f)
            }
        }
        r.close()
    }

    @Test fun cancelledChunkedPlanLeavesNoPageAndNoReader() = runBlocking {
        val ts = TrackingStore()
        val loader = ChunkingLoader(RATE * 600)
        var polls = 0
        val r = ArrangerClipPlan.build(listOf(track("l", "long", ms = 95_000)), 120.0, false, loader, pager = ts, shortClipFrames = RATE, isCancelled = { ++polls > 3 })
        assertNull(r)
        assertEquals(ts.opened.get(), ts.closed.get())
        assertEquals("aborted write leaves no page", 0L, ts.sizeBytes)
    }

    @Test fun playerStartsALongArrangementViaWindowDecodeAndPagesIt() = runBlocking {
        val ts = TrackingStore()
        val loader = RangedLoader(RATE * 1800)
        val scope = CoroutineScope(Dispatchers.Default)
        val p = MultitrackPlayer(loader, { FakeSink() }, scope, newContext = { newCtx() }, reprimeDebounceMs = 20, pageStore = ts, shortClipFrames = RATE)
        assertEquals(PlayOutcome.STARTED, p.playOutcome(StudioArrangement("A", "arr", listOf(track("l", "long", ms = 60_000)))))
        assertEquals(0, loader.wholeDecodes.get()); assertTrue(ts.opened.get() > 0)
        p.stop(); scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); Unit
    }

    @Test fun cancelledPlanClosesEveryReaderItOpened() = runBlocking {
        val ts = TrackingStore()
        val loader = RangedLoader(RATE * 4)
        val t = listOf(track("a", "fa"), track("b", "fb"), track("c", "fc"))
        ArrangerClipPlan.build(t, 120.0, false, loader, pager = ts, shortClipFrames = RATE).also { c -> c!!.forEach { it.reader?.close() } } // warm all hits
        ts.opened.set(0); ts.closed.set(0)
        var calls = 0
        val r = ArrangerClipPlan.build(t, 120.0, false, loader, pager = ts, shortClipFrames = RATE, isCancelled = { ++calls > 4 })
        assertNull(r)
        assertEquals(ts.opened.get(), ts.closed.get())
    }

    @Test fun supersededAfterPlanningClosesPagedReaders() = runBlocking {
        val ts = TrackingStore()
        val loader = RangedLoader(RATE * 4)
        val scope = CoroutineScope(Dispatchers.Default)
        lateinit var p: MultitrackPlayer
        val gate = object : MultitrackClipLoader by loader {
            override fun sourceStamp(fileName: String): String { p.stop("race"); return "v1" } // generation bumps mid-plan
        }
        p = MultitrackPlayer(gate, { FakeSink() }, scope, newContext = { newCtx() }, reprimeDebounceMs = 20, pageStore = ts, shortClipFrames = RATE)
        assertEquals(PlayOutcome.SUPERSEDED, p.playOutcome(StudioArrangement("A", "arr", listOf(track("l", "long")))))
        assertEquals(ts.opened.get(), ts.closed.get())
        scope.coroutineContext[kotlinx.coroutines.Job]?.cancel(); Unit
    }

    @Test fun retainSourcesDropsPagesOfFilesNoArrangementReferences() {
        val k1 = ClipPageStore.Key("keep.m4a", "s", 0, 0, 1.0, 0.0, RATE); val k2 = ClipPageStore.Key("gone.m4a", "s", 0, 0, 1.0, 0.0, RATE)
        store.write(k1, tone(1000, 0.01)); store.write(k2, tone(1000, 0.01))
        store.retainSources(setOf("keep.m4a"))
        assertTrue(store.has(k1)); assertTrue(!store.has(k2))
    }
}

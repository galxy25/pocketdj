package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.dsp.LoudnessSegment
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.cancellation.CancellationException
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import com.levi.pocketdj.audio.dsp.LoudnessCancelFlag
import com.levi.pocketdj.audio.dsp.Loudness
import java.io.IOException
import kotlin.math.PI
import kotlin.math.sin

class LoudnessCacheTest {
    private fun tmp(): File = File.createTempFile("loud", ".json").also { it.delete(); it.deleteOnExit() }
    private fun media(size: Int): File = File.createTempFile("song", ".m4a").also { it.writeBytes(ByteArray(size)); it.deleteOnExit() }
    private fun cache(f: File?, calls: AtomicInteger = AtomicInteger(), measure: (String, LoudnessSegment?, LoudnessCancelFlag) -> Double? = { _, _, _ -> -20.0 }) =
        LoudnessCache(f, CoroutineScope(SupervisorJob() + Dispatchers.Default), Dispatchers.Default, 10, { p, s, c -> calls.incrementAndGet(); measure(p, s, c) })

    @Test fun keyIncludesSizeAndSegment() {
        val a = media(10); val b = media(20)
        val k1 = LoudnessCache.key("s", a)!!; val k2 = LoudnessCache.key("s", b)!!
        assertNotEquals(k1, k2)
        assertEquals(LoudnessSegment(1000, 5000), LoudnessCache.key("s", a, 1000, 5000)!!.segment)
        assertNotEquals(LoudnessCache.key("s", a, 0, 5000), LoudnessCache.key("s", a, 5000, 5000))
        assertNull(LoudnessCache.key("s", File("/nonexistent/x")))
    }

    @Test fun measuresStoresAndReturnsCachedThenGain() = runBlocking {
        val calls = AtomicInteger(); val song = media(5)
        val c = cache(null, calls)
        assertEquals(-20.0, c.analyzeIfNeeded("s", song))
        assertEquals(-20.0, c.analyzeIfNeeded("s", song))
        assertEquals(1, calls.get())
        val key = LoudnessCache.key("s", song)!!
        assertEquals(6.0, c.gainDb(key)!!, 1e-9) // -14 - -20
        assertNull(c.gainDb(LoudnessCache.key("other", song)!!)) // unknown => 0 dB at callers
    }

    @Test fun singleFlightSecondCallerAwaits() = runBlocking {
        val calls = AtomicInteger(); val song = media(5)
        val c = cache(null, calls) { _, _, _ -> Thread.sleep(200); -18.0 }
        val key = LoudnessCache.key("s", song)!!
        val first = async(Dispatchers.Default) { c.analyze(key, song.path) }
        while (!c.isAnalyzing(key)) delay(5)
        val second = c.analyze(key, song.path)
        assertEquals(LoudnessCache.Outcome.Cached(-18.0), second)
        assertEquals(LoudnessCache.Outcome.Measured(-18.0), first.await())
        assertEquals(1, calls.get())
    }

    @Test fun failureIsRememberedForTheLaunch() = runBlocking {
        val calls = AtomicInteger(); val song = media(5)
        val c = cache(null, calls) { _, _, _ -> throw IOException("bad") }
        val key = LoudnessCache.key("s", song)!!
        assertEquals(LoudnessCache.Outcome.Failed, c.analyze(key, song.path))
        assertEquals(LoudnessCache.Outcome.Failed, c.analyze(key, song.path))
        assertEquals(1, calls.get()); assertTrue(c.hasFailed(key)); assertFalse(c.contains(key))
        assertNull(c.analyzeIfNeeded("s", song))
    }

    @Test fun cancelledIsNotRemembered() = runBlocking {
        val calls = AtomicInteger(); val song = media(5)
        val c = cache(null, calls) { _, _, flag ->
            while (!flag.isCancelled) Thread.sleep(5)
            throw CancellationException("x")
        }
        val key = LoudnessCache.key("s", song)!!
        val r = async(Dispatchers.Default) { c.analyze(key, song.path) }
        while (!c.isAnalyzing(key)) delay(5)
        c.cancelAll()
        assertEquals(LoudnessCache.Outcome.Cancelled, r.await())
        assertFalse(c.hasFailed(key)); assertFalse(c.isAnalyzing(key))
    }

    @Test fun growingFileIsNotMeasuredUntilComplete() = runBlocking {
        val calls = AtomicInteger(); val song = media(5)
        val c = cache(null, calls)
        val key = LoudnessCache.key("s", song)!!
        assertEquals(LoudnessCache.Outcome.NotReady, c.analyze(key, song.path) { false })
        assertEquals(0, calls.get()); assertFalse(c.isSettledOrRunning(key))
        assertEquals(LoudnessCache.Outcome.Measured(-20.0), c.analyze(key, song.path) { true })
    }

    @Test fun persistsAndReloadsIncludingUnmeasurable() = runBlocking {
        val f = tmp(); val a = media(7); val b = media(9)
        val c = cache(f) { p, _, _ -> if (p == a.path) -16.5 else null }
        c.analyzeIfNeeded("a", a, 0, 30000); c.analyzeIfNeeded("b", b)
        c.flush()
        val c2 = cache(f)
        val ka = LoudnessCache.key("a", a, 0, 30000)!!; val kb = LoudnessCache.key("b", b)!!
        assertEquals(-16.5, c2.lufs(ka)); assertTrue(c2.contains(kb)); assertNull(c2.lufs(kb))
        assertNull(c2.gainDb(kb))
    }

    @Test fun debouncedSaveWritesWithoutFlush() = runBlocking {
        val f = tmp(); val a = media(3)
        cache(f).analyzeIfNeeded("a", a)
        repeat(100) { if (!f.exists()) delay(20) }
        assertTrue(f.exists())
    }

    @Test fun toleratesCorruptAndForeignJson() {
        val f = tmp()
        f.writeText("not json{{"); assertFalse(cache(f).contains(LoudnessCache.Key("a", 1)))
        // iOS-shape file: unknown fields ignored, entry without lufs = analyzed-unmeasurable, no segment
        f.writeText("""{"version":1,"extra":3,"entries":[{"songId":"a","byteSize":5,"segment":{"startMs":10,"lengthMs":20},"lufs":-12.5},{"songId":"b","byteSize":6,"future":true}]}""")
        val c = cache(f)
        assertEquals(-12.5, c.lufs(LoudnessCache.Key("a", 5, LoudnessSegment(10, 20))))
        assertTrue(c.contains(LoudnessCache.Key("b", 6))); assertNull(c.lufs(LoudnessCache.Key("b", 6)))
    }

    @Test fun analyzerUsesDecoderSeamSegmentAndMonoSum() {
        val sr = 48000
        val chunk = FloatArray(sr * 2) { sin(2 * PI * 1000 * (it / 2) / sr).toFloat() * 0.0708f } // -23 dBFS stereo
        var seen: Pair<Double, Double>? = null
        val v = LoudnessAnalyzer.analyzeSync("p", LoudnessSegment(2000, 4000), true, null, { _, s, m, _, sink ->
            seen = s to m
            repeat(3) { sink(chunk, sr, 2, sr) }; true
        })
        assertEquals(2.0 to 4.0, seen)
        assertEquals(-23.0, v!!, 0.15)
        val none = runCatching { LoudnessAnalyzer.analyzeSync("p", null, true, null, { _, _, _, _, _ -> false }) }
        assertTrue(none.exceptionOrNull() is IOException)
        val flag = LoudnessCancelFlag().also { it.cancel() }
        val cx = runCatching { LoudnessAnalyzer.analyzeSync("p", null, true, flag, { _, _, _, c, _ -> !c() }) }
        assertTrue(cx.exceptionOrNull() is CancellationException)
    }

    @Test fun tornDownScopeCompletesAwaitersAndClearsInFlight() = runBlocking {
        val song = media(5); val key = LoudnessCache.key("s", song)!!
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val c = LoudnessCache(null, scope, Dispatchers.Default, 10, { _, _, _ -> Thread.sleep(100); -20.0 })
        scope.coroutineContext[kotlinx.coroutines.Job]!!.cancel()
        val r = kotlinx.coroutines.withTimeout(3000) { c.analyze(key, song.path) }
        assertEquals(LoudnessCache.Outcome.Cancelled, r)
        assertFalse(c.isAnalyzing(key))
    }

    @Test fun noDuplicateDecodeWhenCallersArriveAtCompletion() = runBlocking {
        repeat(30) { i ->
            val calls = AtomicInteger(); val song = media(10 + i)
            val c = cache(null, calls) { _, _, _ -> -20.0 }
            val key = LoudnessCache.key("s$i", song)!!
            (1..8).map { async(Dispatchers.Default) { repeat(50) { c.analyze(key, song.path) } } }.awaitAll()
            assertEquals(1, calls.get())
        }
    }

    @Test fun zeroLengthSegmentMeasuresNothing() {
        var decoded = false
        val r = LoudnessAnalyzer.analyzeSync("x", LoudnessSegment(1000, 0), true, null, { _, _, _, _, _ -> decoded = true; true })
        assertNull(r)
        assertFalse(decoded)
    }
}

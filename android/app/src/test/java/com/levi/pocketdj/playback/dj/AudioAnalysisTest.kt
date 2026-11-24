package com.levi.pocketdj.playback.dj

import com.levi.pocketdj.audio.core.PcmBuffer
import com.levi.pocketdj.audio.dsp.LoudnessSegment
import com.levi.pocketdj.data.PdjJson
import com.levi.pocketdj.studio.demux.BeatDetect
import com.levi.pocketdj.studio.demux.KeyDetector
import java.io.File
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin
import kotlin.random.Random
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@kotlinx.coroutines.ExperimentalCoroutinesApi
class AudioAnalysisTest {
    private fun clicks(bpm: Double, seconds: Double, sr: Int = 22050): PcmBuffer {
        val out = FloatArray((seconds * sr).toInt())
        val step = 60.0 / bpm * sr
        var pos = 0.0; var beat = 0
        while (pos < out.size) {
            val amp = if (beat % 4 == 0) 1.0 else 0.55
            val p = pos.toInt()
            for (i in 0 until 600) { if (p + i >= out.size) break; out[p + i] += (amp * sin(2 * PI * 1500 * i / sr) * exp(-i / 90.0)).toFloat() }
            pos += step; beat++
        }
        return PcmBuffer(sr, 1, out)
    }

    private fun chord(seconds: Double, sr: Int = 22050, notes: List<Double> = listOf(261.63, 329.63, 392.0)): PcmBuffer =
        PcmBuffer(sr, 1, FloatArray((sr * seconds).toInt()) { i -> notes.sumOf { sin(2 * PI * it * i / sr) }.toFloat() * 0.2f })

    private val key = LoudnessCache.Key("s1", 1000)

    // ---- window ----

    @Test fun completeSongQuickWindowIs20sFromThirtyPercentIn() {
        val w = AudioAnalysis.quickWindow(200.0, 200.0, complete = true)!!
        assertEquals(60.0, w.startSeconds, 1e-9); assertEquals(20.0, w.lengthSeconds, 1e-9); assertFalse(w.headOnly)
    }

    @Test fun shortSongWindowNeverRunsPastTheEnd() {
        val w = AudioAnalysis.quickWindow(25.0, 25.0, complete = true)!!
        assertEquals(5.0, w.startSeconds, 1e-9)            // 7.5 would overrun; start = dur - len
        assertEquals(20.0, w.lengthSeconds, 1e-9)
        val tiny = AudioAnalysis.quickWindow(10.0, 10.0, complete = true)!!
        assertEquals(0.0, tiny.startSeconds, 1e-9); assertEquals(10.0, tiny.lengthSeconds, 1e-9)
        assertNull(AudioAnalysis.quickWindow(2.0, 2.0, complete = true))
        assertNull(AudioAnalysis.quickWindow(100.0, 0.0, complete = true))
    }

    @Test fun unknownDurationUsesWhatIsAvailable() {
        val w = AudioAnalysis.quickWindow(null, 100.0, complete = true)!!
        assertEquals(30.0, w.startSeconds, 1e-9)
        // Declared duration beyond what decodes is clamped to availability.
        assertEquals(15.0, AudioAnalysis.quickWindow(500.0, 50.0, complete = true)!!.startSeconds, 1e-9)
    }

    @Test fun growingFileUsesTheHeadOnceFifteenSecondsExist() {
        assertNull(AudioAnalysis.quickWindow(200.0, 14.9, complete = false))
        val w = AudioAnalysis.quickWindow(200.0, 22.0, complete = false)!!
        assertEquals(0.0, w.startSeconds, 1e-9); assertEquals(22.0, w.lengthSeconds, 1e-9); assertTrue(w.headOnly)
        assertEquals(30.0, AudioAnalysis.quickWindow(200.0, 90.0, complete = false)!!.lengthSeconds, 1e-9)
    }

    // ---- precedence ----

    @Test fun bpmPrecedenceMeasuredThenFullThenConfidentQuickThenNothing() {
        val full = AudioAnalysis.Result(AudioAnalysis.Kind.full, bpm = 128.0, bpmConfidence = 0.5)
        val quick = AudioAnalysis.Result(AudioAnalysis.Kind.quick, bpm = 64.0, bpmConfidence = 0.9)
        assertEquals(AudioAnalysis.Pick(100.0, AudioAnalysis.Source.MEASURED), AudioAnalysis.bpm(100.0, full, quick))
        assertEquals(AudioAnalysis.Pick(128.0, AudioAnalysis.Source.FULL), AudioAnalysis.bpm(null, full, quick))
        assertEquals(AudioAnalysis.Pick(64.0, AudioAnalysis.Source.QUICK), AudioAnalysis.bpm(0.0, null, quick))
        assertEquals(AudioAnalysis.Source.NONE, AudioAnalysis.bpm(null, null, null).source)
    }

    @Test fun lowConfidenceIsTreatedAsMissingAtTheGates() {
        val at = AudioAnalysis.Result(AudioAnalysis.Kind.quick, bpm = 120.0, bpmConfidence = 0.3, camelot = "8A", keyConfidence = 0.7)
        assertEquals(120.0, at.usableBPM!!, 0.0); assertEquals("8A", at.usableCamelot)
        val below = at.copy(bpmConfidence = 0.29, keyConfidence = 0.69)
        assertNull(below.usableBPM); assertNull(below.usableCamelot)
        // A low-confidence FULL result does not block a confident quick hint.
        assertEquals(AudioAnalysis.Source.QUICK, AudioAnalysis.bpm(null, below.copy(kind = AudioAnalysis.Kind.full), at).source)
    }

    @Test fun camelotPrecedenceMatchesBpmLadder() {
        val full = AudioAnalysis.Result(AudioAnalysis.Kind.full, camelot = "5A", keyConfidence = 0.8)
        val quick = AudioAnalysis.Result(AudioAnalysis.Kind.quick, camelot = "9B", keyConfidence = 0.95)
        assertEquals(AudioAnalysis.Pick("1A", AudioAnalysis.Source.MEASURED), AudioAnalysis.camelot("1A", full, quick))
        assertEquals(AudioAnalysis.Pick("5A", AudioAnalysis.Source.FULL), AudioAnalysis.camelot("", full, quick))
        assertEquals(AudioAnalysis.Pick("9B", AudioAnalysis.Source.QUICK), AudioAnalysis.camelot(null, null, quick))
    }

    @Test fun hintLevelingIsClampedAndFullWins() {
        // lufs -30 => +16 dB wanted; the hint caps at +4. lufs -2 => -12 dB wanted; caps at -4.
        assertEquals(AudioAnalysis.Pick(4.0, AudioAnalysis.Source.QUICK),
            AudioAnalysis.levelGain(null, AudioAnalysis.Result(AudioAnalysis.Kind.quick, lufs = -30.0)))
        assertEquals(-4.0, AudioAnalysis.levelGain(null, AudioAnalysis.Result(AudioAnalysis.Kind.quick, lufs = -2.0)).value!!, 1e-9)
        assertEquals(-1.5, AudioAnalysis.levelGain(null, AudioAnalysis.Result(AudioAnalysis.Kind.quick, lufs = -12.5)).value!!, 1e-9)
        // The full gain is NOT clamped to the hint range.
        assertEquals(AudioAnalysis.Pick(9.0, AudioAnalysis.Source.FULL), AudioAnalysis.levelGain(9.0, AudioAnalysis.Result(AudioAnalysis.Kind.quick, lufs = -14.0)))
        assertEquals(AudioAnalysis.Source.NONE, AudioAnalysis.levelGain(null, null).source)
    }

    @Test fun replanOnlyWhenUsableBpmOrCamelotChanged() {
        val weakQuick = AudioAnalysis.Result(AudioAnalysis.Kind.quick, bpm = 100.0, bpmConfidence = 0.1)
        val loudnessOnly = weakQuick.copy(lufs = -9.0)
        assertFalse(AudioAnalysis.usableChanged(null, weakQuick, null, loudnessOnly))
        val strong = AudioAnalysis.Result(AudioAnalysis.Kind.quick, bpm = 100.0, bpmConfidence = 0.6)
        assertTrue(AudioAnalysis.usableChanged(null, weakQuick, null, strong))
        val fullSame = AudioAnalysis.Result(AudioAnalysis.Kind.full, bpm = 100.0, bpmConfidence = 0.6)
        assertFalse(AudioAnalysis.usableChanged(null, strong, fullSame, null))    // hint -> equal final: no re-plan
    }

    // ---- detectors / passes ----

    @Test fun clickTrackBpmAndConfidence() {
        val g = BeatDetect.detectGridWithConfidence(clicks(120.0, 20.0))!!
        assertEquals(120.0, g.grid.bpm, 1.5)
        assertTrue("confidence ${g.confidence}", g.confidence >= AudioAnalysis.MIN_BPM_CONFIDENCE && g.confidence <= 1.0)
        assertEquals(g.grid, BeatDetect.detectGrid(clicks(120.0, 20.0)))        // Studio entry point unchanged
    }

    @Test fun noiseHasLowerConfidenceThanClicks() {
        val rnd = Random(7)
        val noise = PcmBuffer(22050, 1, FloatArray(22050 * 20) { (rnd.nextFloat() - 0.5f) * 0.4f })
        val c = BeatDetect.detectGridWithConfidence(noise)?.confidence ?: 0.0
        val k = BeatDetect.detectGridWithConfidence(clicks(120.0, 20.0))!!.confidence
        assertTrue("noise $c vs clicks $k", c < k && c < 0.3)
    }

    @Test fun maxSecondsLimitsWhatIsAnalysed() {
        // 4 s of clicks then 16 s of silence: capped at 5 s the tempo is found; uncapped, the silence dilutes it.
        val head = clicks(120.0, 5.0).samples
        val pcm = PcmBuffer(22050, 1, head + FloatArray(22050 * 15))
        val capped = BeatDetect.detectGridWithConfidence(pcm, maxSeconds = 5.0)
        assertNotNull(capped); assertEquals(120.0, capped!!.grid.bpm, 3.0)
    }

    @Test fun keyOnAChordCarriesStrengthAndHonoursMaxSeconds() {
        val k = KeyDetector.detect(chord(6.0))!!
        assertEquals("8B", k.camelot)
        assertTrue("strength ${k.strength}", k.strength >= AudioAnalysis.MIN_KEY_CONFIDENCE)
        // maxSeconds below one FFT frame leaves nothing tonal to read.
        assertNull(KeyDetector.detect(chord(6.0), maxSeconds = 0.05))
        assertEquals("8B", KeyDetector.detect(chord(6.0), maxSeconds = 3.0)!!.camelot)
    }

    @Test fun measureCombinesBpmKeyAndLoudness() {
        val r = AudioAnalysis.measure(clicks(100.0, 20.0), AudioAnalysis.Kind.quick, true, 20.0, 20.0, loudness = true)
        assertEquals(AudioAnalysis.Kind.quick, r.kind); assertTrue(r.headOnly)
        assertEquals(100.0, r.bpm!!, 1.5); assertNotNull(r.lufs)
        val noLoud = AudioAnalysis.measure(clicks(100.0, 20.0), AudioAnalysis.Kind.full, false, 20.0, 20.0, loudness = false)
        assertNull(noLoud.lufs)
    }

    private class FakeSource(val pcm: PcmBuffer, val avail: Double) : AudioAnalysis.PassSource {
        val decodes = ArrayList<Pair<Double, Double>>()
        override fun decode(path: String, startSeconds: Double, lengthSeconds: Double): PcmBuffer? { decodes += startSeconds to lengthSeconds; return pcm }
        override fun availableSeconds(path: String, complete: Boolean) = avail
    }

    @Test fun quickPassDecodesTheSliceOffsetWindowAndFullPassTheTopAndMiddle() {
        val src = FakeSource(clicks(120.0, 20.0), 200.0)
        val q = AudioAnalysis.quickPass(src, "p", 10.0, AudioAnalysis.Window(60.0, 20.0, false))!!
        assertEquals(AudioAnalysis.Kind.quick, q.kind); assertEquals(70.0 to 20.0, src.decodes.single())
        src.decodes.clear()
        val f = AudioAnalysis.fullPass(src, "p", 0.0, 200.0)!!
        assertEquals(AudioAnalysis.Kind.full, f.kind); assertNull(f.lufs)
        assertEquals(listOf(0.0 to 120.0, 70.0 to 60.0), src.decodes)      // BPM top 120 s; key = middle minute
        assertNull(AudioAnalysis.fullPass(src, "p", 0.0, 2.0))
    }

    @Test fun headPassOverASliverOfAudioIsRejected() {
        val src = FakeSource(clicks(120.0, 3.0), 200.0)           // header claims 200 s, 3 s decode
        assertNull(AudioAnalysis.quickPass(src, "p", 0.0, AudioAnalysis.Window(0.0, 30.0, true)))
        val ok = FakeSource(clicks(120.0, 20.0), 200.0)
        assertNotNull(AudioAnalysis.quickPass(ok, "p", 0.0, AudioAnalysis.Window(0.0, 30.0, true)))
        assertNotNull(AudioAnalysis.quickPass(src, "p", 0.0, AudioAnalysis.Window(0.0, 3.0, false)))  // non-head windows unaffected
    }

    @Test fun estimateAvailableUsesBytesOverBitrateCappedByDeclared() {
        assertEquals(30.0, AudioAnalysis.estimateAvailable(480_000, 128_000, 0.0), 1e-9)       // no header duration
        assertEquals(30.0, AudioAnalysis.estimateAvailable(480_000, 128_000, 200.0), 1e-9)     // header says final 200 s
        assertEquals(10.0, AudioAnalysis.estimateAvailable(480_000, 128_000, 10.0), 1e-9)
        assertEquals(30.0, AudioAnalysis.estimateAvailable(480_000, 0, 0.0), 1e-9)             // fallback 128 kbps
        assertEquals(0.0, AudioAnalysis.estimateAvailable(0, 128_000, 200.0), 1e-9)
    }

    @Test fun streamingMonoResamplesChunkedInputLikeOneShot() {
        val sr = 44_100
        val x = FloatArray(sr * 2 * 2) { i -> sin(2 * PI * 440.0 * (i / 2) / sr).toFloat() }   // 2 s stereo
        val rs = AudioAnalysis.StreamingMono(22_050)
        var off = 0
        for (chunk in listOf(1000, 4097, 33, 50_000, 100_000)) {
            val frames = minOf(chunk, x.size / 2 - off)
            if (frames <= 0) break
            rs.feed(x.copyOfRange(off * 2, (off + frames) * 2), frames, 2, sr); off += frames
        }
        rs.feed(x.copyOfRange(off * 2, x.size), x.size / 2 - off, 2, sr)
        val out = rs.finish()
        assertEquals(1, out.channels); assertEquals(22_050, out.sampleRate)
        assertEquals(44_100.0, out.frames.toDouble(), 2.0)
        for (i in 100 until out.frames - 100 step 997) {
            assertEquals(sin(2 * PI * 440.0 * (i * 2) / sr), out.samples[i].toDouble(), 0.05)
        }
    }

    // ---- result JSON ----

    @Test fun resultDecodesTolerantlyAndRoundTripsIosShape() {
        val ios = """{"kind":"full","headOnly":false,"bpm":128.0,"bpmConfidence":0.62,"camelot":"8A","keyConfidence":0.81,"lufs":-9.5}"""
        val r = PdjJson.lenient.decodeFromString<AudioAnalysis.Result>(ios)
        assertEquals(AudioAnalysis.Result(AudioAnalysis.Kind.full, false, 128.0, 0.62, "8A", 0.81, -9.5), r)
        // Missing fields, unknown fields, an unknown kind and a wrong-typed field all fall to defaults.
        val odd = PdjJson.lenient.decodeFromString<AudioAnalysis.Result>("""{"kind":"turbo","bpm":null,"future":[1],"keyConfidence":0.9}""")
        assertEquals(AudioAnalysis.Kind.full, odd.kind); assertNull(odd.bpm); assertEquals(0.9, odd.keyConfidence, 0.0)
        assertEquals(r, PdjJson.lenient.decodeFromString<AudioAnalysis.Result>(PdjJson.lenient.encodeToString(r)))
    }

    // ---- cache ----

    private fun tmp(): File = File.createTempFile("analysis", ".json").also { it.delete(); it.deleteOnExit() }
    private fun full(bpm: Double) = AudioAnalysis.Result(AudioAnalysis.Kind.full, bpm = bpm, bpmConfidence = 0.8)
    private fun quick(bpm: Double, head: Boolean = false) = AudioAnalysis.Result(AudioAnalysis.Kind.quick, head, bpm, 0.8)

    @Test fun hintNeverOverwritesFinalAndFinalSupersedesHints() {
        val c = AudioAnalysisCache(null)
        c.store(quick(90.0), key)
        assertEquals(90.0, c.quick(key)!!.bpm!!, 0.0)
        c.store(full(128.0), key)
        assertNull(c.quick(key))                                   // the final supersedes the hint
        c.store(quick(70.0), key)
        assertNull(c.quick(key))                                   // a hint never overwrites a final
        assertEquals(128.0, c.results("s1").first!!.bpm!!, 0.0)
    }

    @Test fun hintLookupSpansByteSizesAndFinalDropsStaleSizes() {
        val c = AudioAnalysisCache(null)
        c.store(quick(90.0, head = true), LoudnessCache.Key("s1", 500))
        assertNotNull(c.quick("s1", null))                          // a growing file re-keys as it grows
        c.store(full(100.0), LoudnessCache.Key("s1", 1000))
        c.store(full(101.0), LoudnessCache.Key("s1", 2000))
        assertEquals(1, c.fullCount); assertNull(c.full(LoudnessCache.Key("s1", 1000)))
        // A different segment of the same song is its own answer.
        c.store(full(77.0), LoudnessCache.Key("s1", 2000, LoudnessSegment(30_000, 60_000)))
        assertEquals(2, c.fullCount)
    }

    @Test fun finalsPersistAndHintsAreLaunchOnly() {
        val f = tmp()
        val a = AudioAnalysisCache(f)
        a.store(full(128.0), key); a.store(quick(60.0), LoudnessCache.Key("s2", 5)); a.flush()
        val b = AudioAnalysisCache(f)
        assertEquals(128.0, b.full(key)!!.bpm!!, 0.0)
        assertEquals(1, b.fullCount); assertNull(b.quick(LoudnessCache.Key("s2", 5)))
        assertEquals(128.0, b.results("s1").first!!.bpm!!, 0.0)
    }

    @Test fun lruKeepsTheMostRecentlyUsedFinals() {
        var t = 0.0
        val f = tmp()
        val c = AudioAnalysisCache(f, maxEntries = 3, now = { t += 1; t })
        for (i in 1..4) c.store(full(100.0 + i), LoudnessCache.Key("s$i", 1))
        c.results("s1")                                              // touch s1: now s2 is the stalest
        c.flush()
        val b = AudioAnalysisCache(f)
        assertEquals(3, b.fullCount)
        assertNull(b.full(LoudnessCache.Key("s2", 1)))
        assertNotNull(b.full(LoudnessCache.Key("s1", 1)))
    }

    @Test fun tolerantDecodeSkipsOnlyTheBadEntryAndSurvivesGarbage() {
        val f = tmp()
        f.writeText("""{"version":9,"extra":1,"entries":[
            {"key":{"songId":"good","byteSize":1},"result":{"kind":"full","bpm":120.0,"bpmConfidence":0.7,"newField":true},"usedAt":5.0},
            {"key":"nonsense"},
            {"key":{"songId":"hint","byteSize":2},"result":{"kind":"quick","bpm":99.0}}]}""")
        val c = AudioAnalysisCache(f)
        assertEquals(1, c.fullCount); assertEquals(120.0, c.full(LoudnessCache.Key("good", 1))!!.bpm!!, 0.0)
        assertNull(c.quick(LoudnessCache.Key("hint", 2)))           // a quick entry on disk is ignored
        f.writeText("not json at all {{{")
        assertEquals(0, AudioAnalysisCache(f).fullCount)
    }

    @Test fun savesAreDebouncedAndOffTheCallingThread() {
        val f = tmp()
        val sched = kotlinx.coroutines.test.TestScope()
        val d = kotlinx.coroutines.test.StandardTestDispatcher(sched.testScheduler)
        val c = AudioAnalysisCache(f, CoroutineScopeOf(d), d, saveDebounceMs = 1000)
        c.store(full(100.0), key)
        c.store(full(110.0), key)
        sched.testScheduler.advanceTimeBy(900); sched.testScheduler.runCurrent()
        assertFalse(f.exists())
        sched.testScheduler.advanceTimeBy(200); sched.testScheduler.runCurrent()
        assertTrue(f.exists())
        assertEquals(110.0, AudioAnalysisCache(f).full(key)!!.bpm!!, 0.0)
    }

    @Suppress("FunctionName")
    private fun CoroutineScopeOf(d: kotlinx.coroutines.CoroutineDispatcher) = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + d)
}

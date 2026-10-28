package com.levi.pocketdj.mix.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ln
import kotlin.math.sqrt

class MixMathTest {
    // crossfade

    @Test fun crossfadeEqualPowerSumsToOne() {
        var x = 0f
        while (x <= 1.0001f) {
            val a = MixMath.crossfadeFactor(Deck.A, x)
            val b = MixMath.crossfadeFactor(Deck.B, x)
            assertEquals("x=$x", 1.0, (a * a + b * b).toDouble(), 1e-5)
            x += 0.05f
        }
    }

    @Test fun crossfadeEndpoints() {
        assertEquals(1f, MixMath.crossfadeFactor(Deck.A, 0f), 1e-6f)
        assertEquals(0f, MixMath.crossfadeFactor(Deck.A, 1f), 1e-6f)
        assertEquals(0f, MixMath.crossfadeFactor(Deck.B, 0f), 1e-6f)
        assertEquals(1f, MixMath.crossfadeFactor(Deck.B, 1f), 1e-6f)
        assertEquals(0.70710678, MixMath.crossfadeFactor(Deck.A, 0.5f).toDouble(), 1e-6)
    }

    // octaveFolded / syncRate

    @Test fun octaveFoldedInRangeIsIdentity() {
        for (r in listOf(0.5, 0.75, 1.0, 1.5, 2.0)) assertEquals(r, MixMath.octaveFolded(r), 1e-9)
    }

    @Test fun octaveFoldedFoldsByOctaves() {
        assertEquals(1.25, MixMath.octaveFolded(2.5), 1e-9)
        assertEquals(2.0, MixMath.octaveFolded(4.0), 1e-9)
        assertEquals(1.125, MixMath.octaveFolded(4.5), 1e-9)
        assertEquals(0.8, MixMath.octaveFolded(0.4), 1e-9)
        assertEquals(0.8, MixMath.octaveFolded(0.2), 1e-9)
    }

    @Test fun octaveFoldedAlwaysLandsInRange() {
        var r = 0.001
        while (r < 500) {
            val f = MixMath.octaveFolded(r)
            assertTrue("r=$r f=$f", f >= 0.5 && f <= 2.0)
            r *= 1.37
        }
    }

    @Test fun octaveFoldedBadInputIsOne() {
        for (v in listOf(0.0, -3.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertEquals(1.0, MixMath.octaveFolded(v), 0.0)
        }
    }

    @Test fun syncRateMatchesIosExamples() {
        assertEquals(1.0, MixMath.syncRate(120.0, 1.0, 120.0), 1e-9)
        assertEquals(1.2, MixMath.syncRate(120.0, 1.0, 100.0), 1e-9)
        assertEquals(2.0, MixMath.syncRate(128.0, 1.0, 64.0), 1e-9)
        assertEquals(2.0, MixMath.syncRate(174.0, 1.0, 87.0), 1e-9)
        assertEquals(1.05, MixMath.syncRate(120.0, 1.05, 120.0), 1e-9)
        assertEquals(1.0, MixMath.syncRate(120.0, 1.0, 0.0), 0.0)
        // 70 BPM lead doubled to 140 effective matches a 140 follower at 1.0
        assertEquals(1.0, MixMath.syncRate(70.0, 2.0, 140.0), 1e-9)
        // 140 lead vs 70 follower folds 2.0 (in range); 140 lead vs 35 follower folds 4 -> 2
        assertEquals(2.0, MixMath.syncRate(140.0, 1.0, 35.0), 1e-9)
    }

    // loop math

    @Test fun loopWindowSnapsToPreviousUnitBoundary() {
        val w = MixMath.loopWindowMath(anchorSec = 7.3, phaseSec = 0.0, unitSeconds = 2.0, units = 2.0, durationSec = 100.0)!!
        assertEquals(6.0, w.start, 1e-9)
        assertEquals(10.0, w.end, 1e-9)
    }

    @Test fun loopWindowPhaseTable() {
        // (anchor - phase)/unit = 9.5 -> boundary 9 -> start 0.25 + 4.5 = 4.75
        val w = MixMath.loopWindowMath(5.0, 0.25, 0.5, 4.0, 100.0)!!
        assertEquals(4.75, w.start, 1e-9)
        assertEquals(6.75, w.end, 1e-9)
        // anchor before the phase -> start at the phase
        val early = MixMath.loopWindowMath(0.1, 0.25, 0.5, 2.0, 100.0)!!
        assertEquals(0.25, early.start, 1e-9)
        assertEquals(1.25, early.end, 1e-9)
    }

    @Test fun loopWindowInvalidInputsAreNull() {
        assertNull(MixMath.loopWindowMath(1.0, 0.0, 0.0, 1.0, 10.0))
        assertNull(MixMath.loopWindowMath(1.0, 0.0, 1.0, 0.0, 10.0))
        assertNull(MixMath.loopWindowMath(1.0, 0.0, 1.0, 1.0, 0.0))
    }

    @Test fun loopWindowAnchorClampedToDuration() {
        val w = MixMath.loopWindowMath(500.0, 0.0, 1.0, 4.0, 10.0)!!
        assertEquals(4, (w.end - w.start).toInt())       // slid back, length kept
        assertEquals(10.0, w.end, 1e-9)
    }

    @Test fun clampSlidesBackWithoutShrinking() {
        val w = MixMath.clampLoopWindow(8.0, 12.0, 10.0)!!
        assertEquals(6.0, w.start, 1e-9)
        assertEquals(10.0, w.end, 1e-9)
    }

    @Test fun clampFloorIs50ms() {
        val w = MixMath.clampLoopWindow(1.0, 1.001, 10.0)!!
        assertEquals(0.05, w.end - w.start, 1e-9)
        val z = MixMath.clampLoopWindow(2.0, 1.0, 10.0)!!   // negative length floors too
        assertEquals(0.05, z.end - z.start, 1e-9)
    }

    @Test fun clampLongerThanDeckShrinksToDeck() {
        val w = MixMath.clampLoopWindow(0.0, 50.0, 10.0)!!
        assertEquals(0.0, w.start, 1e-9)
        assertEquals(10.0, w.end, 1e-9)
    }

    @Test fun clampNegativeStartMovesToZero() {
        val w = MixMath.clampLoopWindow(-1.0, 1.0, 10.0)!!
        assertEquals(0.0, w.start, 1e-9)
        assertEquals(2.0, w.end, 1e-9)
        assertNull(MixMath.clampLoopWindow(0.0, 1.0, 0.0))
    }

    // glide

    @Test fun semitonesPerKeyIs10PercentFrequency() {
        assertEquals(12 * ln(1.1) / ln(2.0), MixMath.SEMITONES_PER_KEY, 1e-12)
        assertEquals(1.6495, MixMath.SEMITONES_PER_KEY, 1e-3)
    }

    @Test fun glideRateAndPitchClamp() {
        assertEquals(1.1, MixMath.glideRate(1.0), 1e-12)
        assertEquals(0.9, MixMath.glideRate(-1.0), 1e-12)
        assertEquals(2.0, MixMath.glideRate(100.0), 0.0)
        assertEquals(0.5, MixMath.glideRate(-100.0), 0.0)
        assertEquals(MixMath.SEMITONES_PER_KEY, MixMath.glidePitch(1.0), 1e-12)
        assertEquals(12.0, MixMath.glidePitch(100.0), 0.0)
        assertEquals(-12.0, MixMath.glidePitch(-100.0), 0.0)
    }

    @Test fun glideIdentityWithNoData() {
        val g = MixMath.glideParams(null, null, null, null)
        assertEquals(GlideParams(1.0, 0.0, 1.0, 0.0), g)
    }

    @Test fun glideIdenticalKeysNoPitch() {
        val g = MixMath.glideParams("8A", "8A", null, null)
        assertEquals(0.0, g.outPitch, 0.0)
        assertEquals(0.0, g.inPitch, 0.0)
    }

    @Test fun glidePitchBendsAtMostOneKeyEachInOpposingDirections() {
        val up = MixMath.glideParams("8A", "9A", null, null)
        assertEquals(MixMath.SEMITONES_PER_KEY * 0.5, up.outPitch, 1e-12)   // 1 step: mag 0.5
        assertEquals(-MixMath.SEMITONES_PER_KEY * 0.5, up.inPitch, 1e-12)
        val far = MixMath.glideParams("1A", "5A", null, null)               // 4 steps: capped at 1 key
        assertEquals(MixMath.SEMITONES_PER_KEY, far.outPitch, 1e-12)
        assertEquals(-MixMath.SEMITONES_PER_KEY, far.inPitch, 1e-12)
        val down = MixMath.glideParams("5A", "1A", null, null)
        assertEquals(-MixMath.SEMITONES_PER_KEY, down.outPitch, 1e-12)
        assertEquals(MixMath.SEMITONES_PER_KEY, down.inPitch, 1e-12)
        assertEquals(1.0, up.outRate, 0.0)   // pitch-only: tempo untouched
    }

    @Test fun glidePitchOneKeyMissingIsIdentity() {
        val g = MixMath.glideParams("8A", null, 120.0, null)
        assertEquals(GlideParams(1.0, 0.0, 1.0, 0.0), g)
    }

    @Test fun glideTempoSplitsOctaveFoldedMatch() {
        val g = MixMath.glideParams(null, null, 128.0, 64.0)     // ra/rb = 2.0
        assertEquals(sqrt(2.0), g.inRate, 1e-12)
        assertEquals(1 / sqrt(2.0), g.outRate, 1e-12)
        val same = MixMath.glideParams(null, null, 120.0, 120.0)
        assertEquals(1.0, same.inRate, 1e-12)
        assertEquals(1.0, same.outRate, 1e-12)
        val near = MixMath.glideParams(null, null, 124.0, 120.0)
        assertEquals(sqrt(124.0 / 120.0), near.inRate, 1e-12)
        assertEquals(1.0, near.inRate * near.outRate, 1e-12)
        // octave: 140 vs 70 folds 2.0, 140 vs 35 folds 4->2: same split
        assertEquals(sqrt(2.0), MixMath.glideParams(null, null, 140.0, 35.0).inRate, 1e-12)
    }

    @Test fun glideTempoMissingOrNonPositiveBpmIsIdentity() {
        assertEquals(1.0, MixMath.glideParams(null, null, 120.0, null).inRate, 0.0)
        assertEquals(1.0, MixMath.glideParams(null, null, 0.0, 120.0).inRate, 0.0)
        assertEquals(1.0, MixMath.glideParams(null, null, 120.0, -5.0).outRate, 0.0)
    }

    @Test fun glideBothAxesCombine() {
        val g = MixMath.glideParams("8A", "10A", 128.0, 100.0)
        assertNotEquals(0.0, g.outPitch, 0.0)
        assertNotEquals(1.0, g.inRate, 0.0)
        assertEquals(MixMath.SEMITONES_PER_KEY, g.outPitch, 1e-12)
    }

    // PRNG

    @Test fun splitmix64KnownVectorsFromSeedZero() {
        val r = SplitMix64(0uL)
        // Reference splitmix64 outputs for seed 0 (widely published test vector).
        assertEquals(0xE220A8397B1DCDAFuL, MixMath.splitmix64(r))
        assertEquals(0x6E789E6AA1B965F4uL, MixMath.splitmix64(r))
        assertEquals(0x06C45D188009454FuL, MixMath.splitmix64(r))
    }

    @Test fun rollTextureIsDeterministicAndInRange() {
        val a = SplitMix64(12345uL)
        val b = SplitMix64(12345uL)
        repeat(50) {
            val ta = MixMath.rollTexture(a)
            val tb = MixMath.rollTexture(b)
            assertEquals(ta, tb)
            assertTrue(ta.effect in MixMath.FX_GLIDE_POOL)
            assertTrue(ta.peak >= 0.5 && ta.peak < 0.8)
            assertTrue(ta.run in 3..5)
        }
        assertEquals(a.state, b.state)
    }

    @Test fun rollTextureVariesAcrossSeedsAndPoolExcludesCompressor() {
        assertFalse(Effect.COMPRESSOR in MixMath.FX_GLIDE_POOL)
        val seen = HashSet<Effect>()
        val runs = HashSet<Int>()
        val rng = SplitMix64(1uL)
        repeat(200) { val t = MixMath.rollTexture(rng); seen.add(t.effect); runs.add(t.run) }
        assertEquals(3, seen.size)
        assertEquals(setOf(3, 4, 5), runs)
    }

    private fun item(id: String) = AutoMixItem(MixLoadable(id, "t", "a"), 1000)

    @Test fun fxSeedIsFnv1aXorCount() {
        // FNV-1a 64 of "a" = 0xaf63dc4c8601ec8c ; xor count 3
        assertEquals(0xaf63dc4c8601ec8cuL xor 3uL, MixMath.fxSeed(listOf(item("a"), item("b"), item("c"))))
        // empty queue hashes the literal "seed", count 0 -> pure FNV-1a("seed")
        val empty = MixMath.fxSeed(emptyList())
        assertEquals(MixMath.fxSeed(listOf(item("seed"))) xor 1uL, empty)
    }

    @Test fun fxSeedDependsOnFirstIdAndCountOnly() {
        val s1 = MixMath.fxSeed(listOf(item("x"), item("y")))
        val s2 = MixMath.fxSeed(listOf(item("x"), item("zzz")))
        assertEquals(s1, s2)
        assertNotEquals(s1, MixMath.fxSeed(listOf(item("x"))))
        assertNotEquals(s1, MixMath.fxSeed(listOf(item("q"), item("y"))))
    }

    // stream math

    @Test fun streamBytesPerSecondNoExpectedUsesHouseRate() {
        assertEquals(32_768.0, MixMath.streamBytesPerSecond(44_100L * 100, 44_100.0, null)!!, 0.0)
        assertEquals(32_768.0, MixMath.streamBytesPerSecond(44_100L * 100, 44_100.0, 0L)!!, 0.0)
    }

    @Test fun streamBytesPerSecondFromExpectedBytes() {
        // 100 s, 4_000_000 bytes -> 40_000 B/s (<= 41 KB/s ceiling)
        assertEquals(40_000.0, MixMath.streamBytesPerSecond(44_100L * 100, 44_100.0, 4_000_000L)!!, 1e-9)
    }

    @Test fun streamBytesPerSecondHeaderlessIsNull() {
        // header claims 10 s but file is 5 MB (>> 41 KB/s * 10 s) -> can't map frames to bytes
        assertNull(MixMath.streamBytesPerSecond(441_000L, 44_100.0, 5_000_000L))
        assertNull(MixMath.streamBytesPerSecond(0L, 44_100.0, 1000L))
        assertNull(MixMath.streamBytesPerSecond(100L, 0.0, 1000L))
    }

    @Test fun streamPlayableFramesNullRateIsStartFrame() {
        assertEquals(777L, MixMath.streamPlayableFrames(10_000_000L, null, 44_100.0, 777L))
        assertEquals(777L, MixMath.streamPlayableFrames(10_000_000L, 0.0, 44_100.0, 777L))
    }

    @Test fun streamPlayableFramesSubtractsMarginAndFloorsAtStart() {
        // 400_000 B at 40_000 B/s = 10 s - 1.5 = 8.5 s
        assertEquals((8.5 * 44_100).toLong(), MixMath.streamPlayableFrames(400_000L, 40_000.0, 44_100.0, 0L))
        // under the margin -> start frame
        assertEquals(1234L, MixMath.streamPlayableFrames(40_000L, 40_000.0, 44_100.0, 1234L))
        // never before the start
        assertEquals(500_000L, MixMath.streamPlayableFrames(400_000L, 40_000.0, 44_100.0, 500_000L))
    }

    // handover / playable seconds

    @Test fun handoverReadyRules() {
        assertFalse(MixMath.handoverReady(0.05, true, 100.0))        // not strictly > 0.05
        assertTrue(MixMath.handoverReady(0.06, true, 100.0))         // complete: playhead covered
        assertFalse(MixMath.handoverReady(3.9, false, 100.0))        // needs 4 s runway
        assertTrue(MixMath.handoverReady(4.0, false, 100.0))
        assertTrue(MixMath.handoverReady(1.0, false, 1.05))          // near song end: songLeft - 0.05
        assertFalse(MixMath.handoverReady(0.9, false, 1.05))
        assertTrue(MixMath.handoverReady(0.1, false, 0.0))           // min(4, max(.05, ..)) = 0.05
    }

    @Test fun playableSecondsCompleteIsLength() {
        assertEquals(30.0, MixMath.playableSeconds(30.0, 0, null, 30.0, true), 0.0)
        assertEquals(0.0, MixMath.playableSeconds(-5.0, 0, null, 30.0, true), 0.0)
    }

    @Test fun playableSecondsPartialUsesByteRateMinusMargin() {
        // expected 3_000_000 B over 100 s = 30_000 B/s ; 600_000 B = 20 s - 1.5
        assertEquals(18.5, MixMath.playableSeconds(100.0, 600_000, 3_000_000, 100.0, false), 1e-9)
        // capped by length
        assertEquals(8.5, MixMath.playableSeconds(10.0, 600_000, 3_000_000, 100.0, false), 1e-9)
        // no expectedBytes: 256 kbps fallback
        assertEquals(10.0 - 1.5, MixMath.playableSeconds(100.0, 327_680, null, 100.0, false), 1e-9)
        // tiny -> floored at 0
        assertEquals(0.0, MixMath.playableSeconds(100.0, 1000, null, 100.0, false), 0.0)
    }

    // throughput / ETA

    @Test fun throughputWindowEmptyIsNull() {
        assertNull(ThroughputWindow().bytesPerSecond(0.0))
    }

    @Test fun throughputWindowSumsOverElapsedSpan() {
        val w = ThroughputWindow()
        w.add(1_000_000, 0.0)
        w.add(2_000_000, 10.0)
        assertEquals(300_000.0, w.bytesPerSecond(10.0)!!, 1e-6)
    }

    @Test fun throughputWindowPrunesTo30sAndFloorsSpanAt1s() {
        val w = ThroughputWindow()
        w.add(1_000_000, 0.0)
        w.add(2_000_000, 10.0)
        w.add(1_000_000, 41.0)       // t=0 and t=10 fall out of the 30 s window
        assertEquals(1, w.sampleCount)
        assertEquals(1_000_000.0, w.bytesPerSecond(41.0)!!, 1e-6)     // 1 s floor
        w.add(327_680, 41.2)
        assertEquals(1_327_680.0, w.bytesPerSecond(41.2)!!, 1e-6)     // still floored (0.2 s)
    }

    @Test fun throughputWindowSpanCapsAt30s() {
        val w = ThroughputWindow()
        w.add(3_000_000, 0.0)
        // exactly at the 30 s edge it is still in the window; span capped at 30
        assertEquals(100_000.0, w.bytesPerSecond(30.0)!!, 1e-6)
        assertNull(w.bytesPerSecond(30.5))     // pruned
    }

    @Test fun etaSeconds() {
        assertNull(MixMath.etaSeconds(300.0, null))
        assertEquals(300 * 32_768.0 / 300_000.0, MixMath.etaSeconds(300.0, 300_000.0)!!, 1e-9)
        assertEquals(300 * 32_768.0 / 327_680.0, MixMath.etaSeconds(300.0, 327_680.0)!!, 1e-9)
        assertEquals(30.0, MixMath.etaSeconds(300.0, 327_680.0)!!, 1e-9)
        // throughput floor of 1 B/s avoids divide-by-zero
        assertEquals(10.0 * 32_768.0, MixMath.etaSeconds(10.0, 0.0)!!, 1e-6)
    }

    @Test fun etaLabelFormats() {
        assertEquals("—", MixMath.etaLabel(null))
        assertEquals("3m 20s", MixMath.etaLabel(200.0))
        assertEquals("45s", MixMath.etaLabel(45.0))
        assertEquals("1m 0s", MixMath.etaLabel(59.6))
        assertEquals("0s", MixMath.etaLabel(0.0))
        assertEquals("—", MixMath.etaLabel(-5.0))
        assertEquals("—", MixMath.etaLabel(Double.POSITIVE_INFINITY))
        assertEquals("—", MixMath.etaLabel(Double.NaN))
    }
}
